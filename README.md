# tamatama-extractor

SHIGEZONE「タマタマ ビデオプレーヤー701」（Crystal701 / Actions V100）用のNAND読み出しツール。純正ブートブロック3の書き戻しも実験機能として扱う。

| 機能 | 検証の範囲 |
| --- | --- |
| 起動領域0〜3とLFIの読み出し | 既存のRAMローダーで実機確認済み。本CLIで生成した両ローダーは、そのときのバイナリに一致する。 |
| 起動領域0〜3の生データとOOB | 実機で使った読み出しループを再利用し、終了位置を1024ページに変更。変更版はオフラインでビルド済み。 |
| 純正ブートブロック3の書き戻し | 旧ツールで書き戻しと独立した読み戻しに成功した構成に限定。このCLIの実機書き込みは未検証。 |
| LFIの解析 | 保存済みの取得データを使い、22 MiBの論理イメージと145ファイルのチェックサムを照合済み。 |

このCLIは、調査した個体の64バイトADFU構成と固定LFIマップを使う。別の個体でLFIの物理ブロックの割り当てが異なる場合は、マップの調査が必要になる。MSCのFAT32領域、空き物理ブロック、LFI全体の書き換え、壊れたファームウェアからの復旧は対象外。

## 準備

Python 3.10以上と `mipsel-linux-gnu` のGNU binutilsを使う。WindowsではUbuntuのWSLにbinutilsを入れ、ツール自体はWindowsのPythonで実行する。使用するWSLディストリビューション名は `TAMATAMA_WSL_DISTRO` で指定できる。既定値は `Ubuntu`。

```bash
sudo apt install binutils-mipsel-linux-gnu
```

以下は `tamatama_extractor.py` があるディレクトリから実行する。アップロードには、固定したactions-adfu-toolのソースを別途取得する。

```powershell
git clone https://github.com/BlackLikeaCat/actions-adfu-tool.git ../adfu-bootstrap
git -C ../adfu-bootstrap checkout --detach 91c8f4709c5d36f916baa2109900df6b95dc396f
python -m pip install pyusb==1.3.1 libusb-package==1.0.30.1
python tamatama_extractor.py build --adfu-checkout ../adfu-bootstrap --output build-nand
```

`build` はUSBを使わない。既知のハッシュに一致するエンコード済みイメージだけを実機コマンドが受け付ける。Linuxで実行する場合はlibusbを導入し、環境に合わせてUSBアクセス権を設定する。

## 読み出し

各コマンドの前に本体を完全に電源オフし、ボタンを押しながらUSBを接続してADFUに入り直す。USBの抜き差しだけでは、前回のRAMローダーが動作したままの場合がある。接続するADFU機器は1台にする。

```powershell
python tamatama_extractor.py read-boot --adfu-checkout ../adfu-bootstrap --loaders build-nand --output boot
python tamatama_extractor.py read-boot-raw --adfu-checkout ../adfu-bootstrap --loaders build-nand --output raw-boot
python tamatama_extractor.py read-lfi --adfu-checkout ../adfu-bootstrap --loaders build-nand --output lfi
```

各出力先には `receipt.json` と `capture.bin` ができる。`read-boot` はECCで訂正した4 MiBと `ecc-counts.bin`、`read-boot-raw` は各ページに224バイトのOOBを付けた生データを保存する。`read-lfi` はECC処理済みの22物理ブロックのほか、ページを組ごとに並べ直した `lfi.bin` と `lfi-files.json` を保存する。通信やECC検査を通過できなかった読み出しは `capture.partial.bin` として残る。

保存済みのLFIの表を調べたり、変更候補のファイルサイズを比較したりする場合は次を使う。

```powershell
python tamatama_extractor.py inspect-lfi lfi/lfi.bin
python tamatama_extractor.py inspect-lfi lfi/lfi.bin --file FWINFO.BIN candidate.bin
```

比較結果の `fits_current_file_span` は、チェックサム検証に使った元のファイルサイズとの比較。`bytes_to_next_file` は次の開始位置までの距離で、割り当て可能な容量を表すものではない。ファイル表のもう一つのサイズ欄は `size_field_2` として表示する。

## 実験機能としての純正復元

`prepare-restore` は、同じ個体・ポートで取得した4ブロックの生データと訂正済みデータを使う。既知の純正ハッシュと一致するデータだけから、ブロック3用の復元計画を作る。USBポートの記録は、接続先を照合するもので個体固有IDではない。取得から照合まで、同じ本体を同じポートにつなぐ。

```powershell
python tamatama_extractor.py prepare-restore --boot boot --raw raw-boot --output restore-plan
python tamatama_extractor.py dry-run --adfu-checkout ../adfu-bootstrap --loaders build-nand --plan restore-plan --output dry-check
```

`dry-run` ではデータをRAMへ送り、転送のチェックサムを確認する。純正の復元を行うには、新たにADFUで接続し、`restore-stock-block3` に `--write` を指定する。照合を再度実施し、その後に限ってブロック3を消去し、先頭128ページにプログラムする。ブロック0〜2はこのローダーの対象外。書き込み中に電源やUSBが切れた場合の復旧は未検証。

```powershell
python tamatama_extractor.py restore-stock-block3 --write --adfu-checkout ../adfu-bootstrap --loaders build-nand --plan restore-plan --output restore-result
```

復元結果が `programmed: true` になったら、完全に電源を切り、同じポートでADFUに入り直す。次のコマンドで、256ページ分の訂正済みデータと各セクターのOOBユーザーバイトを照合する。

```powershell
python tamatama_extractor.py verify-stock-block3 --adfu-checkout ../adfu-bootstrap --loaders build-nand --plan restore-plan --write-receipt restore-result/receipt.json --output readback
```

## 先行調査とソース

- タマタマ701のハードウェア、USB、ADFU調査はGOROmanさんの記録が出発点。[Crystal701調査記録](https://gist.github.com/GOROman/934e9c522632b303065777bb154a4ef6)
- ADFUの識別、転送、実行、エンコードにはBlackLikeaCatの実装を使用。ホスト側はPythonモジュールとして読み込み、64バイトのUSB読み出し処理は本ツール側で扱う。[actions-adfu-tool](https://github.com/BlackLikeaCat/actions-adfu-tool/tree/91c8f4709c5d36f916baa2109900df6b95dc396f)
- `raw_fast.S`、`ecc_firmware.S`、`verify_stock_block.S` などのNAND制御は、Actions系のレジスタと読み出し手順を参照した経緯をソースに記載している。ビルドするのはこのツールのアセンブリで、`common/nand.c` は同梱・リンクしていない。[actions-hacking `common/nand.c`](https://github.com/SiarheiVolkau/actions-hacking/blob/7299651793c2021c3f3c101940b7f778f5d46ee7/common/nand.c)

本ツールのコードはGPL-2.0-or-later。取得したデータの利用条件は、このツールのライセンスとは別。テストは `python -m unittest test_tamatama_extractor` で実行できる。
