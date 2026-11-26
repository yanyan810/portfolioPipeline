# 実装・検証記録

実施日: 2026-11-26（日本時間）

## 資料との対応

| 資料 | 実装した内容 | 検証・設計判断 |
|---|---|---|
| [02](https://docs.google.com/presentation/d/1wM2ax9d3D788_gROktsq0EOOuQAFYgwrKb1dicHJAVk/edit) | Git取得、Intermediate、Generated、ZIP | `--depth 1` で最新ソースだけ取得。収集対象は履歴解析ではないため浅い取得を採用。URL・コミットID・UTC取得日時を別途記録して追跡可能にする。無効な取得元で非0終了、既存成果物保持を確認 |
| [03](https://docs.google.com/presentation/d/1M--BKOnA6MUVMr3nJxhLqmOUTN2zvw9F3zFecoku-XY/edit) | `config.psd1`、`Assert-Config`、`TargetWork` | 空のworksは設定エラー。存在しないTargetWorkは停止。他作品を処理しない。対象限定の更新後は全体ZIPを無効化し、前のZIPを誤って提出しないようにする |
| [04](https://docs.google.com/presentation/d/13hNSNhE4CHPyIsM1y_mvhBasWvHx-ISI9nFLB2grVlA/edit) | Git／ローカルフォルダ切替、安全な置換 | 両方指定・未指定・存在しないローカルパスを開始前に拒否。全作品をステージングし、成功後だけ公開。入れ子のソースと設定ファイルが残ることを確認 |
| [05](https://docs.google.com/presentation/d/11Js50sPvxcJXavavG_sw_bg1rLfLcO3pmNMrOz6MPJw/edit) | FileUtils、除外付きコピー、専用ルートの検証 | `.git`・Thumbs.db・PDB・認証ファイルを除外。`.editorconfig`・LICENSE・入れ子ファイルを保持。追加規則の `*.tmp` に対し `settings.ini` を残す対照例で確認。すべてのドットファイルを除外するサンプルコードは採用しない |
| [06](https://docs.google.com/presentation/d/1-O8d9uAvx2HN_XvBIiJDI9vApI6A6wHY4t5J_WXk7Ds/edit) | Python CLI、Drive取得、スライドPDF変換、OAuth、SkipDownload | 引数はファイルIDと保存先、成功0／失敗非0。部分ファイルは一時名で保存し、成功後に置換。異常終了時も前のファイルを保持。SkipDownloadでPythonを呼ばないことを、存在しないPythonコマンドを渡して確認。認証JSONはGit追跡対象外 |
| [07](https://docs.google.com/presentation/d/1i2SziXNieZ0Bssn-XN_T7ioLK9g-rVDI7zcnG67M-ww/edit) | MSBuild、起動確認、責務分離、診断ログ | 1作品でも失敗すれば全体停止。実際のMSBuild成功／失敗、ログ保持、テストEXEの異常終了検出・後始末を確認。起動時に作られるファイルは破棄用コピーに隔離 |

## 自動テスト

`tests/Run-Tests.ps1` はPowerShell 5.1と7の両方を対象とするテストです。別プロセスでの通常実行、対象限定再実行、失敗時の提出物保持、ローカルGit取得、実際のMSBuild、テスト用EXEの起動を含みます。テストの診断ファイルは `TestResults` に保存します。

最終版の結果: PowerShell 7で23項目、Windows PowerShell 5.1で23項目、Python 3.12で12テストが成功しました。

`tests/test_download_file.py` の12テストは、Google APIの模擬応答で以下を確認します。

- バイナリ取得とGoogleスライドからのPDF変換
- ダウンロード途中の失敗で部分ファイルを除去し、以前の完成ファイルを保持
- ファイル名の無害化、認証・メタデータファイル名への上書き拒否
- ダウンロード権限、未対応のGoogleファイル種別、URLをIDとして渡した場合の拒否
- CLIの非0終了、エラー出力で認証情報を表示しないこと

APIの模擬テストは実際のOAuth認証・ネットワーク通信の成功を保証しません。

## anAliveを使った実行

実行コマンド:

```powershell
.\PortfolioPipeline.ps1 -UseCachedSpecs
```

- 取得元: `https://github.com/yanyan810/anAlive.git`
- 取得コミット: `e82c200c2a84957766c955522707a5084a277ae3`
- ビルド: `CG2_Setup.sln` / Release / x64
- 説明資料: 指定されたGoogleスライドを接続済みGoogle DriveからPDFとして取得。ファイルサイズ1,524,550バイト
- PDFのSHA-256: `5E5F65CACB4E6074E62CD3EB6A4B876764BA14A89E385036ECDE6D602AAA5F86`
- 実行確認: `CG2_Setup.exe` を5秒起動。異常終了がなく、確認後にプロセスを終了
- 配置対象: `CG2_Setup.exe`、`dxcompiler.dll`、`dxil.dll`、`resources`、ビルド前ソース、説明PDF、取得記録

一度目の実作品ビルドでは、パイプライン側で指定したIntDirの変数展開が原因で失敗しました。設定を修正してビルド成功を確認しました。起動確認でゲームのキャッシュが生成されることも分かったため、最終版は実行ファイルの破棄用コピー上で起動します。元の制作フォルダ・元リポジトリのソースは変更していません。

## 残る確認

- 単体PythonプログラムのGoogle OAuth初回認証と実ファイルの取得は未実施です。このPCの接続済みDriveからのPDF取得は成功しましたが、`lib/credentials.json` / `lib/token.json` を使った認証の実証とは別です。
- 起動確認は短時間の異常終了だけを検出します。操作・画面・ゲーム進行・音声・ステージ遷移などは手動の受入確認が必要です。
- 提出フォルダ名は説明資料のクラス・出席番号・氏名から設定しています。提出先が求める日本語表記や命名規則とは、提出前に照合してください。
- `-UseCachedSpecs` はPDFの保存時点の内容を使います。資料を更新した場合はOAuthで取り直すか、PDFキャッシュを更新してください。
