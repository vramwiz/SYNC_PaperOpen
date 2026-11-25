# 開封演出の配布 ZIP

`make_release_zip.bat` は既存の `SYNC_PaperOpen.auf2` を `SYNC_PaperOpen.zip` にまとめ、同梱した本体の XXH3-128 を `SYNC_PaperOpen.catalog.json` に反映します。

1. 配布する AUF2 を `C:\ProgramData\aviutl2\Plugin\SYNC_PaperOpen` に用意します。別フォルダーの本体を使う場合は `-ReleaseDirectory` で指定します。
2. [xxHash 公式配布の xxhsum.exe](https://github.com/Cyan4973/xxHash/releases/tag/v0.8.4) を `Win64\Dependencies\xxHash-0.8.4` または PATH の通った場所へ置きます。個別パスは `-XxhsumPath` で指定できます。
3. JSON のバージョンと公開日を確認し、`make_release_zip.bat` を実行します。初回のタグとカタログは `v1.0.0` です。

ZIP には本体、README、ライセンス、ライセンス表記、SDK のライセンスを同梱します。GitHub リリースに ZIP とカタログ JSON を添付します。
