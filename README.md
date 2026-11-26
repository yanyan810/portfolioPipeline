# portfolioPipeline

授業資料02〜07に沿って、作品のソース、説明資料、実行ファイルを収集し、提出用フォルダとZIPを作るPowerShellパイプラインです。

## 今回の作品設定

`config.psd1` に次を設定しています。

- ソース: https://github.com/yanyan810/anAlive.git の既定ブランチ
- 説明資料: https://docs.google.com/presentation/d/19dp1DcmRzcpZ2S7Nnt5uo6nKK_sSvMdAv3TW24JNSdo/edit
- ビルド: `CG2_Setup.sln`、Release、x64
- 実行ファイル: `CG2_Setup.exe`、`dxcompiler.dll`、`dxil.dll` と `resources`
- 提出名: `LE3B_24_MIYAZAWA_HARUHI_WORK`（説明資料の表題に合わせた仮設定。授業指定の表記に変更してください）

指定された `C:\Users\yanya\Desktop\個人製作` は確認だけ行いました。通常実行ではGitHubのソースを取得し、この制作フォルダは変更しません。ローカルソースを使う場合は、`git_repository_url` を削除し、`local_source_path = 'C:\Users\yanya\Desktop\個人製作\個人製作'` に切り替えます。親フォルダ全体には検証用コピーや過去の出力もあるため、作品のある内側のフォルダを指定します。

## 実行

PowerShell 5.1 または PowerShell 7で、このフォルダを開きます。スクリプト実行が制限されている場合だけ、次のように現在のプロセス内で許可します。

```powershell
Set-ExecutionPolicy -Scope Process Bypass

# 外部接続もビルドも必要ないサンプル
.\PortfolioPipeline.ps1 -ConfigPath .\config.sample.psd1

# 今回、接続済みGoogle Driveから取得した説明PDFを使ってanAliveを収集・ビルド
.\PortfolioPipeline.ps1 -UseCachedSpecs

# 後述のOAuth設定後に、説明資料も毎回Driveから取得する通常実行
.\PortfolioPipeline.ps1
```

キャッシュPDFは `inputs/specs/19dp1DcmRzcpZ2S7Nnt5uo6nKK_sSvMdAv3TW24JNSdo.pdf` にあります。`inputs` はGit管理対象外なので、このPCでのみ利用できます。新たにクローンしたPCではOAuthを設定して通常実行するか、PDFをエクスポートして同じ場所へ保存してください。`-UseCachedSpecs` は明示的に保存済みのPDFを使うオプションで、スライドの更新は自動反映しません。キャッシュの使用とSHA-256は `collection.json` に記録します。

通常の全作品実行が成功すると、次が作成されます。

```text
Generated/
  LE3B_24_MIYAZAWA_HARUHI_WORK/
    01_anAlive/
      SourceCode/       # ビルド前のソース
      Executable/       # EXE、DLL、resources
      Description.pdf   # キャッシュ利用時。Drive取得時は元の資料名.pdf
      collection.json   # コミットID、取得日時、スキップ条件、起動確認結果
    pipeline-result.json
  LE3B_24_MIYAZAWA_HARUHI_WORK.zip
```

## 機能とオプション

```powershell
.\PortfolioPipeline.ps1 -TargetWork 01_anAlive -UseCachedSpecs
.\PortfolioPipeline.ps1 -SkipDownload -SkipBuild -SkipSmokeTest
.\PortfolioPipeline.ps1 -KeepIntermediate -UseCachedSpecs
.\PortfolioPipeline.ps1 -CheckEnvironmentOnly
.\PortfolioPipeline.ps1 -PythonCommand 'C:\path\to\python.exe'
```

| オプション | 動作 |
|---|---|
| `-ConfigPath` | 別の `.psd1` 設定を読む。相対パスはスクリプトの場所から解決 |
| `-TargetWork` | 指定作品だけを更新。他の作品は維持し、古い全体ZIPを無効化。全作品を実行してZIPを作り直す |
| `-SkipDownload` | 説明資料とDrive ZIPの両方を省略。Pythonも呼ばない |
| `-SkipBuild` | MSBuildを省略。EXEを用意しない場合は起動確認も省略する |
| `-SkipSmokeTest` | 短時間の起動確認を省略 |
| `-UseCachedSpecs` | Drive説明資料の代わりに、IDを名前にしたローカルPDFを使う。Drive ZIPには適用しない |
| `-KeepIntermediate` | 成功時にもソース、ビルドログ、一時ファイルを残す |
| `-CheckEnvironmentOnly` | 01相当のPython・Git・依存ライブラリ確認だけを行う |
| `-PythonCommand` | 使用するPython実行ファイル。既定値は `python` |

スキップは開発用です。提出前は省略なしで実行し、`collection.json` の `skipped` を確認します。`-UseCachedSpecs` を使う場合はPDFが最新版か確認します。スモークテストは起動直後の異常終了だけを確認します。画面、操作、データ読込など作品の機能は手動で確認してください。

Python・GoogleライブラリはDrive取得が必要なときだけ確認・不足分をインストールします。ローカルサンプルにPythonは不要です。Git取得にはGit、今回のC++ビルドにはVisual Studioのv143 C++ツールセットとWindows SDKが必要です。

## Google Driveの初期認証

1. 自分のGoogle CloudプロジェクトでDrive APIを有効にし、デスクトップアプリのOAuthクライアントを作成します。
2. ダウンロードしたJSONを `lib/credentials.json` に保存します。
3. 以下を実行し、ブラウザーで自分のアカウントを認証します。

```powershell
python -m pip install -r requirements.txt
python .\lib\download_file.py --auth-only
```

`lib/token.json` が作られます。通常実行はブラウザーを自動で開かず、有効なトークンの利用・更新だけを行います。初回や再認証が必要な場合は上記の認証用コマンドで対応します。読み取り専用の `drive.readonly` を使用し、`credentials.json` と `token.json` はコミット・提出しません。非対話環境では事前認証したトークンを安全に配置し、期限切れや失効時は担当者が再認証します。

既存の接続済みGoogle Driveと、この単体PythonプログラムのOAuth設定は別です。今回のキャッシュPDFは接続済みDriveから取得したもので、単体プログラムの認証が済んだことを意味しません。

公式手順: [Python quickstart](https://developers.google.com/workspace/drive/api/quickstart/python)、[ファイルの取得・エクスポート](https://developers.google.com/workspace/drive/api/guides/manage-downloads)。GoogleスライドはPDFに変換し、ZIPなどは元の形式で取得します。Google標準のエクスポートAPIの10MB制限も適用されます。

## 設定を追加する

`works` に作品のハッシュテーブルを追加します。`work_folder_name` は重複できません。ソースには `git_repository_url` と `local_source_path` の片方だけを指定します。

```powershell
@{
    work_folder_name = '02_LocalWork'
    local_source_path = '.\MyLocalWork'
    local_executable_path = '.\MyGame.zip' # フォルダも可。省略可
    google_drive_file_id = '説明資料のファイルID' # URLではなくID
    test_executable_name = 'MyGame.exe'
    smoke_test_required = $true
    exclude_patterns = @('*.tmp')
}
```

実行ファイルの取得方法は、ビルド・`google_drive_zip_id`・`local_executable_path` のいずれかを選びます。`local_source_path` がZIPの場合は実行ファイルZIPとして展開します。ZIPが単一の親フォルダを持つ場合は、その1階層を取り除きます。

ビルドの配置対象は `project_build_copy_list` にソースからの相対パスで列挙します。未指定なら `project_build_output_relative_path` の内容を配置します。MSBuildの出力先は `.pipeline_build/Output` に上書きします。配布用ソースはビルド前に複製するため、中間生成物を含みません。

## 失敗時と除外規則

提出物の一式が欠けた状態を成功にしないため、1作品でも失敗すれば全体を停止し、終了コード1を返します。取得、コピー、Drive取得、ビルド、起動確認がすべて成功するまで `Generated` の既存提出物を変更しません。配置中のエラーでは、バックアップから前のフォルダ・ZIPを戻します（プロセス強制終了や電源断まで含むトランザクションではありません）。

一時ファイルは実行ごとに `Intermediate/日時_ID` へ分けます。失敗時には `pipeline.log` と `work_XX/msbuild.log` を残し、次の実行でも消しません。成功した実行の一時フォルダだけを削除します。

`.git`、`.vs`、`.vscode`、`Thumbs.db`、`desktop.ini`、`__MACOSX`、`__pycache__`、`*.pdb`、`*.pyc`、`.env`、認証JSONを除外します。追加規則は `exclude_patterns` で設定できます。必要な `.editorconfig` などのドットファイルやLICENSEは残します。資料05のコード例のようにすべてのドットファイルを捨てる方式にはしていません。

出力先には、このプロジェクト直下の専用フォルダだけを指定できます。既存の非空フォルダには管理マーカーが必要で、`lib` や `.git` は指定できません。入力と出力の重複、ジャンクションやシンボリックリンク、不正なZIP内パスも拒否します。

## 検証

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Shell powershell
python -m unittest discover -s tests -p 'test_*.py' -v
```

Pesterや追加テストライブラリは不要です。PowerShellテストはローカル収集・設定エラー・除外・ZIP・ロールバック・対象選択・外部コマンド失敗を検証します。PythonテストはGoogle APIを模した応答で、PDF変換・部分ダウンロードの削除・既存ファイル保持・終了コードを確認します。実際のOAuth通信は別途、上記の認証設定後に実ファイルで確認する必要があります。

授業の検証項目との対応、実行結果と未確認事項は [docs/verification.md](docs/verification.md) を参照してください。
