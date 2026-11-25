# SYNC_PaperOpen 作業ノート

## プロジェクト

- Delphi プロジェクトは `SYNC_PaperOpen.dproj`。AviUtl2 のメディアオブジェクト「開封演出」、グループ「SYNC」として登録する。
- WeatherFX からプロジェクト構成、SDK 型、登録処理、リソースとライセンスを引き継いだ。PianoRoll の単体入力と初期画像確保、3D 深度の調査を参照した。
- `Setup` の配布バッチとカタログは PaperOpen 用。公開版では ZIP とカタログを GitHub リリースに添付する。

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
| `PaperOpen_Paper.pas` | 折り、巻き、しわ、裏返しのメッシュ |
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

## 2026-11-25 画像指定欄の修正

- 保存済みの `Aup2/sample.aup2` では旧「紙の画像ファイル」が空欄で、PNG が旧「入れ物の画像ファイル」へ指定されていた。「横長封筒」では容器画像を使わないため、旧版では全フレームが無描画になった。
- 「紙画像」「容器画像」「適用」に短縮した。「容器画像」は「ユーザー指定画像」でだけ表示する。旧ファイル項目は保存互換用に非表示で受け取り、標準の入れ物で紙が空欄なら、旧容器欄の画像も用紙として復元する。
- 新規配置時の登場方法は「最初から表示」にした。既存オブジェクトに保存されている「フェードイン」はその設定で動作する。
- v1.0.1 の本番 AUF2 を検査用 EXE に読み込み、先頭フレームの描画、元のサンプルからの画像復元、新旧項目の優先順、容器画像の表示条件を確認した。

## 2026-11-25 折りたたみ面と紙飛行機の修正

- 折りたたんだ状態では元画像の印刷と透過を隠し、展開中に表側の内容と透明部分を出す。取り出し中も紙の地色で描画する。
- 紙飛行機は機首、中央の折り筋、後退翼を持つメッシュへ変更した。飛行中は機首を経路に沿わせ、展開時には翼を起こして元の紙へ戻す。
- v1.0.2 の Win64 Debug と Release はともに警告0・エラー0。設定を変えずに作業用の出力先を MSBuild の引数で指定し、検査済みの Release を配置した。
- 色と透過が異なる画像を使って全12変形の閉じた状態、展開直後、展開途中を比較した。閉じた状態と封筒からの取り出し中に元画像の内容が映らないことを確認した。両構成の116フレームは一致した。

## 2026-11-25 正式版 v1.0.0

- 紙飛行機をプリセットと展開方法から外した。プリセット12種と展開方法12種を残した。
- Win64 Debug と Release の警告・エラーは0。両構成の101フレームは一致し、残る演出の描画は v1.0.2 の検査記録とも一致した。
- README は使い方と演出の説明をまとめた。配布バッチは正式版 AUF2 を ZIP にまとめ、`SYNC_PaperOpen.catalog.json` の v1.0.0 に実ファイルの XXH3-128 を反映する。
