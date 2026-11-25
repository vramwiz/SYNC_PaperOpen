unit PaperOpen_State;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// プリセットと進行状態。全位相をオブジェクト内の秒から独立して評価する。

interface

type
  TContainerKind = (ckNone, ckWide, ckTall, ckSquare, ckWax, ckBag, ckBox,
    ckTube, ckImage);
  TOpeningKind = (okNone, okTop, okSide, okLid, okCut, okTie, okPull);
  TFoldKind = (fkNone, fkHalfV, fkHalfH, fkThirdV, fkThirdH, fkQuarter,
    fkAccordion, fkEighth, fkScroll, fkRoll, fkCrumple, fkTurn);
  TEntranceKind = (enStatic, enFade, enTop, enBottom, enLeft, enRight,
    enFloat, enFly);
  TDirection = (diAuto, diUp, diDown, diLeft, diRight);
  TExitKind = (exStay, exInstant, exFade, exDown, exUp, exLeft, exRight, exShrink);
  TPhase = (phEntrance, phOpening, phPull, phUnfold, phExit);

  TPaperSettings = record
    Container: TContainerKind;
    Opening: TOpeningKind;
    Fold: TFoldKind;
    Entrance: TEntranceKind;
    Direction: TDirection;
    Leaving: TExitKind;
    BaseColor, AccentColor: Cardinal; // RGB
    Seconds: array[TPhase] of Double;
    Crease: Double; // 0..1
    ContainerScale: Single; // 1 = 100%
  end;

  TPaperFrame = record
    Entrance, Opening, Pull, Unfold, Leaving: Single; // 0..1
    ContainerVisible, PaperVisible, Occluded: Boolean;
  end;

const
  PRESET_COUNT = 12;
  MAX_SECONDS = 60;

function PaperPreset(Index: Integer): TPaperSettings;
function EvaluatePaperFrame(const S: TPaperSettings; Time: Double): TPaperFrame;
function PaperDirection(const S: TPaperSettings): TDirection;
function Smooth(Value: Single): Single;
function Bounded(Value, Limit: Double): Double;

implementation

uses System.Math;

function Bounded(Value, Limit: Double): Double;
begin
  if IsNan(Value) then Exit(0);
  Result := EnsureRange(Value, 0, Limit);
end;

function PaperPreset(Index: Integer): TPaperSettings;
var
  Phase: TPhase;
begin
  Result := Default(TPaperSettings);
  Result.Container := ckWide;
  Result.Opening := okTop;
  Result.Fold := fkThirdH;
  Result.Entrance := enFade;
  Result.Leaving := exFade;
  Result.BaseColor := $F0DFBC;
  Result.AccentColor := $AE5545;
  Result.ContainerScale := 1;
  for Phase := Low(TPhase) to High(TPhase) do
    Result.Seconds[Phase] := 1;
  case Index of
    0: Result.Entrance := enStatic;
    1:
      begin
        Result.Container := ckTall;
        Result.Fold := fkThirdV;
        Result.BaseColor := $EFE8D5;
      end;
    2:
      begin
        Result.Container := ckWax;
        Result.Opening := okTie;
        Result.BaseColor := $E1C794;
        Result.AccentColor := $922D44;
        Result.Seconds[phOpening] := 1.25;
      end;
    3:
      begin
        Result.Container := ckSquare;
        Result.Fold := fkHalfV;
        Result.BaseColor := $F3E4DF;
        Result.AccentColor := $AA7A4D;
      end;
    4:
      begin
        Result.Opening := okCut;
        Result.Fold := fkQuarter;
        Result.BaseColor := $B98851;
        Result.AccentColor := $884338;
        Result.Entrance := enRight;
        Result.Seconds[phOpening] := 0.65;
      end;
    5:
      begin
        Result.Container := ckBox;
        Result.Opening := okLid;
        Result.Fold := fkHalfH;
        Result.BaseColor := $546779;
        Result.AccentColor := $CFAB76;
        Result.Leaving := exDown;
      end;
    6:
      begin
        Result.Container := ckBag;
        Result.Opening := okTie;
        Result.Fold := fkQuarter;
        Result.BaseColor := $CCA375;
        Result.AccentColor := $754B3A;
        Result.Leaving := exLeft;
      end;
    7:
      begin
        Result.Container := ckTube;
        Result.Opening := okLid;
        Result.Direction := diRight;
        Result.Fold := fkRoll;
        Result.BaseColor := $C99D65;
        Result.AccentColor := $75462B;
        Result.Crease := 0.18;
        Result.Seconds[phUnfold] := 1.35;
      end;
    8:
      begin
        Result.Container := ckNone;
        Result.Opening := okNone;
        Result.Fold := fkScroll;
        Result.BaseColor := $DCBA80;
        Result.AccentColor := $644332;
        Result.Entrance := enTop;
        Result.Seconds[phUnfold] := 1.4;
      end;
    9:
      begin
        Result.Container := ckNone;
        Result.Opening := okNone;
        Result.Fold := fkEighth;
        Result.BaseColor := $D4D0C6;
        Result.Crease := 0.35;
        Result.Entrance := enBottom;
        Result.Seconds[phUnfold] := 1.35;
      end;
    10:
      begin
        Result.Container := ckNone;
        Result.Opening := okNone;
        Result.Fold := fkCrumple;
        Result.Entrance := enRight;
        Result.Crease := 0.25;
        Result.Seconds[phUnfold] := 1.2;
      end;
    11:
      begin
        Result.Container := ckNone;
        Result.Opening := okNone;
        Result.Fold := fkTurn;
        Result.Entrance := enFloat;
        Result.Seconds[phEntrance] := 1.5;
      end;
  end;
end;

function Smooth(Value: Single): Single;
begin
  Result := Value * Value * (3 - 2 * Value);
end;

function EvaluatePaperFrame(const S: TPaperSettings; Time: Double): TPaperFrame;
  function Advance(Phase: TPhase; Enabled: Boolean): Single;
  var
    Duration: Double;
  begin
    if not Enabled then Exit(1);
    Duration := Bounded(S.Seconds[Phase], MAX_SECONDS);
    if Duration = 0 then Exit(Ord(Time >= 0));
    Result := Bounded(Time / Duration, 1);
    Time := Time - Duration;
  end;
var
  HasContainer, AnimateOpening, PulledOut: Boolean;
  SincePull: Double;
begin
  Result := Default(TPaperFrame);
  if IsNan(Time) or IsInfinite(Time) then Time := 0;
  Time := Max(Time, 0);
  HasContainer := S.Container <> ckNone;
  AnimateOpening := HasContainer and not (S.Opening in [okNone, okPull]);
  Result.Entrance := Advance(phEntrance, S.Entrance <> enStatic);
  Result.Opening := 0;
  if AnimateOpening then
    Result.Opening := Advance(phOpening, True)
  else if S.Opening = okPull then
    Result.Opening := 0.15;
  Result.Pull := Advance(phPull, HasContainer);
  SincePull := Time;
  PulledOut := SincePull >= 0;
  Result.Unfold := Advance(phUnfold, S.Fold <> fkNone);
  Result.PaperVisible := not HasContainer or (Result.Pull > 0) and
    (Result.Entrance >= 1) and (not AnimateOpening or (Result.Opening >= 1));
  Result.Occluded := HasContainer and not PulledOut;
  Result.ContainerVisible := HasContainer;
  if HasContainer and PulledOut and (S.Leaving <> exStay) then
  begin
    Time := SincePull;
    Result.Leaving := Advance(phExit, S.Leaving <> exInstant);
    Result.ContainerVisible := Result.Leaving < 1;
  end;
end;

function PaperDirection(const S: TPaperSettings): TDirection;
begin
  Result := S.Direction;
  if Result = diAuto then
    if S.Opening = okSide then Result := diRight
    else Result := diUp;
end;

end.
