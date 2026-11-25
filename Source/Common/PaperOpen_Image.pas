unit PaperOpen_Image;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// WIC の先頭フレームを straight RGBA に変換し、ファイルの版ごとに保持する。

interface

uses AviUtl2FilterTypes;

type
  TPaperImage = class
  private
    FFilename: string;
    FSize, FStamp: Int64;
    FValid: Boolean;
    FWidth, FHeight: Integer;
    FVersion: UInt64;
    FPixels: TArray<TPIXEL_RGBA>;
  public
    // パスまたはファイルの版が変わった時だけ読み直す。Pixels は次の更新まで有効。
    function Load(const Filename: string): Boolean;
    function Pixels: PPIXEL_RGBA;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Version: UInt64 read FVersion;
  end;

const
  MAX_IMAGE_SIDE = 16384;
  MAX_IMAGE_PIXELS = 33554432;

implementation

uses
  System.SysUtils, System.Win.ComObj, Winapi.Windows, Winapi.ActiveX,
  Winapi.Wincodec;

function TPaperImage.Load(const Filename: string): Boolean;
var
  Attributes: TWin32FileAttributeData;
  Size, Stamp: Int64;
  InitResult: HRESULT;
  Factory: IWICImagingFactory;
  Decoder: IWICBitmapDecoder;
  Frame: IWICBitmapFrameDecode;
  Converter: IWICFormatConverter;
  W, H: Cardinal;
  Data: TArray<TPIXEL_RGBA>;
begin
  if (Filename = '') or
    not GetFileAttributesEx(PChar(Filename), GetFileExInfoStandard, @Attributes) or
    ((Attributes.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) then
  begin
    if FFilename <> '' then
    begin
      FFilename := '';
      FValid := False;
      FPixels := nil;
      Inc(FVersion);
    end;
    Exit(False);
  end;

  Size := (Int64(Attributes.nFileSizeHigh) shl 32) or Attributes.nFileSizeLow;
  Stamp := (Int64(Attributes.ftLastWriteTime.dwHighDateTime) shl 32) or
    Attributes.ftLastWriteTime.dwLowDateTime;
  if (Filename = FFilename) and (Size = FSize) and (Stamp = FStamp) then
    Exit(FValid);

  FFilename := Filename;
  FSize := Size;
  FStamp := Stamp;
  Inc(FVersion);
  FValid := False;
  FPixels := nil;
  Result := False;
  InitResult := CoInitializeEx(nil, COINIT_MULTITHREADED);
  if Failed(InitResult) and (InitResult <> RPC_E_CHANGED_MODE) then Exit;
  try
    if Failed(CoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER,
      IWICImagingFactory, Factory)) then Exit;
    if Failed(Factory.CreateDecoderFromFilename(PChar(Filename), TGUID.Empty,
      GENERIC_READ, WICDecodeMetadataCacheOnDemand, Decoder)) then Exit;
    if Failed(Decoder.GetFrame(0, Frame)) or Failed(Frame.GetSize(W, H)) then Exit;
    if (W = 0) or (H = 0) or (W > MAX_IMAGE_SIDE) or (H > MAX_IMAGE_SIDE) or
      (Int64(W) * H > MAX_IMAGE_PIXELS) then Exit;
    if Failed(Factory.CreateFormatConverter(Converter)) then Exit;
    if Failed(Converter.Initialize(Frame, GUID_WICPixelFormat32bppRGBA,
      WICBitmapDitherTypeNone, nil, 0, WICBitmapPaletteTypeCustom)) then Exit;
    SetLength(Data, Integer(W * H));
    if Failed(Converter.CopyPixels(nil, W * 4, W * H * 4, @Data[0])) then Exit;
    FWidth := W;
    FHeight := H;
    FPixels := Data;
    FValid := True;
    Result := True;
  finally
    Converter := nil;
    Frame := nil;
    Decoder := nil;
    Factory := nil;
    if Succeeded(InitResult) then CoUninitialize;
  end;
end;

function TPaperImage.Pixels: PPIXEL_RGBA;
begin
  Result := Pointer(FPixels);
end;

end.
