unit SYNC_PaperOpen_MediaPlugin;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 開封演出メディアの登録と、エフェクトごとの画像・描画資源の所有。

interface

uses AviUtl2FilterTypes;

const
  PAPEROPEN_REQUIRED_VERSION = 2011600;

function GetPaperOpenMediaTable: PFILTER_PLUGIN_TABLE;

implementation

uses
  System.SysUtils, System.SyncObjs, Winapi.Windows, PluginFilterTable,
  PaperOpen_State, PaperOpen_Parameters, PaperOpen_Image, PaperOpen_Geometry,
  PaperOpen_Paper, PaperOpen_Container, PaperOpen_D3D;

type
  TPaperSession = class
  private
    FLock: TCriticalSection;
    FPaper, FContainer: TPaperImage;
    FMesh: TPaperMesh;
    FD3D: TPaperD3D;
    FFold: TFoldKind;
    FFootprintVersion: UInt64;
    FFoldedWidth, FFoldedHeight: Single;
  public
    constructor Create;
    destructor Destroy; override;
    function Render(Video: PFILTER_PROC_VIDEO; S: TPaperSettings;
      const PaperPath, ContainerPath: string): Byte;
  end;

var
  Registered: Boolean;

constructor TPaperSession.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FPaper := TPaperImage.Create;
  FContainer := TPaperImage.Create;
  FMesh := TPaperMesh.Create;
  FD3D := TPaperD3D.Create;
end;

destructor TPaperSession.Destroy;
begin
  FD3D.Free;
  FMesh.Free;
  FContainer.Free;
  FPaper.Free;
  FLock.Free;
  inherited;
end;

function TPaperSession.Render(Video: PFILTER_PROC_VIDEO; S: TPaperSettings;
  const PaperPath, ContainerPath: string): Byte;
var
  Frame: TPaperFrame;
  PaperPose: TPose;
  Container: TContainerLayout;
  Custom: TPaperImage;
  ImageW, ImageH: Integer;
  FabricW, FabricH: Single;
  Ranges: array[0..2] of TDrawRange;
  Batch: Integer;

  procedure AddContainer(Front: Boolean);
  begin
    Ranges[Batch].First := FMesh.Count;
    Ranges[Batch].Depth := False;
    DrawContainer(FMesh, Container, Front);
    Ranges[Batch].Count := FMesh.Count - Ranges[Batch].First;
    Inc(Batch);
  end;

begin
  Result := 0;
  if not Assigned(Video^.SetImageData) then Exit;
  FLock.Acquire;
  try
    if not FPaper.Load(PaperPath) then Exit;
    ImageW := FPaper.Width;
    ImageH := FPaper.Height;
    Custom := nil;
    FabricW := 0;
    FabricH := 0;
    if S.Container = ckImage then
    begin
      if FContainer.Load(ContainerPath) then
      begin
        Custom := FContainer;
        FabricW := FContainer.Width;
        FabricH := FContainer.Height;
      end
      else S.Container := ckNone;
    end;
    Frame := EvaluatePaperFrame(S, Video^.Object_^.Time);

    // 平面に戻ったら元のRGBAと元寸法で標準描画へ直接返す。
    if not Frame.ContainerVisible and Frame.PaperVisible and
      (Frame.Entrance >= 1) and (Frame.Pull >= 1) and (Frame.Unfold >= 1) and
      ((S.Crease <= 0) or (S.Fold = fkNone)) then
    begin
      Video^.SetImageData(FPaper.Pixels, ImageW, ImageH);
      Exit(1);
    end;

    if (S.Container <> ckNone) and
      ((FFootprintVersion <> FPaper.Version) or (FFold <> S.Fold)) then
    begin
      FoldedFootprint(S.Fold, ImageW, ImageH, FFoldedWidth, FFoldedHeight);
      FFootprintVersion := FPaper.Version;
      FFold := S.Fold;
    end;

    PlaceScene(S, Frame, ImageW, ImageH, FFoldedWidth, FFoldedHeight,
      FabricW, FabricH, PaperPose, Container);
    FMesh.Reset;
    Batch := 0;
    FillChar(Ranges, SizeOf(Ranges), 0);
    if Frame.ContainerVisible then
    begin
      AddContainer(False);
      if not Frame.Occluded then AddContainer(True);
    end;
    if Frame.PaperVisible then
    begin
      Ranges[Batch].First := FMesh.Count;
      Ranges[Batch].Depth := True;
      DrawPaper(FMesh, PaperPose, S, ImageW, ImageH, Frame.Unfold);
      Ranges[Batch].Count := FMesh.Count - Ranges[Batch].First;
      Inc(Batch);
    end;
    if Frame.ContainerVisible and Frame.Occluded then AddContainer(True);

    if FD3D.Render(Video, FMesh, FMesh.Canvas(ImageW, ImageH), Ranges, S, FPaper, Custom) then
      Result := 1;
  finally
    FLock.Release;
  end;
end;

function ProcVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
var
  Settings: TPaperSettings;
  PaperPath, ContainerPath: string;
begin
  Result := 0;
  if (Video = nil) or (Video^.Object_ = nil) or (Video^.UserData = nil) then Exit;
  try
    ReadPaperOpenParameters(Settings, PaperPath, ContainerPath);
    Result := TPaperSession(Video^.UserData).Render(Video, Settings, PaperPath, ContainerPath);
  except
    on E: Exception do OutputDebugString(PWideChar('SYNC_PaperOpen render: ' + E.Message));
  end;
end;

function CreateSession(EffectID: Int64): Pointer; cdecl;
begin
  Result := nil;
  try
    Result := TPaperSession.Create;
  except
    // DLL境界の外には生成失敗をnilで伝える。
  end;
end;

procedure DestroySession(EffectID: Int64; UserData: Pointer); cdecl;
begin
  try
    TPaperSession(UserData).Free;
  except
    // ホストへDelphi例外を返さない。
  end;
end;

function GetPaperOpenMediaTable: PFILTER_PLUGIN_TABLE;
begin
  if not Registered then
  begin
    SetupPluginTable(FILTER_FLAG_VIDEO or FILTER_FLAG_INPUT or FILTER_FLAG_USERDATA,
      '開封演出', 'SYNC', '開封演出 / SYNC_PaperOpen v1.0.0', ProcVideo, nil);
    RegisterPaperOpenParameters;
    GetPluginTable^.Func_Create := CreateSession;
    GetPluginTable^.Func_Destroy := DestroySession;
    Registered := True;
  end;
  Result := GetPluginTable;
end;

end.
