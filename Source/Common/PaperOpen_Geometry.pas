unit PaperOpen_Geometry;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// メッシュの座標系、頂点の再利用、標準描画用キャンバスの寸法を管理する。

interface

uses PaperOpen_State;

type
  TVec3 = record
    X, Y, Z: Single;
    class function At(AX, AY: Single; AZ: Single = 0): TVec3; static;
  end;

  TPaperVertex = record
    Position: TVec3;
    U, V: Single;
    R, G, B, A: Single;
    Material, Light: Single;
  end;

  TPose = record
    X, Y, Angle, Scale, Opacity: Single;
    function Place(const P: TVec3): TVec3;
  end;

  TCanvas = record
    Width, Height: Integer;
  end;

  TPaperMesh = class
  private
    FData: TArray<TPaperVertex>;
    FCount: Integer;
    FExtentX, FExtentY, FDepth: Single;
    procedure Push(const Source: TPaperVertex);
  public
    procedure Reset;
    procedure Triangle(const A, B, C: TPaperVertex);
    procedure Quad(const A, B, C, D: TPaperVertex);
    function Data: Pointer;
    function Canvas(ImageWidth, ImageHeight: Integer): TCanvas;
    property Count: Integer read FCount;
    property Depth: Single read FDepth;
  end;

function Vertex(const P: TVec3; U, V: Single; RGB: Cardinal;
  Opacity: Single; Material: Integer = 0; Light: Single = 1): TPaperVertex;
function FacingLight(const A, B, C: TVec3): Single;
function Tint(RGB: Cardinal; Value: Single): Cardinal;
function EntrancePose(Kind: TEntranceKind; Progress, Span: Single): TPose;
procedure DirectionVector(Direction: TDirection; out X, Y: Single);
function Mix(A, B, T: Single): Single;

implementation

uses System.Math, PaperOpen_Image;

class function TVec3.At(AX, AY, AZ: Single): TVec3;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.Z := AZ;
end;

function Mix(A, B, T: Single): Single;
begin
  Result := A + (B - A) * T;
end;

function TPose.Place(const P: TVec3): TVec3;
var
  S, C: Single;
begin
  SinCos(Angle, S, C);
  Result := TVec3.At(X + Scale * (C * P.X - S * P.Y),
    Y + Scale * (S * P.X + C * P.Y), Scale * P.Z);
end;

function Vertex(const P: TVec3; U, V: Single; RGB: Cardinal;
  Opacity: Single; Material: Integer; Light: Single): TPaperVertex;
begin
  Result.Position := P;
  Result.U := U;
  Result.V := V;
  Result.R := ((RGB shr 16) and $FF) / 255;
  Result.G := ((RGB shr 8) and $FF) / 255;
  Result.B := (RGB and $FF) / 255;
  Result.A := Opacity;
  Result.Material := Material;
  Result.Light := Light;
end;

function FacingLight(const A, B, C: TVec3): Single;
var
  X, Y, Z, Magnitude: Single;
begin
  X := (B.Y - A.Y) * (C.Z - A.Z) - (B.Z - A.Z) * (C.Y - A.Y);
  Y := (B.Z - A.Z) * (C.X - A.X) - (B.X - A.X) * (C.Z - A.Z);
  Z := (B.X - A.X) * (C.Y - A.Y) - (B.Y - A.Y) * (C.X - A.X);
  Magnitude := Sqrt(Sqr(X) + Sqr(Y) + Sqr(Z));
  if Magnitude < 0.00001 then Exit(1);
  Result := EnsureRange(0.65 + 0.35 * Abs((X * 0.30 + Y * 0.46 + Z) /
    Magnitude), 0.65, 1.09);
end;

function Tint(RGB: Cardinal; Value: Single): Cardinal;
  function Component(Shift: Integer): Cardinal;
  begin
    Result := EnsureRange(Round(((RGB shr Shift) and $FF) * Value), 0, 255);
  end;
begin
  Result := (Component(16) shl 16) or (Component(8) shl 8) or Component(0);
end;

function EntrancePose(Kind: TEntranceKind; Progress, Span: Single): TPose;
var
  P, Rest: Single;
begin
  P := Smooth(Progress);
  Rest := 1 - P;
  Result := Default(TPose);
  Result.Scale := 1;
  Result.Opacity := 1;
  case Kind of
    enFade: Result.Opacity := P;
    enTop: Result.Y := -Span * Rest;
    enBottom: Result.Y := Span * Rest;
    enLeft: Result.X := -Span * Rest;
    enRight: Result.X := Span * Rest;
    enFloat:
      begin
        Result.Y := -Span * Rest;
        Result.X := Span * (0.16 * Sin(2.6 * Pi * P) - 0.12) * Rest;
        Result.Angle := 0.50 * Sin(3 * Pi * P + 0.65) * Rest;
        Result.Opacity := Smooth(Min(1.0, Progress * 4));
      end;
    enFly:
      begin
        Result.X := -Span * 1.3 * Rest;
        Result.Y := -Span * (0.42 * Rest + 0.22 * Sin(Pi * P));
        Result.Angle := (-0.55 + 0.36 * Sin(Pi * P)) * Rest;
        Result.Scale := 1 - 0.22 * Rest;
        Result.Opacity := Smooth(Min(1.0, Progress * 6));
      end;
  end;
end;

procedure DirectionVector(Direction: TDirection; out X, Y: Single);
begin
  X := 0;
  Y := 0;
  case Direction of
    diDown: Y := 1;
    diLeft: X := -1;
    diRight: X := 1;
  else
    Y := -1;
  end;
end;

procedure TPaperMesh.Reset;
begin
  FCount := 0;
  FExtentX := 0;
  FExtentY := 0;
  FDepth := 1;
end;

procedure TPaperMesh.Push(const Source: TPaperVertex);
var
  P: TPaperVertex;
begin
  P := Source;
  // 固定した斜投影。ZはGPUの深度比較にも別途使用する。
  P.Position.X := P.Position.X + P.Position.Z * 0.12;
  P.Position.Y := P.Position.Y - P.Position.Z * 0.24;
  FExtentX := Max(FExtentX, Abs(P.Position.X));
  FExtentY := Max(FExtentY, Abs(P.Position.Y));
  FDepth := Max(FDepth, Abs(P.Position.Z));
  FData[FCount] := P;
  Inc(FCount);
end;

procedure TPaperMesh.Triangle(const A, B, C: TPaperVertex);
begin
  if FCount + 3 > Length(FData) then
    SetLength(FData, Max(768, Length(FData) * 2));
  Push(A);
  Push(B);
  Push(C);
end;

procedure TPaperMesh.Quad(const A, B, C, D: TPaperVertex);
begin
  Triangle(A, B, C);
  Triangle(A, C, D);
end;

function TPaperMesh.Data: Pointer;
begin
  Result := Pointer(FData);
end;

function TPaperMesh.Canvas(ImageWidth, ImageHeight: Integer): TCanvas;
  function Side(Extent: Single; ImageSide: Integer): Integer;
  var
    Parity: Integer;
  begin
    // 同じ偶奇を維持して元画像のテクセル中心と標準描画の中心を揃える。
    Parity := ImageSide mod 2;
    Result := Min(MAX_IMAGE_SIDE - Parity, ((Ceil(Extent * 2) + 3 + 31) div 32) *
      32 + Parity);
  end;
var
  Scale: Double;
begin
  Result.Width := Side(FExtentX, ImageWidth);
  Result.Height := Side(FExtentY, ImageHeight);
  if Int64(Result.Width) * Result.Height > MAX_IMAGE_PIXELS then
  begin
    Scale := Sqrt(MAX_IMAGE_PIXELS / (Double(Result.Width) * Result.Height));
    Result.Width := Max(2, Trunc(Result.Width * Scale) div 2) * 2 -
      (ImageWidth mod 2);
    Result.Height := Max(2, Trunc(Result.Height * Scale) div 2) * 2 -
      (ImageHeight mod 2);
  end;
end;

end.
