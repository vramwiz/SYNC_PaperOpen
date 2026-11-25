unit PaperOpen_Parameters;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// SDK項目の登録と、ボタンから指定されたエフェクトへのプリセット反映。

interface

uses PaperOpen_State;

procedure RegisterPaperOpenParameters;
procedure ReadPaperOpenParameters(out S: TPaperSettings; out PaperFile, ContainerFile: string);

implementation

uses System.Math, System.SysUtils, Winapi.Windows, AviUtl2FilterTypes, PluginFilterTable;

type
  TSelector = (sePreset, seContainer, seOpening, seFold, seEntrance, seDirection,
    seLeaving);

const
  Names: array[TSelector] of PWideChar = (
    'プリセット', '入れ物の種類', '開封方法', '展開方法', '登場方法', '取り出し方向',
    '退場方法');
  PhaseNames: array[TPhase] of PWideChar = (
    '登場時間', '開封時間', '取り出し時間', '展開時間', '退場時間');
  PresetNames: array[0..PRESET_COUNT-1] of PWideChar = (
    '横長封筒の手紙', '縦長封筒の手紙', '封蝋付きの手紙', '招待状', '極秘書類',
    '箱に入った書類', '紙袋に入った書類', '宝の地図', '巻物', '折りたたまれた新聞',
    'くしゃくしゃの紙', '舞い降りる紙');
  ContainerNames: array[TContainerKind] of PWideChar = ('なし', '横長封筒',
    '縦長封筒', '正方形封筒', '封蝋付き封筒', '紙袋', '箱', '筒状ケース',
    'ユーザー指定画像');
  OpeningNames: array[TOpeningKind] of PWideChar = ('開封なし', '上部を開く',
    '側面を開く', '蓋を開く', '上部を切り離す', '紐をほどく',
    '開口部から取り出すだけ');
  FoldNames: array[TFoldKind] of PWideChar = ('折りたたみなし', '二つ折り（縦）',
    '二つ折り（横）', '三つ折り（縦）', '三つ折り（横）', '四つ折り', '蛇腹折り',
    '八つ折り', '巻物を広げる', '丸めた紙を広げる', 'くしゃくしゃの紙を広げる',
    '裏返しの紙をめくる');
  EntranceNames: array[TEntranceKind] of PWideChar = ('最初から表示',
    'フェードイン', '上から登場', '下から登場', '左から登場', '右から登場',
    '舞い降りる', '飛来する');
  DirectionNames: array[TDirection] of PWideChar = ('自動', '上', '下', '左', '右');
  ExitNames: array[TExitKind] of PWideChar = ('そのまま残す', '即時消去',
    'フェードアウト', '下方向へ落下', '上方向へ移動', '左方向へ移動',
    '右方向へ移動', '縮小消失');
  IMAGE_FILTER: PWideChar =
    '画像ファイル (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp;*.ico)'#0 +
    '*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp;*.ico'#0 +
    'すべてのファイル (*.*)'#0'*.*'#0#0;

var
  Selectors: array[TSelector] of TFILTER_ITEM_SELECT;
  Options: array[TSelector, 0..PRESET_COUNT] of TFILTER_ITEM_SELECT_ITEM;
  OptionCounts: array[TSelector] of Integer;
  Tracks: array[TPhase] of TFILTER_ITEM_TRACK;
  Creases: TFILTER_ITEM_TRACK;
  BaseColor, AccentColor: TFILTER_ITEM_COLOR;
  PaperPath, ContainerPath, LegacyPaperPath, LegacyContainerPath: TFILTER_ITEM_FILE;
  ContainerPathVisibility, LegacyPaperVisibility, LegacyContainerVisibility: TFILTER_ITEM_HIDE_RULE;
  ApplyButton: TFILTER_ITEM_BUTTON;
  Groups, GroupEnds: array[0..4] of TFILTER_ITEM_GROUP;

function CurrentIndex(Kind: TSelector): Integer;
begin
  Result := EnsureRange(Selectors[Kind].Value, 0, OptionCounts[Kind] - 1);
end;

function RGB(const Color: TFILTER_ITEM_COLOR): Cardinal;
begin
  Result := (Cardinal(Color.R) shl 16) or (Cardinal(Color.G) shl 8) or Color.B;
end;

procedure ApplyPreset(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE;
  Effect, Item: PWideChar); cdecl;
var
  S: TPaperSettings;
  Phase: TPhase;
  Target: string;
  Index: Integer;
  Value: PAnsiChar;

  procedure WriteItem(Name: PWideChar; const Text: UTF8String);
  begin
    if not Edit^.SetObjectItemValue(Obj, PWideChar(Target), Name, PAnsiChar(Text)) then
      OutputDebugString(PWideChar('SYNC_PaperOpen preset: ' + string(Name)));
  end;

  procedure WriteChoice(Kind: TSelector; Choice: Integer);
  begin
    WriteItem(Names[Kind], UTF8String(Options[Kind, Choice].Name));
  end;

begin
  if (Edit = nil) or (Obj = nil) or (Effect = nil) or
    not Assigned(Edit^.SetObjectItemValue) then Exit;
  try
    Target := Effect;
    Index := CurrentIndex(sePreset);
    if Assigned(Edit^.GetObjectItemValue) then
    begin
      Value := Edit^.GetObjectItemValue(Obj, PWideChar(Target), Names[sePreset]);
      if Value <> nil then
        for var I := Low(PresetNames) to High(PresetNames) do
          if UTF8String(PresetNames[I]) = UTF8String(Value) then
          begin
            Index := I;
            Break;
          end;
    end;
    S := PaperPreset(Index);
    WriteChoice(seContainer, Ord(S.Container));
    WriteChoice(seOpening, Ord(S.Opening));
    WriteChoice(seFold, Ord(S.Fold));
    WriteChoice(seEntrance, Ord(S.Entrance));
    WriteChoice(seDirection, Ord(S.Direction));
    WriteChoice(seLeaving, Ord(S.Leaving));
    for Phase := Low(TPhase) to High(TPhase) do
      WriteItem(PhaseNames[Phase], UTF8String(FloatToStr(S.Seconds[Phase], TFormatSettings.Invariant)));
    WriteItem(BaseColor.Name, UTF8String(IntToHex(S.BaseColor, 6)));
    WriteItem(AccentColor.Name, UTF8String(IntToHex(S.AccentColor, 6)));
    WriteItem(Creases.Name, UTF8String(FloatToStr(S.Crease * 100, TFormatSettings.Invariant)));
  except
    on E: Exception do OutputDebugString(PWideChar('SYNC_PaperOpen preset: ' + E.Message));
  end;
end;

procedure RegisterPaperOpenParameters;
var
  S: TPaperSettings;

  procedure AddOptions(Kind: TSelector; Initial: Integer; const Values: array of PWideChar);
  var I: Integer;
  begin
    OptionCounts[Kind] := Length(Values);
    for I := 0 to High(Values) do
    begin
      Options[Kind,I].Name := Values[I];
      Options[Kind,I].Value := I;
    end;
    AddSelect(Selectors[Kind], Names[Kind], Initial, @Options[Kind,0]);
  end;

  procedure Track(Phase: TPhase);
  begin
    AddTrack(Tracks[Phase], PhaseNames[Phase], S.Seconds[Phase], 0, MAX_SECONDS, 0.01);
  end;

  procedure Color(var Item: TFILTER_ITEM_COLOR; Name: PWideChar; RGB: Cardinal);
  begin
    AddColor(Item, Name, Byte(RGB and $FF), Byte((RGB shr 8) and $FF), Byte(RGB shr 16));
  end;

begin
  S := PaperPreset(0);
  AddOptions(sePreset, 0, PresetNames);
  AddButton(ApplyButton, '適用', ApplyPreset);
  AddFile(PaperPath, '紙画像', '', IMAGE_FILTER);

  AddGroup(Groups[0], '入れ物・開封', 1);
  AddOptions(seContainer, Ord(S.Container), ContainerNames);
  AddFile(ContainerPath, '容器画像', '', IMAGE_FILTER);
  AddHideRule(ContainerPathVisibility, ContainerPath.Name, Names[seContainer],
    FILTER_HIDE_NOT_EQUAL, Ord(ckImage));
  AddOptions(seOpening, Ord(S.Opening), OpeningNames);
  Track(phOpening);
  AddGroup(GroupEnds[0], '', 0);

  AddGroup(Groups[1], '登場・取り出し', 1);
  AddOptions(seEntrance, Ord(S.Entrance), EntranceNames);
  Track(phEntrance);
  AddOptions(seDirection, Ord(S.Direction), DirectionNames);
  Track(phPull);
  AddGroup(GroupEnds[1], '', 0);

  AddGroup(Groups[2], '展開', 1);
  AddOptions(seFold, Ord(S.Fold), FoldNames);
  Track(phUnfold);
  AddTrack(Creases, '折り目の残り具合', 0, 0, 100, 0.01);
  AddGroup(GroupEnds[2], '', 0);

  AddGroup(Groups[3], '退場', 0);
  AddOptions(seLeaving, Ord(S.Leaving), ExitNames);
  Track(phExit);
  AddGroup(GroupEnds[3], '', 0);

  AddGroup(Groups[4], '色', 0);
  Color(BaseColor, '基本色', S.BaseColor);
  Color(AccentColor, 'アクセント色', S.AccentColor);
  AddGroup(GroupEnds[4], '', 0);

  // 既存プロジェクトの保存キーを読み込めるよう、旧ファイル項目を非表示で登録する。
  AddFile(LegacyPaperPath, '紙の画像ファイル', '', IMAGE_FILTER);
  AddAlwaysHideRule(LegacyPaperVisibility, LegacyPaperPath.Name);
  AddFile(LegacyContainerPath, '入れ物の画像ファイル', '', IMAGE_FILTER);
  AddAlwaysHideRule(LegacyContainerVisibility, LegacyContainerPath.Name);
end;

procedure ReadPaperOpenParameters(out S: TPaperSettings; out PaperFile, ContainerFile: string);
var
  Phase: TPhase;
begin
  S.Container := TContainerKind(CurrentIndex(seContainer));
  S.Opening := TOpeningKind(CurrentIndex(seOpening));
  S.Fold := TFoldKind(CurrentIndex(seFold));
  S.Entrance := TEntranceKind(CurrentIndex(seEntrance));
  S.Direction := TDirection(CurrentIndex(seDirection));
  S.Leaving := TExitKind(CurrentIndex(seLeaving));
  S.BaseColor := RGB(BaseColor);
  S.AccentColor := RGB(AccentColor);
  S.Crease := Bounded(Creases.Value, 100) / 100;
  for Phase := Low(TPhase) to High(TPhase) do
    S.Seconds[Phase] := Bounded(Tracks[Phase].Value, MAX_SECONDS);
  PaperFile := PaperPath.Value;
  if PaperFile = '' then PaperFile := LegacyPaperPath.Value;

  ContainerFile := '';
  if S.Container = ckImage then
  begin
    ContainerFile := ContainerPath.Value;
    if ContainerFile = '' then ContainerFile := LegacyContainerPath.Value;
  end
  else if PaperFile = '' then
    // 旧版の標準容器で、使われない容器欄だけに選んだ画像を紙として復元する。
    PaperFile := LegacyContainerPath.Value;
end;

end.
