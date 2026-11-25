unit PaperOpen_D3D;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// D3D11でメッシュを合成し、AviUtl2の標準画像へ返す。ホストのテクスチャは借用のみ。

interface

uses Winapi.D3D11, Winapi.DXGIFormat, AviUtl2FilterTypes, PaperOpen_State,
  PaperOpen_Geometry, PaperOpen_Image;

type
  TDrawRange = record
    First, Count: Integer;
    Depth: Boolean;
  end;

  TUploadedImage = record
    View: ID3D11ShaderResourceView;
    Version: UInt64;
  end;

  TPaperD3D = class
  private
    FDevice: ID3D11Device;
    FDeferred: ID3D11DeviceContext;
    FLayout: ID3D11InputLayout;
    FMeshVS, FCopyVS: ID3D11VertexShader;
    FMeshPS, FCopyPS, FReadbackPS: ID3D11PixelShader;
    FRaster: ID3D11RasterizerState;
    FSampler: ID3D11SamplerState;
    FBlend: ID3D11BlendState;
    FDepthOff, FDepthOn: ID3D11DepthStencilState;
    FVertices, FConstants: ID3D11Buffer;
    FCapacity: Integer;
    FTarget, FResolved, FCopy, FStaging: ID3D11Texture2D;
    FColorView, FCopyView: ID3D11RenderTargetView;
    FDepthView: ID3D11DepthStencilView;
    FReadView: ID3D11ShaderResourceView;
    FPaper, FCase: TUploadedImage;
    FWidth, FHeight, FSamples, FCopyW, FCopyH, FStageW, FStageH: Integer;
    FCopyFormat: DXGI_FORMAT;
    FSoftware: Boolean;
    FReadback: TArray<TPIXEL_RGBA>;
    procedure ReleaseResources;
    procedure SelectDevice(const Device: ID3D11Device);
    procedure MakePipeline;
    procedure EnsureVertices(Count: Integer);
    procedure EnsureCanvas(Width, Height: Integer);
    procedure EnsureCopy(Width, Height: Integer; Format: DXGI_FORMAT);
    procedure Upload(Image: TPaperImage; var Cache: TUploadedImage);
    procedure Draw(const Target: ID3D11Texture2D; const Canvas: TCanvas;
      Mesh: TPaperMesh; const Ranges: array of TDrawRange;
      const Settings: TPaperSettings; Unfold: Single);
    procedure SendReadback(Video: PFILTER_PROC_VIDEO; const Canvas: TCanvas);
  public
    // Render 中に画像の寸法を確保する。true の場合はホストの標準描画を続ける。
    function Render(Video: PFILTER_PROC_VIDEO; Mesh: TPaperMesh; const Canvas: TCanvas;
      const Ranges: array of TDrawRange; const S: TPaperSettings;
      Unfold: Single; Paper, Container: TPaperImage): Boolean;
  end;

implementation

uses System.SysUtils, System.Math, System.SyncObjs, Winapi.Windows,
  Winapi.D3DCommon, Winapi.D3DCompiler, PaperOpen_Paper;

{$I PaperOpen_Shader.inc}

type
  TUniforms = record
    ScaleX, ScaleY, Depth, Crease, FoldsX, FoldsY, Kind, PrintExposure: Single;
  end;

const
  CLEAR_COLOR: TFourSingleArray = (0, 0, 0, 0);
  BLEND_FACTOR: TFourSingleArray = (1, 1, 1, 1);
  COMPOSITE_FORMAT = DXGI_FORMAT_R16G16B16A16_UNORM;

var
  ShaderLock, SubmitLock: TCriticalSection;
  MeshVSCode, MeshPSCode, CopyVSCode, CopyPSCode, ReadbackPSCode: ID3DBlob;

procedure Check(Res: HRESULT; const Operation: string);
begin
  if Failed(Res) then
    raise EInvalidOp.CreateFmt('%s failed (0x%.8x)', [Operation, UInt32(Res)]);
end;

function CompileCode(const EntryPoint, Profile: AnsiString): ID3DBlob;
var
  Errors: ID3DBlob;
  Res: HRESULT;
  Details: AnsiString;
begin
  Res := D3DCompile(PAnsiChar(SHADER_SOURCE), Length(SHADER_SOURCE), 'PaperOpen',
    nil, nil, PAnsiChar(EntryPoint), PAnsiChar(Profile), D3DCOMPILE_OPTIMIZATION_LEVEL3,
    0, Result, Errors);
  if Failed(Res) and (Errors <> nil) then
  begin
    SetString(Details, PAnsiChar(Errors.GetBufferPointer), Errors.GetBufferSize);
    raise EInvalidOp.Create(string(Details));
  end;
  Check(Res, 'D3DCompile');
end;

procedure ShaderCode;
begin
  ShaderLock.Acquire;
  try
    if MeshVSCode = nil then MeshVSCode := CompileCode('MeshVS', 'vs_5_0');
    if MeshPSCode = nil then MeshPSCode := CompileCode('MeshPS', 'ps_5_0');
    if CopyVSCode = nil then CopyVSCode := CompileCode('CopyVS', 'vs_5_0');
    if CopyPSCode = nil then CopyPSCode := CompileCode('CopyPS', 'ps_5_0');
    if ReadbackPSCode = nil then ReadbackPSCode := CompileCode('ReadbackPS', 'ps_5_0');
  finally
    ShaderLock.Release;
  end;
end;

function TextureDesc(Width, Height: Integer; Format: DXGI_FORMAT;
  Samples, BindFlags: Cardinal): D3D11_TEXTURE2D_DESC;
begin
  Result := Default(D3D11_TEXTURE2D_DESC);
  Result.Width := Width;
  Result.Height := Height;
  Result.Format := Format;
  Result.MipLevels := 1;
  Result.ArraySize := 1;
  Result.SampleDesc.Count := Samples;
  Result.Usage := D3D11_USAGE_DEFAULT;
  Result.BindFlags := BindFlags;
end;

function ViewFormat(Format: DXGI_FORMAT): DXGI_FORMAT;
begin
  case Format of
    DXGI_FORMAT_R8G8B8A8_TYPELESS, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
      Result := DXGI_FORMAT_R8G8B8A8_UNORM;
    DXGI_FORMAT_B8G8R8A8_TYPELESS, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
      Result := DXGI_FORMAT_B8G8R8A8_UNORM;
    DXGI_FORMAT_R16G16B16A16_TYPELESS: Result := DXGI_FORMAT_R16G16B16A16_FLOAT;
    DXGI_FORMAT_R32G32B32A32_TYPELESS: Result := DXGI_FORMAT_R32G32B32A32_FLOAT;
    DXGI_FORMAT_R10G10B10A2_TYPELESS: Result := DXGI_FORMAT_R10G10B10A2_UNORM;
  else
    Result := Format;
  end;
end;

procedure TPaperD3D.ReleaseResources;
begin
  FDeferred := nil;
  FLayout := nil;
  FMeshVS := nil;
  FMeshPS := nil;
  FCopyVS := nil;
  FCopyPS := nil;
  FReadbackPS := nil;
  FRaster := nil;
  FSampler := nil;
  FBlend := nil;
  FDepthOff := nil;
  FDepthOn := nil;
  FVertices := nil;
  FConstants := nil;
  FCapacity := 0;
  FColorView := nil;
  FCopyView := nil;
  FDepthView := nil;
  FReadView := nil;
  FTarget := nil;
  FResolved := nil;
  FCopy := nil;
  FStaging := nil;
  FPaper := Default(TUploadedImage);
  FCase := Default(TUploadedImage);
  FDevice := nil;
  FSoftware := False;
end;

procedure TPaperD3D.SelectDevice(const Device: ID3D11Device);
var
  Res: HRESULT;
  Feature: D3D_FEATURE_LEVEL;
  Immediate: ID3D11DeviceContext;
begin
  if (FDevice <> nil) and (FDeferred <> nil) and
    ((FDevice = Device) or ((Device = nil) and FSoftware)) then Exit;
  ReleaseResources;
  if Device = nil then
  begin
    // SDKのGPU入出力を利用できない場合は独立デバイスでRGBAを生成する。
    Res := D3D11CreateDevice(nil, D3D_DRIVER_TYPE_HARDWARE, 0, 0,
      nil, 0, D3D11_SDK_VERSION, FDevice, Feature, Immediate);
    if Failed(Res) then
      Check(D3D11CreateDevice(nil, D3D_DRIVER_TYPE_WARP, 0, 0,
        nil, 0, D3D11_SDK_VERSION, FDevice, Feature, Immediate), 'D3D11CreateDevice');
    FSoftware := True;
  end
  else
    FDevice := Device;
  Check(FDevice.CreateDeferredContext(0, FDeferred), 'CreateDeferredContext');
end;

procedure TPaperD3D.MakePipeline;
var
  Input: array[0..3] of D3D11_INPUT_ELEMENT_DESC;
  Raster: D3D11_RASTERIZER_DESC;
  Sampler: D3D11_SAMPLER_DESC;
  Buffer: D3D11_BUFFER_DESC;
  Blend: D3D11_BLEND_DESC;
  Depth: D3D11_DEPTH_STENCIL_DESC;
begin
  if FConstants <> nil then Exit;
  ShaderCode;
  Check(FDevice.CreateVertexShader(MeshVSCode.GetBufferPointer, MeshVSCode.GetBufferSize,
    nil, @FMeshVS), 'CreateMeshVS');
  Check(FDevice.CreatePixelShader(MeshPSCode.GetBufferPointer, MeshPSCode.GetBufferSize,
    nil, FMeshPS), 'CreateMeshPS');
  Check(FDevice.CreateVertexShader(CopyVSCode.GetBufferPointer, CopyVSCode.GetBufferSize,
    nil, @FCopyVS), 'CreateCopyVS');
  Check(FDevice.CreatePixelShader(CopyPSCode.GetBufferPointer, CopyPSCode.GetBufferSize,
    nil, FCopyPS), 'CreateCopyPS');
  Check(FDevice.CreatePixelShader(ReadbackPSCode.GetBufferPointer, ReadbackPSCode.GetBufferSize,
    nil, FReadbackPS), 'CreateReadbackPS');

  FillChar(Input, SizeOf(Input), 0);
  Input[0].SemanticName := 'POSITION';
  Input[0].Format := DXGI_FORMAT_R32G32B32_FLOAT;
  Input[1].SemanticName := 'TEXCOORD';
  Input[1].Format := DXGI_FORMAT_R32G32_FLOAT;
  Input[1].AlignedByteOffset := 12;
  Input[2].SemanticName := 'COLOR';
  Input[2].Format := DXGI_FORMAT_R32G32B32A32_FLOAT;
  Input[2].AlignedByteOffset := 20;
  Input[3].SemanticName := 'TEXCOORD';
  Input[3].SemanticIndex := 1;
  Input[3].Format := DXGI_FORMAT_R32G32_FLOAT;
  Input[3].AlignedByteOffset := 36;
  Check(FDevice.CreateInputLayout(@Input[0], Length(Input), MeshVSCode.GetBufferPointer,
    MeshVSCode.GetBufferSize, FLayout), 'CreateInputLayout');

  Raster := Default(D3D11_RASTERIZER_DESC);
  Raster.FillMode := D3D11_FILL_SOLID;
  Raster.CullMode := D3D11_CULL_NONE;
  Raster.DepthClipEnable := True;
  Raster.MultisampleEnable := True;
  Check(FDevice.CreateRasterizerState(Raster, FRaster), 'CreateRasterizerState');

  Sampler := Default(D3D11_SAMPLER_DESC);
  Sampler.Filter := D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
  Sampler.AddressU := D3D11_TEXTURE_ADDRESS_CLAMP;
  Sampler.AddressV := D3D11_TEXTURE_ADDRESS_CLAMP;
  Sampler.AddressW := D3D11_TEXTURE_ADDRESS_CLAMP;
  Sampler.ComparisonFunc := D3D11_COMPARISON_NEVER;
  Sampler.MaxAnisotropy := 1;
  Check(FDevice.CreateSamplerState(Sampler, FSampler), 'CreateSamplerState');

  Blend := Default(D3D11_BLEND_DESC);
  with Blend.RenderTarget[0] do
  begin
    BlendEnable := True;
    SrcBlend := D3D11_BLEND_ONE;
    DestBlend := D3D11_BLEND_INV_SRC_ALPHA;
    BlendOp := D3D11_BLEND_OP_ADD;
    SrcBlendAlpha := D3D11_BLEND_ONE;
    DestBlendAlpha := D3D11_BLEND_INV_SRC_ALPHA;
    BlendOpAlpha := D3D11_BLEND_OP_ADD;
    RenderTargetWriteMask := Ord(D3D11_COLOR_WRITE_ENABLE_ALL);
  end;
  Check(FDevice.CreateBlendState(Blend, FBlend), 'CreateBlendState');
  Depth := Default(D3D11_DEPTH_STENCIL_DESC);
  Depth.DepthWriteMask := D3D11_DEPTH_WRITE_MASK_ZERO;
  Depth.DepthFunc := D3D11_COMPARISON_ALWAYS;
  Check(FDevice.CreateDepthStencilState(Depth, FDepthOff), 'CreateDepthOff');
  Depth.DepthEnable := True;
  Depth.DepthWriteMask := D3D11_DEPTH_WRITE_MASK_ALL;
  Depth.DepthFunc := D3D11_COMPARISON_LESS_EQUAL;
  Check(FDevice.CreateDepthStencilState(Depth, FDepthOn), 'CreateDepthOn');

  Buffer := Default(D3D11_BUFFER_DESC);
  Buffer.ByteWidth := SizeOf(TUniforms);
  Buffer.Usage := D3D11_USAGE_DYNAMIC;
  Buffer.BindFlags := D3D11_BIND_CONSTANT_BUFFER;
  Buffer.CPUAccessFlags := D3D11_CPU_ACCESS_WRITE;
  Check(FDevice.CreateBuffer(Buffer, nil, FConstants), 'CreateConstantBuffer');
end;

procedure TPaperD3D.EnsureVertices(Count: Integer);
var
  Desc: D3D11_BUFFER_DESC;
  Capacity: Integer;
begin
  if FCapacity >= Count then Exit;
  Capacity := Max(768, FCapacity);
  while Capacity < Count do Capacity := Capacity * 2;
  Desc := Default(D3D11_BUFFER_DESC);
  Desc.ByteWidth := Capacity * SizeOf(TPaperVertex);
  Desc.Usage := D3D11_USAGE_DYNAMIC;
  Desc.BindFlags := D3D11_BIND_VERTEX_BUFFER;
  Desc.CPUAccessFlags := D3D11_CPU_ACCESS_WRITE;
  Check(FDevice.CreateBuffer(Desc, nil, FVertices), 'CreateVertexBuffer');
  FCapacity := Capacity;
end;

procedure TPaperD3D.EnsureCanvas(Width, Height: Integer);
var
  Desc: D3D11_TEXTURE2D_DESC;
  Depth, Color, ResolveTex: ID3D11Texture2D;
  RTV: ID3D11RenderTargetView;
  DSV: ID3D11DepthStencilView;
  SRV: ID3D11ShaderResourceView;
  Samples: Cardinal;
  ColorQuality, DepthQuality: Cardinal;
begin
  if (FReadView <> nil) and (Width <= FWidth) and (Height <= FHeight) then Exit;
  if (FReadView <> nil) and (Int64(Max(Width,FWidth)) * Max(Height,FHeight) <=
    Int64(Width) * Height * 2) and
    (Int64(Max(Width,FWidth)) * Max(Height,FHeight) <= MAX_IMAGE_PIXELS) then
  begin
    Width := Max(Width,FWidth);
    Height := Max(Height,FHeight);
  end;
  Samples := 1;
  if Int64(Width) * Height <= 2000000 then Samples := 4
  else if Int64(Width) * Height <= 4000000 then Samples := 2;
  while Samples > 1 do
  begin
    if Succeeded(FDevice.CheckMultisampleQualityLevels(COMPOSITE_FORMAT, Samples, ColorQuality)) and
      Succeeded(FDevice.CheckMultisampleQualityLevels(DXGI_FORMAT_D32_FLOAT, Samples, DepthQuality)) and
      (ColorQuality > 0) and (DepthQuality > 0) then Break;
    Samples := Samples div 2;
  end;
  Desc := TextureDesc(Width, Height, DXGI_FORMAT_D32_FLOAT, Samples, D3D11_BIND_DEPTH_STENCIL);
  Check(FDevice.CreateTexture2D(Desc, nil, Depth), 'CreateDepthTexture');
  Check(FDevice.CreateDepthStencilView(Depth, nil, DSV), 'CreateDepthView');

  Desc := TextureDesc(Width, Height, COMPOSITE_FORMAT, Samples, D3D11_BIND_RENDER_TARGET);
  if Samples = 1 then Desc.BindFlags := Desc.BindFlags or D3D11_BIND_SHADER_RESOURCE;
  Check(FDevice.CreateTexture2D(Desc, nil, Color), 'CreateCompositeTexture');
  Check(FDevice.CreateRenderTargetView(Color, nil, RTV), 'CreateCompositeView');
  if Samples > 1 then
  begin
    Desc := TextureDesc(Width, Height, COMPOSITE_FORMAT, 1, D3D11_BIND_SHADER_RESOURCE);
    Check(FDevice.CreateTexture2D(Desc, nil, ResolveTex), 'CreateResolveTexture');
  end
  else ResolveTex := Color;
  Check(FDevice.CreateShaderResourceView(ResolveTex, nil, SRV), 'CreateCompositeReadView');
  FTarget := Color;
  FResolved := ResolveTex;
  FColorView := RTV;
  FDepthView := DSV;
  FReadView := SRV;
  FWidth := Width;
  FHeight := Height;
  FSamples := Samples;
end;

procedure TPaperD3D.EnsureCopy(Width, Height: Integer; Format: DXGI_FORMAT);
var
  Desc: D3D11_TEXTURE2D_DESC;
  Surface: ID3D11Texture2D;
  View: ID3D11RenderTargetView;
begin
  if (FCopyView <> nil) and (Format = FCopyFormat) and
    (Width <= FCopyW) and (Height <= FCopyH) then Exit;
  Desc := TextureDesc(Width, Height, Format, 1, D3D11_BIND_RENDER_TARGET);
  Check(FDevice.CreateTexture2D(Desc, nil, Surface), 'CreateOutputTexture');
  Check(FDevice.CreateRenderTargetView(Surface, nil, View), 'CreateOutputView');
  FCopy := Surface;
  FCopyView := View;
  FCopyFormat := Format;
  FCopyW := Width;
  FCopyH := Height;
end;

procedure TPaperD3D.Upload(Image: TPaperImage; var Cache: TUploadedImage);
type
  TPixel16 = packed record R, G, B, A: Word end;
var
  Data: TArray<TPixel16>;
  P: PPIXEL_RGBA;
  Desc: D3D11_TEXTURE2D_DESC;
  Initial: D3D11_SUBRESOURCE_DATA;
  Texture: ID3D11Texture2D;
  View: ID3D11ShaderResourceView;
  I, A: Integer;
begin
  if Image = nil then
  begin
    Cache := Default(TUploadedImage);
    Exit;
  end;
  if (Cache.View <> nil) and (Cache.Version = Image.Version) then Exit;
  P := Image.Pixels;
  SetLength(Data, Image.Width * Image.Height);
  // 透明エッジで透明画素のRGBがにじまないように補間前に乗算する。
  for I := 0 to High(Data) do
  begin
    A := P^.A * 257;
    Data[I].R := (P^.R * A + 127) div 255;
    Data[I].G := (P^.G * A + 127) div 255;
    Data[I].B := (P^.B * A + 127) div 255;
    Data[I].A := A;
    Inc(P);
  end;
  Desc := TextureDesc(Image.Width, Image.Height, DXGI_FORMAT_R16G16B16A16_UNORM, 1,
    D3D11_BIND_SHADER_RESOURCE);
  Desc.Usage := D3D11_USAGE_IMMUTABLE;
  Initial := Default(D3D11_SUBRESOURCE_DATA);
  Initial.pSysMem := @Data[0];
  Initial.SysMemPitch := Image.Width * SizeOf(TPixel16);
  Check(FDevice.CreateTexture2D(Desc, @Initial, Texture), 'UploadImage');
  Check(FDevice.CreateShaderResourceView(Texture, nil, View), 'CreateImageView');
  Cache.View := View;
  Cache.Version := Image.Version;
end;

procedure TPaperD3D.Draw(const Target: ID3D11Texture2D; const Canvas: TCanvas;
  Mesh: TPaperMesh; const Ranges: array of TDrawRange; const Settings: TPaperSettings;
  Unfold: Single);
var
  W, H, I, X, Y: Integer;
  Stride, Offset: Cardinal;
  Constants: TUniforms;
  Mapping: D3D11_MAPPED_SUBRESOURCE;
  TargetDesc: D3D11_TEXTURE2D_DESC;
  OutputDesc: D3D11_RENDER_TARGET_VIEW_DESC;
  Format: DXGI_FORMAT;
  OutputView: ID3D11RenderTargetView;
  Empty: ID3D11ShaderResourceView;
  Viewport: D3D11_VIEWPORT;
  Region: D3D11_BOX;
  Cmd: ID3D11CommandList;
  Immediate: ID3D11DeviceContext;
  CopyToTarget: Boolean;
begin
  W := Canvas.Width;
  H := Canvas.Height;
  Format := DXGI_FORMAT_R8G8B8A8_UNORM;
  if Target <> nil then
  begin
    Target.GetDesc(TargetDesc);
    if (TargetDesc.ArraySize <> 1) or (TargetDesc.SampleDesc.Count <> 1) or
      (TargetDesc.Width < Cardinal(W)) or (TargetDesc.Height < Cardinal(H)) then
      raise EInvalidOp.Create('Unsupported image texture layout');
    Format := ViewFormat(TargetDesc.Format);
    OutputDesc := Default(D3D11_RENDER_TARGET_VIEW_DESC);
    OutputDesc.Format := Format;
    OutputDesc.ViewDimension := D3D11_RTV_DIMENSION_TEXTURE2D;
    if Failed(FDevice.CreateRenderTargetView(Target, @OutputDesc, OutputView)) then
      OutputView := nil;
  end;
  CopyToTarget := (Target <> nil) and (OutputView = nil);
  if OutputView = nil then
  begin
    EnsureCopy(W, H, Format);
    OutputView := FCopyView;
  end;

  EnsureVertices(Mesh.Count);
  EnsureCanvas(W,H);
  Check(FDeferred.Map(FVertices, 0, D3D11_MAP_WRITE_DISCARD, 0, Mapping), 'MapVertices');
  Move(Mesh.Data^, Mapping.pData^, Mesh.Count * SizeOf(TPaperVertex));
  FDeferred.Unmap(FVertices, 0);
  Constants.ScaleX := 2 / W;
  Constants.ScaleY := -2 / H;
  Constants.Depth := 0.47 / Mesh.Depth;
  Constants.Kind := Ord(Settings.Fold);
  // 折り切った紙の外側は地色で覆い、展開に合わせて表側の印刷面を出す。
  Constants.PrintExposure := Smooth(EnsureRange((Unfold - 0.10) / 0.58, 0, 1));
  FoldDivisions(Settings.Fold, X, Y);
  if Settings.Fold in [fkScroll, fkRoll] then Y := 4;
  if Settings.Fold = fkTurn then X := 2;
  Constants.FoldsX := X;
  Constants.FoldsY := Y;
  Constants.Crease := Settings.Crease;
  Check(FDeferred.Map(FConstants, 0, D3D11_MAP_WRITE_DISCARD, 0, Mapping), 'MapConstants');
  Move(Constants, Mapping.pData^, SizeOf(Constants));
  FDeferred.Unmap(FConstants, 0);

  Viewport := Default(D3D11_VIEWPORT);
  Viewport.Width := W;
  Viewport.Height := H;
  Viewport.MaxDepth := 1;
  Stride := SizeOf(TPaperVertex);
  Offset := 0;
  FDeferred.IASetInputLayout(FLayout);
  FDeferred.IASetVertexBuffers(0, 1, FVertices, @Stride, @Offset);
  FDeferred.IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  FDeferred.VSSetShader(FMeshVS, nil, 0);
  FDeferred.VSSetConstantBuffers(0, 1, FConstants);
  FDeferred.PSSetShader(FMeshPS, nil, 0);
  FDeferred.PSSetConstantBuffers(0, 1, FConstants);
  FDeferred.PSSetShaderResources(0, 1, FPaper.View);
  FDeferred.PSSetShaderResources(1, 1, FCase.View);
  FDeferred.PSSetSamplers(0, 1, FSampler);
  FDeferred.RSSetState(FRaster);
  FDeferred.RSSetViewports(1, @Viewport);
  FDeferred.OMSetRenderTargets(1, FColorView, FDepthView);
  FDeferred.ClearRenderTargetView(FColorView, CLEAR_COLOR);
  FDeferred.ClearDepthStencilView(FDepthView, D3D11_CLEAR_DEPTH, 1, 0);
  FDeferred.OMSetBlendState(FBlend, BLEND_FACTOR, $FFFFFFFF);
  for I := Low(Ranges) to High(Ranges) do
    if Ranges[I].Count > 0 then
    begin
      if Ranges[I].Depth then FDeferred.OMSetDepthStencilState(FDepthOn, 0)
      else FDeferred.OMSetDepthStencilState(FDepthOff, 0);
      FDeferred.Draw(Ranges[I].Count, Ranges[I].First);
    end;
  FDeferred.OMSetRenderTargets(0, nil, nil);
  if FSamples > 1 then
    FDeferred.ResolveSubresource(FResolved, 0, FTarget, 0, COMPOSITE_FORMAT);

  FDeferred.IASetInputLayout(nil);
  FDeferred.VSSetShader(FCopyVS, nil, 0);
  // ホストのD3D画像は乗算済みアルファ。SetImageData用の読み戻しだけ解除する。
  if Target <> nil then FDeferred.PSSetShader(FCopyPS, nil, 0)
  else FDeferred.PSSetShader(FReadbackPS, nil, 0);
  FDeferred.PSSetShaderResources(0, 1, FReadView);
  FDeferred.OMSetRenderTargets(1, OutputView, nil);
  FDeferred.OMSetDepthStencilState(FDepthOff, 0);
  FDeferred.OMSetBlendState(nil, BLEND_FACTOR, $FFFFFFFF);
  FDeferred.Draw(3, 0);
  Empty := nil;
  FDeferred.PSSetShaderResources(0, 1, Empty);
  FDeferred.PSSetShaderResources(1, 1, Empty);
  FDeferred.OMSetRenderTargets(0, nil, nil);
  if CopyToTarget then
  begin
    Region := Default(D3D11_BOX);
    Region.Right := W;
    Region.Bottom := H;
    Region.Back := 1;
    FDeferred.CopySubresourceRegion(Target, 0, 0, 0, 0, FCopy, 0, @Region);
  end;

  Check(FDeferred.FinishCommandList(False, Cmd), 'FinishCommandList');
  FDevice.GetImmediateContext(Immediate);
  SubmitLock.Acquire;
  try
    Immediate.ExecuteCommandList(Cmd, True);
  finally
    SubmitLock.Release;
  end;
  Check(FDevice.GetDeviceRemovedReason, 'Draw');
end;

procedure TPaperD3D.SendReadback(Video: PFILTER_PROC_VIDEO; const Canvas: TCanvas);
var
  W, H, Row: Integer;
  Desc: D3D11_TEXTURE2D_DESC;
  Map: D3D11_MAPPED_SUBRESOURCE;
  Region: D3D11_BOX;
  Immediate: ID3D11DeviceContext;
begin
  W := Canvas.Width;
  H := Canvas.Height;
  if (FStaging = nil) or (W > FStageW) or (H > FStageH) then
  begin
    Desc := TextureDesc(W, H, DXGI_FORMAT_R8G8B8A8_UNORM, 1, 0);
    Desc.Usage := D3D11_USAGE_STAGING;
    Desc.CPUAccessFlags := D3D11_CPU_ACCESS_READ;
    Check(FDevice.CreateTexture2D(Desc, nil, FStaging), 'CreateReadbackTexture');
    FStageW := W;
    FStageH := H;
  end;
  Region := Default(D3D11_BOX);
  Region.Right := W;
  Region.Bottom := H;
  Region.Back := 1;
  FDevice.GetImmediateContext(Immediate);
  Immediate.CopySubresourceRegion(FStaging, 0, 0, 0, 0, FCopy, 0, @Region);
  if Length(FReadback) < W * H then SetLength(FReadback, W * H);
  Check(Immediate.Map(FStaging, 0, D3D11_MAP_READ, 0, Map), 'MapOutput');
  try
    for Row := 0 to H - 1 do
      Move((PByte(Map.pData) + Row * NativeInt(Map.RowPitch))^, FReadback[Row * W], W * 4);
  finally
    Immediate.Unmap(FStaging, 0);
  end;
  Video^.SetImageData(@FReadback[0], W, H);
end;

function TPaperD3D.Render(Video: PFILTER_PROC_VIDEO; Mesh: TPaperMesh;
  const Canvas: TCanvas; const Ranges: array of TDrawRange; const S: TPaperSettings;
  Unfold: Single; Paper, Container: TPaperImage): Boolean;
var
  Image: ID3D11Texture2D;
  Device: ID3D11Device;
begin
  Result := False;
  if not Assigned(Video^.SetImageData) or (Mesh.Count = 0) then Exit;
  if Assigned(Video^.GetImageTexture2D) then
  begin
    // PianoRollと同様、初期メディアの画像リソースをSDK側で先に確保する。
    Video^.SetImageData(nil, Canvas.Width, Canvas.Height);
    Pointer(Image) := Video^.GetImageTexture2D();
    if Image <> nil then
    begin
      Image._AddRef;
      try
        Image.GetDevice(Device);
        SelectDevice(Device);
        MakePipeline;
        Upload(Paper, FPaper);
        Upload(Container, FCase);
        Draw(Image, Canvas, Mesh, Ranges, S, Unfold);
        Exit(True);
      except
        on E: Exception do
        begin
          OutputDebugString(PWideChar('SYNC_PaperOpen texture output: ' + E.Message));
          ReleaseResources;
        end;
      end;
    end;
  end;

  // SetImageDataによる再確保を行う前に、借用画像への参照を解放する。
  Image := nil;
  try
    SelectDevice(nil);
    MakePipeline;
    Upload(Paper, FPaper);
    Upload(Container, FCase);
    Draw(nil, Canvas, Mesh, Ranges, S, Unfold);
    SendReadback(Video, Canvas);
    Result := True;
  except
    ReleaseResources;
    raise;
  end;
end;

initialization
  ShaderLock := TCriticalSection.Create;
  SubmitLock := TCriticalSection.Create;
finalization
  SubmitLock.Free;
  ShaderLock.Free;
end.
