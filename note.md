# SYNC_PaperOpen 作業ノート

## プロジェクト

- Delphi プロジェクトは `SYNC_PaperOpen.dproj`。AviUtl2 のメディアオブジェクト「開封演出」、グループ「SYNC」として登録する。
- WeatherFX からプロジェクト構成、SDK 型、登録処理、リソースとライセンスを引き継いだ。PianoRoll の単体入力と初期画像確保、3D 深度の調査を参照した。
- `Setup` は WeatherFX のフォルダー全体をコピーした。スクリプト、カタログ、ZIP はコピー元の製品向けの内容。開封演出向けの配布作業は別途行う。

## ビルド

Delphi 37.0 の環境を読み込み、プロジェクトルートで Win64 Debug と Release をビルドする。両構成は同じ場所に出力するため、最終配置には Release を使う。

```powershell
cmd /c 'call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild SYNC_PaperOpen.dproj /t:Rebuild /p:Config=Debug /p:Platform=Win64'
cmd /c 'call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild SYNC_PaperOpen.dproj /t:Rebuild /p:Config=Release /p:Platform=Win64'
```

- AUF2 は `C:\ProgramData\aviutl2\Plugin\SYNC_PaperOpen\SYNC_PaperOpen.auf2`。WeatherFX のビルド後イベントは DLL を AUF2 名でコピーし、元の DLL と Release の RSM を削除する。
- DCU は `Win64\Debug\DCU` と `Win64\Release\DCU`。デバッガーホストは両構成ともコピー元の `D:\aviutl2_v2.1.16\aviutl2.exe`。通常のビルドと検査はコマンドラインで行う。
- ユニット追加時は DPR の `in` と DPROJ の `DCCReference` の両方へ登録する。IDE で開いているプロジェクトファイルを外部で変更した場合は、IDE で開き直す。

## 実装

| ファイル | 責務 |
| --- | --- |
| `SYNC_PaperOpen.dpr` | DLL のエクスポートと最低対応バージョン |
| `Source/Plugin/Filter/` | SDK 登録、プリセット反映、インスタンスの所有 |
| `PaperOpen_State.pas` | プリセットと経過秒数による各工程の評価 |
| `PaperOpen_Image.pas` | WIC デコードとファイル更新の検出 |
| `PaperOpen_Geometry.pas` | 投影、頂点バッファ、画像中心とキャンバス寸法 |
| `PaperOpen_Paper.pas` | 折り、巻き、しわ、紙飛行機、裏返しのメッシュ |
| `PaperOpen_Container.pas` | 入れ物の寸法・開封・前後面・取り出し・退場 |
| `PaperOpen_D3D.pas` と `PaperOpen_Shader.inc` | 深度、表裏、折り目の陰影、透過合成と標準画像への出力 |

- カメラ制御は不要。固定投影と専用深度バッファで紙を描き、取り出し中は入れ物の前面で遮蔽する。合成結果は元画像と同じ中心を基準に AviUtl2 の標準描画へ渡す。
- ホストの画像テクスチャには乗算済みアルファで出力する。独立デバイスから `SetImageData` へ渡す経路ではストレート RGBA へ変換する。折り目と入れ物が消えた完成画像は、読み込んだ RGBA を元寸法のまま渡す。
- パラメータを評価時点でコピーする。デコード済み画像、テクスチャ、頂点領域と描画先はエフェクトごとに再利用する。ホスト所有ポインターはコールバック中に借用し、Delphi 例外は DLL 境界内で処理する。
- 時間は0～60秒。画像と描画キャンバスには一辺16,384画素・総画素数33,554,432の上限を設けた。広い移動範囲や極端な縦横比の素材では、変形中の周辺が上限で切れる場合がある。
- 日本語を含む Delphi／PowerShell ソースは UTF-8 BOM と CRLF。ユニットの先頭に責務を書き、公開処理では入力・出力・副作用と資源の所有を記載する。SDK 型の変更時は公式ヘッダーと照合する。

## 2026-11-25 の検査

- Win64 Debug と Release を MSBuild で Rebuild し、両方とも警告0・エラー0。配置先には Release の AUF2 がある。
- 検査用 EXE で本番 AUF2 をロードした。プリセット13種、展開13種、入れ物と開封方法の組み合わせ56通り、退場8種、元画像の寸法と透過、逆方向のシーク、0秒設定、複数インスタンスを確認した。
- 乗算済み RGBA16F のモックホストで描画した109枚のフレームが Debug と Release で一致した。ビルドログは `Win64/BuildLogs`、検査ログと描画一覧は `Win64/Verification`。
- AviUtl2 と Delphi IDE は起動していない。AviUtl2 上の設定画面・操作と実機の再生性能は未確認。
