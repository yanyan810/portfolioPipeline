$ErrorActionPreference = 'Stop'
$requirementsFileName = 'requirements.txt'

Write-Host '--- 環境確認を開始します ---'

# Step 1. Python の確認
Write-Host 'Step 1: Python の確認中...'
try {
    $pythonVersion = python --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Python の実行に失敗しました (終了コード: $LASTEXITCODE)"
    }
    Write-Host "OK: $pythonVersion"
}
catch {
    Write-Host "失敗: Python を確認できませんでした。 $($_.Exception.Message)" -ForegroundColor Red
    Read-Host '終了するには Enter キーを押してください...'
    exit 1
}

# Step 2. Git の確認
Write-Host 'Step 2: Git の確認中...'
try {
    $gitVersion = git --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Git の実行に失敗しました (終了コード: $LASTEXITCODE)"
    }
    Write-Host "OK: $gitVersion"
}
catch {
    Write-Host "失敗: Git を確認できませんでした。 $($_.Exception.Message)" -ForegroundColor Red
    Read-Host '終了するには Enter キーを押してください...'
    exit 1
}

# Step 3. 依存ライブラリの準備
Write-Host 'Step 3: 依存ライブラリの確認中...'
try {
    $reqFile = Join-Path $PSScriptRoot $requirementsFileName
    if (-not (Test-Path -LiteralPath $reqFile -PathType Leaf)) {
        throw "$requirementsFileName が見つかりません。"
    }

    # import の成否を終了コードで判定する
    $oldEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        python -c 'import googleapiclient, google_auth_oauthlib' 2>$null
        $installed = ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $oldEAP
    }

    if (-not $installed) {
        Write-Host '未導入: インストールを開始します'
        python -m pip install -r $reqFile --upgrade --no-warn-script-location
        if ($LASTEXITCODE -ne 0) {
            throw "pip install が失敗しました (終了コード: $LASTEXITCODE)"
        }

        # インストール後も実際に読み込めることを確認する
        $oldEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            python -c 'import googleapiclient, google_auth_oauthlib' 2>$null
            $importExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldEAP
        }
        if ($importExitCode -ne 0) {
            throw 'インストール後の import 確認に失敗しました。'
        }
        Write-Host 'インストール完了・読み込み成功'
    }
    else {
        Write-Host '導入済み: 読み込み成功'
    }
}
catch {
    Write-Host "失敗: 依存ライブラリを準備できませんでした。 $($_.Exception.Message)" -ForegroundColor Red
    Read-Host '終了するには Enter キーを押してください...'
    exit 1
}

Write-Host '--- 環境確認と準備が完了しました ---' -ForegroundColor Green
Read-Host '終了するには Enter キーを押してください...'
