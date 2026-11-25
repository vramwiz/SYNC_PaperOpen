unit PaperOpen_Paper;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 紙のUVを固定し、折り畳み・巻き・平面への復帰を連続した面で生成する。

interface

uses PaperOpen_State, PaperOpen_Geometry;

procedure FoldDivisions(Kind: TFoldKind; out Columns, Rows: Integer);
function PaperPoint(Kind: TFoldKind; W, H, U, V, Folded: Single): TVec3;
procedure FoldedFootprint(Kind: TFoldKind; W, H: Single;
  out Width, Height: Single);
procedure DrawPaper(Mesh: TPaperMesh; const Pose: TPose; const S: TPaperSettings;
  W, H, Unfold: Single);

implementation

uses System.Math;

procedure FoldDivisions(Kind: TFoldKind; out Columns, Rows: Integer);
begin
  Columns := 1;
  Rows := 1;
  case Kind of
    fkHalfV: Columns := 2;
    fkHalfH: Rows := 2;
    fkThirdV: Columns := 3;
    fkThirdH: Rows := 3;
    fkQuarter: begin Columns := 2; Rows := 2 end;
    fkAccordion: Columns := 6;
    fkEighth: begin Columns := 2; Rows := 4 end;
    fkPlane: begin Columns := 4; Rows := 4 end;
  end;
end;

function HingeAngle(Index, Count: Integer; Bellows: Boolean): Single;
begin
  if Bellows then
  begin
    if Odd(Index) then Exit(-Pi * 0.473);
    Exit(Pi * 0.473);
  end;
  case Count of
    2: if Index = 0 then Exit(-Pi * 0.968);
    3:
      begin
        if Index = 0 then Exit(-Pi * 0.965);
        if Index = 2 then Exit(Pi * 0.945);
      end;
    4: if Odd(Index) then Exit(Pi * 0.973);
  end;
  Result := 0;
end;

procedure FoldAxis(U, Size, Folded: Single; Count: Integer; Bellows: Boolean;
  out Position, Depth, Angle: Single);
var
  I: Integer;
  Segment, FullX, Prefix, Theta, S, C, Middle: Single;
begin
  if Count = 1 then
  begin
    Position := (U - 0.5) * Size;
    Depth := 0;
    Angle := 0;
    Exit;
  end;
  Segment := Size / Count;
  Position := 0;
  FullX := 0;
  Depth := 0;
  Angle := 0;
  Prefix := U * Count;
  for I := 0 to Count - 1 do
  begin
    Theta := Folded * HingeAngle(I, Count, Bellows);
    SinCos(Theta, S, C);
    Position := Position + Segment * C * EnsureRange(Prefix - I, 0, 1);
    Depth := Depth + Segment * S * EnsureRange(Prefix - I, 0, 1);
    FullX := FullX + Segment * C;
    if I = Min(Trunc(Prefix), Count - 1) then Angle := Theta;
  end;
  // C折りは中央のパネル、二つ折りは折り返し側のパネルを中心へ置く。
  Middle := FullX * 0.5;
  if Count = 2 then
    Middle := Mix(Size * 0.5, Segment * 0.5 * Cos(Folded * HingeAngle(0, Count, False)), Folded);
  if Count = 3 then
    Middle := Mix(Size * 0.5, Segment * (0.5 + Cos(Folded * HingeAngle(0, Count, False))), Folded);
  Position := Position - Middle;

  // 各パネルの奥行きを保ちながら、折り終わりの重心を原点付近へ戻す。
  Depth := Depth + Segment * Folded * 0.23 * Ord(Count in [2, 3]);
end;

function PaperPoint(Kind: TFoldKind; W, H, U, V, Folded: Single): TVec3;
var
  X, Y, Z, A, B, DZ, T, Radius, C, S, Warp, Span: Single;
  NX, NY: Integer;
begin
  X := (U - 0.5) * W;
  Y := (V - 0.5) * H;
  Result := TVec3.At(X, Y);
  if (Folded <= 0) or (Kind = fkNone) then Exit;
  case Kind of
    fkHalfV..fkEighth:
      begin
        FoldDivisions(Kind, NX, NY);
        FoldAxis(U, W, Folded, NX, Kind = fkAccordion, X, Z, A);
        FoldAxis(V, H, Folded, NY, False, Y, DZ, B);
        Result := TVec3.At(X, Y - Z * Sin(B), DZ + Z * Cos(B));
      end;
    fkScroll, fkRoll:
      begin
        T := V - 0.5;
        if Kind = fkScroll then
        begin
          // 巻物は中央から開き、両端に反対向きの巻きが残る。
          Span := (1 - Folded) * 0.49;
          if Abs(T) <= Span then Exit;
          A := (Abs(T) - Span) * 6.9 * Folded;
          Radius := H / (6.9 * Folded);
          Result.Y := Sign(T) * (Span * H + Radius * Sin(A));
        end
        else
        begin
          A := T * 7.0 * Folded;
          Radius := H / (7.0 * Folded);
          Result.Y := Radius * Sin(A);
          Radius := Radius * (0.94 + 0.12 * V);
        end;
        Result.Z := Radius * (1 - Cos(A));
      end;
    fkCrumple:
      begin
        Warp := Min(W, H) * Folded;
        Result.X := X * (1 - 0.68 * Folded) +
          Warp * 0.085 * Sin(30 * U + 16 * V) * Sin(Pi * U);
        Result.Y := Y * (1 - 0.68 * Folded) +
          Warp * 0.08 * Cos(20 * U - 35 * V) * Sin(Pi * V);
        Result.Z := Warp * (0.11 * Sin(24 * U + 17 * V) +
          0.06 * Cos(34 * U - 28 * V) + 0.09 * Cos(7 * (U - V)));
      end;
    fkPlane:
      begin
        // 背筋と斜めの翼を持つ形。UVの左右を対称に折って前端を絞る。
        A := Folded * (0.42 + 0.78 * (1 - V));
        SinCos(A, S, C);
        Result.X := X * C * (1 - Folded * 0.98 * (1 - V));
        Result.Y := Y * (1 - 0.26 * Folded) +
          Abs(U - 0.5) * H * Folded * (0.18 - 0.50 * V);
        Result.Z := -Abs(X) * S * 0.80;
      end;
    fkTurn:
      begin
        A := Pi * Folded + Sin(Pi * U) * Sin(Pi * Folded) * 0.52;
        SinCos(A, S, C);
        Result.X := X * C;
        Result.Z := -X * S + Min(W, H) * 0.11 * Sin(Pi * Folded) *
          Sin(Pi * U) * Sin(Pi * V);
      end;
  end;
end;

procedure FoldedFootprint(Kind: TFoldKind; W, H: Single;
  out Width, Height: Single);
var
  I, J: Integer;
  P: TVec3;
begin
  if Kind = fkNone then
  begin
    Width := W;
    Height := H;
    Exit;
  end;
  Width := 0;
  Height := 0;
  for J := 0 to 24 do
    for I := 0 to 24 do
    begin
      P := PaperPoint(Kind, W, H, I / 24, J / 24, 1);
      Width := Max(Width, 2 * Abs(P.X + P.Z * 0.12));
      Height := Max(Height, 2 * Abs(P.Y - P.Z * 0.24));
    end;
end;

procedure DrawPaper(Mesh: TPaperMesh; const Pose: TPose; const S: TPaperSettings;
  W, H, Unfold: Single);
var
  Points: array[0..40, 0..24] of TVec3;
  I, J, NX, NY: Integer;
  A, B, C, D: TVec3;
  U0, U1, V0, V1, Folded, Light: Single;
begin
  if Pose.Opacity <= 0 then Exit;
  Folded := 1 - Smooth(Unfold);
  FoldDivisions(S.Fold, NX, NY);
  if Folded > 0 then
    case S.Fold of
      fkScroll, fkRoll: NY := 40;
      fkCrumple: begin NX := 24; NY := 24 end;
      fkPlane: begin NX := 16; NY := 16 end;
      fkTurn: begin NX := 20; NY := 10 end;
    end
  else
  begin
    NX := 1;
    NY := 1;
  end;
  for J := 0 to NY do
    for I := 0 to NX do
      Points[J,I] := Pose.Place(PaperPoint(S.Fold, W, H, I / NX, J / NY, Folded));
  for J := 0 to NY - 1 do
    for I := 0 to NX - 1 do
    begin
      A := Points[J,I];
      B := Points[J,I+1];
      C := Points[J+1,I+1];
      D := Points[J+1,I];
      U0 := I / NX;
      U1 := (I + 1) / NX;
      V0 := J / NY;
      V1 := (J + 1) / NY;
      Light := Mix(1, FacingLight(A,B,D), Min(1.0, Folded * 4));
      Mesh.Quad(Vertex(A,U0,V0,S.BaseColor,Pose.Opacity,1,Light),
        Vertex(B,U1,V0,S.BaseColor,Pose.Opacity,1,Light),
        Vertex(C,U1,V1,S.BaseColor,Pose.Opacity,1,Light),
        Vertex(D,U0,V1,S.BaseColor,Pose.Opacity,1,Light));
    end;
end;

end.
