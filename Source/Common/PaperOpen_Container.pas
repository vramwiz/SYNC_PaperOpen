unit PaperOpen_Container;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 紙を包む前面、奥面、開口部を分けて生成する。取り出し中は前面で紙を隠す。

interface

uses PaperOpen_State, PaperOpen_Geometry;

type
  TContainerLayout = record
    Pose: TPose;
    W, H, DX, DY, Opening, ImageW, ImageH: Single;
    Kind: TContainerKind;
    Method: TOpeningKind;
    Base, Accent: Cardinal;
  end;

procedure PlaceScene(const S: TPaperSettings; const F: TPaperFrame;
  PaperW, PaperH, FoldedW, FoldedH, ImageW, ImageH: Single;
  out Paper: TPose; out Container: TContainerLayout);
procedure DrawContainer(Mesh: TPaperMesh; const C: TContainerLayout;
  Front: Boolean);

implementation

uses System.Math;

procedure ContainerSize(Kind: TContainerKind; FoldedW, FoldedH, ImageW,
  ImageH: Single; out W, H: Single);
var
  Fit: Single;
begin
  W := Max(FoldedW * 1.15, FoldedW + 2);
  H := Max(FoldedH * 1.22, FoldedH + 2);
  case Kind of
    ckWide, ckWax: W := Max(W, H * 1.65);
    ckTall:
      begin
        H := Max(H, W * 1.40);
        W := Max(W, H * 0.45);
      end;
    ckSquare: begin W := Max(W, H); H := W end;
    ckBag:
      begin
        H := Max(H * 1.15, W * 0.72);
        W := Max(W, H * 0.62);
      end;
    ckBox: begin W := W * 1.12; H := H * 1.12 end;
    ckTube: H := H * 1.08;
    ckImage:
      if (ImageW > 0) and (ImageH > 0) then
      begin
        Fit := Max(W / ImageW, H / ImageH);
        // 細長い素材の極端な拡大を抑え、素材の縦横比は常に維持する。
        Fit := Min(Fit, 3.5 * Max(W, H) / Max(ImageW, ImageH));
        W := ImageW * Fit;
        H := ImageH * Fit;
      end;
  end;
end;

procedure PlaceScene(const S: TPaperSettings; const F: TPaperFrame;
  PaperW, PaperH, FoldedW, FoldedH, ImageW, ImageH: Single;
  out Paper: TPose; out Container: TContainerLayout);
var
  W, H, DX, DY, Clearance, Span, P, Offset, Tip, DrawBack: Single;
  Sideways: Boolean;
  Entrance: TPose;
  Center: TVec3;
begin
  Container := Default(TContainerLayout);
  Span := Max(PaperW, PaperH) * 0.77;
  if S.Container = ckNone then
  begin
    Paper := EntrancePose(S.Entrance, F.Entrance, Span);
    Exit;
  end;

  DirectionVector(PaperDirection(S), DX, DY);
  Sideways := DX <> 0;
  ContainerSize(S.Container, FoldedW, FoldedH, ImageW, ImageH, W, H);
  if Sideways then
  begin
    Container.W := H;
    Container.H := W;
    Container.ImageW := ImageH;
    Container.ImageH := ImageW;
  end
  else
  begin
    Container.W := W;
    Container.H := H;
    Container.ImageW := ImageW;
    Container.ImageH := ImageH;
  end;
  Container.DX := DX;
  Container.DY := DY;
  Container.Kind := S.Container;
  Container.Method := S.Opening;
  Container.Base := S.BaseColor;
  Container.Accent := S.AccentColor;
  Container.Opening := Smooth(F.Opening);

  Tip := Abs(DX) * FoldedW + Abs(DY) * FoldedH;
  Clearance := 0.5 * (Container.H + Tip) + Max(2, Tip * 0.08);
  Entrance := EntrancePose(S.Entrance, F.Entrance, Max(Span, Max(W,H) * 0.7));
  Container.Pose := Entrance;
  DrawBack := Clearance * 0.38 * (1 - Smooth(F.Pull));
  Center := Entrance.Place(TVec3.At(-DX * (Clearance - DrawBack),
    -DY * (Clearance - DrawBack)));
  Container.Pose.X := Center.X;
  Container.Pose.Y := Center.Y;
  P := Smooth(F.Leaving);
  Offset := Max(W, H) * P;
  case S.Leaving of
    exFade: Container.Pose.Opacity := Container.Pose.Opacity * (1 - P);
    exDown:
      begin
        Container.Pose.Y := Container.Pose.Y + Max(W,H) * Sqr(F.Leaving) * 1.5;
        Container.Pose.Angle := Container.Pose.Angle + P * 0.55;
      end;
    exUp: Container.Pose.Y := Container.Pose.Y - Offset;
    exLeft: Container.Pose.X := Container.Pose.X - Offset;
    exRight: Container.Pose.X := Container.Pose.X + Offset;
    exShrink: Container.Pose.Scale := Container.Pose.Scale * (1 - P);
  end;
  if S.Leaving in [exDown, exUp, exLeft, exRight, exShrink] then
    Container.Pose.Opacity := Container.Pose.Opacity * (1 - Sqr(P));

  Paper := Default(TPose);
  Paper.Scale := 1;
  Paper.Opacity := 1;
  P := Smooth(F.Pull);
  Offset := (1 - P) * Clearance - DrawBack;
  Paper.X := -DX * Offset + DY * Tip * 0.08 * Sin(Pi * P);
  Paper.Y := -DY * Offset - DX * Tip * 0.08 * Sin(Pi * P);
  Paper.Angle := 0.075 * Sin(Pi * P) * (DX - DY);
end;

procedure DrawContainer(Mesh: TPaperMesh; const C: TContainerLayout;
  Front: Boolean);
var
  W, H, P, Z, Band, Edge, Lift, Turn, Angle, Slope, Curve, Arc, L, R: Single;
  Body, Dark, Inner, Rim: Cardinal;
  I: Integer;
  A, B: TVec3;

  function At(X, Y, Depth: Single): TVec3;
  begin
    Result := C.Pose.Place(TVec3.At(-C.DY * X - C.DX * Y,
      C.DX * X - C.DY * Y, Depth));
  end;

  function V(X, Y, Depth: Single; RGB: Cardinal; Opacity: Single = 1): TPaperVertex;
  begin
    Result := Vertex(At(X,Y,Depth),0,0,RGB,C.Pose.Opacity * Opacity);
  end;

  procedure Rect(L, T, R, B, Depth: Single; RGB: Cardinal);
  begin
    Mesh.Quad(V(L,T,Depth,RGB), V(R,T,Depth,RGB), V(R,B,Depth,RGB), V(L,B,Depth,RGB));
  end;

  procedure Line(X1, Y1, X2, Y2, Thick, Depth: Single; RGB: Cardinal;
    Opacity: Single = 1);
  var
    DX, DY, D: Single;
  begin
    DX := X2 - X1;
    DY := Y2 - Y1;
    D := Hypot(DX, DY);
    if D < 0.001 then Exit;
    D := Thick / D * 0.5;
    DX := DX * D;
    DY := DY * D;
    Mesh.Quad(V(X1-DY,Y1+DX,Depth,RGB,Opacity), V(X2-DY,Y2+DX,Depth,RGB,Opacity),
      V(X2+DY,Y2-DX,Depth,RGB,Opacity), V(X1+DY,Y1-DX,Depth,RGB,Opacity));
  end;

  procedure Seal(X, Y, Radius: Single; RGB: Cardinal; Opacity: Single);
  var
    J: Integer;
    A0, A1, R0, R1: Single;
  begin
    for J := 0 to 23 do
    begin
      A0 := J * Pi / 12;
      A1 := (J+1) * Pi / 12;
      R0 := Radius * (0.97 + 0.07 * Sin(7 * A0));
      R1 := Radius * (0.97 + 0.07 * Sin(7 * A1));
      Mesh.Triangle(V(X,Y,Z,Tint(RGB,1.1),Opacity),
        V(X+Cos(A0)*R0,Y+Sin(A0)*R0,Z,RGB,Opacity),
        V(X+Cos(A1)*R1,Y+Sin(A1)*R1,Z,RGB,Opacity));
    end;
  end;

  procedure Fastener;
  var
    Shift, Alpha: Single;
  begin
    if not ((C.Method = okTie) or (C.Kind = ckWax)) then Exit;
    if C.Method = okTie then Alpha := 1 - Smooth(Min(1.0, P * 1.8))
    else Alpha := 1 - Smooth(P);
    if Alpha <= 0 then Exit;
    Shift := P * W * 0.34;
    if C.Kind = ckWax then
    begin
      Seal(Shift, -H * 0.14 + P * H * 0.25, Edge * 3.2, C.Accent, Alpha);
      Seal(Shift, -H * 0.14 + P * H * 0.25, Edge * 1.9, Tint(C.Accent,0.83), Alpha);
    end
    else
    begin
      Line(-W + Shift,-H * 0.66,W - Shift,-H * 0.66,Edge,Z,C.Accent,Alpha);
      Line(0,-H * 0.66,-Edge*4,-H * 0.66 + Edge*2,Edge*0.7,Z,C.Accent,Alpha);
      Line(0,-H * 0.66,Edge*4,-H * 0.66 + Edge*2,Edge*0.7,Z,C.Accent,Alpha);
      Seal(0,-H * 0.66,Edge * 0.95,C.Accent,Alpha);
    end;
  end;

  procedure Flap;
  var
    Y, Depth: Single;
    Color: Cardinal;
  begin
    Angle := Pi * 0.88 * P;
    if C.Method = okTie then Angle := Pi * 0.88 * Smooth(Max(0.0, (P-0.28)/0.72));
    if C.Method = okLid then Angle := Pi * 0.70 * P;
    if C.Method = okPull then Angle := Pi * 0.61;
    // 前面の蓋は90度を越えた時点で奥面のバッチへ移す。
    if Front <> (Cos(Angle) >= 0) then Exit;
    if C.Kind = ckBox then Band := H * 1.86;
    if C.Kind = ckBag then Band := H * 0.35;
    Y := -H + Band * Cos(Angle);
    Depth := Band * Sin(Angle);
    Color := Tint(Body, 1.02 - 0.24 * Sin(Angle));
    if C.Kind in [ckWide, ckTall, ckSquare, ckWax] then
    begin
      Mesh.Triangle(V(-W,-H,0,Rim), V(W,-H,0,Rim), V(0,Y,Depth,Color));
      Line(-W,-H,W,-H,Edge * 0.36,Z,Dark);
    end
    else
      Mesh.Quad(V(-W,-H,0,Rim), V(W,-H,0,Rim), V(W,Y,Depth,Color), V(-W,Y,Depth,Color));
  end;

  procedure CustomImage;
    function ImageVert(X, Y, U, V: Single; Alpha: Single = 1): TPaperVertex;
    var
      TU, TV: Single;
    begin
      TU := U;
      TV := V;
      // 画像本体の向きは取り出し方向の変更に追従させない。
      if C.DX > 0 then begin TU := 1-V; TV := U end;
      if C.DX < 0 then begin TU := V; TV := 1-U end;
      if C.DY > 0 then begin TU := 1-U; TV := 1-V end;
      Result := Vertex(At(X,Y,Z), TU, TV, $FFFFFF, C.Pose.Opacity * Alpha, 2);
    end;
  var
    Seam, Lifted: Single;
  begin
    Seam := -H + Band * 0.25;
    Lifted := Seam - Band * P;
    if C.Method in [okNone, okPull] then Lifted := -H;
    if Front then
    begin
      if C.Method in [okNone, okPull] then
        Mesh.Quad(ImageVert(-W,-H,0,0), ImageVert(W,-H,1,0),
          ImageVert(W,H,1,1), ImageVert(-W,H,0,1))
      else
        Mesh.Quad(ImageVert(-W,Seam,0,(Seam+H)/(2*H)),
          ImageVert(W,Seam,1,(Seam+H)/(2*H)), ImageVert(W,H,1,1), ImageVert(-W,H,0,1));
    end
    else if C.Method = okCut then
    begin
      if P < 1 then
        Mesh.Quad(ImageVert(-W,-H-P*Band,0,0,1-P), ImageVert(W,-H-P*Band,1,0,1-P),
          ImageVert(W,Seam-P*Band,1,(Seam+H)/(2*H),1-P),
          ImageVert(-W,Seam-P*Band,0,(Seam+H)/(2*H),1-P));
    end
    else if not (C.Method in [okNone, okPull]) then
      Mesh.Quad(ImageVert(-W,Lifted,0,0), ImageVert(W,Lifted,1,0),
        ImageVert(W,Seam,1,(Seam+H)/(2*H)), ImageVert(-W,Seam,0,(Seam+H)/(2*H)));
  end;

begin
  if (C.Pose.Opacity <= 0) or (C.Pose.Scale <= 0) then Exit;
  W := C.W * 0.5;
  H := C.H * 0.5;
  P := C.Opening;
  Z := 0;
  Band := H * 1.10;
  Edge := Max(0.65, Min(W,H) * 0.035);
  Body := C.Base;
  Rim := Tint(Body,1.16);
  Dark := Tint(Body,0.58);
  Inner := Tint(Body,0.73);
  if C.Kind = ckImage then
  begin
    CustomImage;
    Exit;
  end;

  if not Front then
  begin
    if C.Kind <> ckTube then Rect(-W,-H,W,H,0,Inner);
    if (C.Kind = ckTube) and (P > 0) then
      for I := 0 to 19 do
      begin
        Slope := (I + 0.5) / 10 - 1;
        Curve := Sqrt(1 - Sqr(Slope));
        Rect(W*(I/10-1),-H-Edge*Curve,W*((I+1)/10-1),-H+Edge*6.8,0,Dark);
      end;
    if C.Kind = ckBox then
      Rect(-W+Edge,-H+Edge,W-Edge,-H*0.57,0,Dark);
  end;

  if Front then
  begin
    Lift := Edge * (1 + P * 4);
    if C.Method = okCut then Lift := Edge * (2.8 + P * 2);
    case C.Kind of
      ckTube:
        begin
          Arc := Min(W * 0.22, H * 0.22);
          for I := 0 to 19 do
          begin
            Slope := (I + 0.5) / 10 - 1;
            Curve := Sqrt(1 - Sqr(Slope));
            L := W * (I/10-1);
            R := L + W/10;
            Rect(L,-H+Lift+Arc*0.32*Curve,R,H-Arc*(1-Curve),0,
              Tint(Body,0.69 + 0.40 * Curve - 0.12 * Slope));
            Rect(L,H-Arc*(1-Curve)-Edge*2,R,H-Arc*(1-Curve),0,
              Tint(C.Accent,0.68 + Curve*0.27));
          end;
        end;
      ckBox:
        begin
          Rect(-W,-H+Lift,W,H,0,Rim);
          Rect(-W+Edge,-H+Lift+Edge,W-Edge,H-Edge,0,Body);
          Rect(-W+Edge,H-Edge*4,W-Edge,H-Edge,0,Tint(Body,0.82));
          Rect(-Edge*3,-H+Lift+Edge,-Edge,-H+Lift+Edge*2.4,0,C.Accent);
          Rect(Edge,-H+Lift+Edge,Edge*3,-H+Lift+Edge*2.4,0,C.Accent);
        end;
      ckBag:
        begin
          Rect(-W,-H+Lift,W,H,0,Body);
          Mesh.Triangle(V(-W,-H+Lift,0,Rim), V(-W+Edge*3,H,0,Inner), V(-W,H,0,Dark));
          Mesh.Triangle(V(W,-H+Lift,0,Rim), V(W-Edge*3,H,0,Inner), V(W,H,0,Dark));
          Line(-W+Edge*3,H-Edge*3,W-Edge*3,H-Edge*3,Edge * 0.50,0,Inner);
        end;
    else
      Rect(-W,-H+Lift,W,H,0,Body);
      Mesh.Triangle(V(-W-0.01,H,0,Rim),V(0,-H*0.05,0,Rim),V(W,H,0,Tint(Body,1.08)));
      Line(-W,H,0,-H*0.05,Edge*0.35,0,Inner);
      Line(0,-H*0.05,W,H,Edge*0.35,0,Inner);
      Line(-W+Edge,H-Edge,W-Edge,H-Edge,Edge*0.33,0,Tint(C.Accent,0.89),0.46);
    end;
    if C.Kind <> ckTube then Line(-W,-H+Lift,W,-H+Lift,Edge*0.42,0,Dark);
  end;

  if C.Method = okCut then
  begin
    if Front and (P < 1) then
    begin
      Turn := -P * H * 0.82;
      A := TVec3.At(-W,-H+Turn);
      B := TVec3.At(W,-H+Turn + P*W*0.21);
      Mesh.Quad(V(A.X,A.Y,Z,C.Accent,1-P), V(B.X,B.Y,Z,C.Accent,1-P),
        V(B.X,B.Y+Edge*3,Z,Body,1-P), V(A.X,A.Y+Edge*3,Z,Body,1-P));
    end;
  end
  else if (C.Kind = ckTube) and not (C.Method in [okNone,okPull]) then
  begin
    if Front or (P >= 1) then Exit;
    Turn := -H - P * H * 0.82;
    Rect(-W-Edge,Turn-Edge*1.5,W+Edge,Turn+Edge*2.4,C.H*P*0.07,Dark);
    Rect(-W,Turn-Edge,W,Turn+Edge,C.H*P*0.07,C.Accent);
  end
  else if not (C.Method in [okNone,okPull]) or
    ((C.Method = okNone) and (C.Kind in [ckWide,ckTall,ckSquare,ckWax,ckBox])) then
    Flap;

  if Front then Fastener;
end;

end.
