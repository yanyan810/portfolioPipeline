function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments, [string]$LogPath)
    $oldPreference = $ErrorActionPreference
    try {
        # Windows PowerShell otherwise treats native stderr as a terminating error.
        $ErrorActionPreference = 'Continue'
        $lines = @(& $Command @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    $output = ($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($LogPath) { Set-Content -LiteralPath $LogPath -Value $output -Encoding UTF8 }
    if ($code -ne 0) {
        if ($LogPath) { throw "$Command failed (exit $code). See log: $LogPath" }
        throw "$Command failed (exit $code). $output"
    }
    return $output
}

function Find-MSBuildPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $found = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe'
        if (-not $found) { $found = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' }
        if ($LASTEXITCODE -eq 0) {
            foreach ($path in $found) { if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
        }
    }
    $command = Get-Command MSBuild.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        foreach ($year in @('2022', '2019')) {
            foreach ($edition in @('Community', 'Professional', 'Enterprise', 'BuildTools')) {
                $path = Join-Path $base "Microsoft Visual Studio/$year/$edition/MSBuild/Current/Bin/MSBuild.exe"
                if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
            }
        }
    }
    throw 'MSBuild.exe was not found. Install Visual Studio C++ build tools.'
}

function Initialize-PipelineEnvironment {
    param([string]$RootPath, [string]$PythonCommand, [switch]$RequireGit, [switch]$RequirePython)
    if ($RequireGit) { Write-Host (Invoke-NativeCommand 'git' @('--version')) }
    if ($RequirePython) {
        $req = Join-Path $RootPath 'requirements.txt'
        if (-not (Test-Path -LiteralPath $req -PathType Leaf)) { throw 'requirements.txt was not found.' }
        Write-Host (Invoke-NativeCommand $PythonCommand @('--version'))
        try { $null = Invoke-NativeCommand $PythonCommand @('-c', 'import googleapiclient, google_auth_oauthlib, google.auth') }
        catch {
            Write-Host 'Installing Google Drive dependencies...'
            Write-Host (Invoke-NativeCommand $PythonCommand @('-m', 'pip', 'install', '-r', $req, '--no-warn-script-location'))
            $null = Invoke-NativeCommand $PythonCommand @('-c', 'import googleapiclient, google_auth_oauthlib, google.auth')
        }
    }
}

function Invoke-MSBuildAndDeploy {
    param([hashtable]$Work, [string]$SourcePath, [string]$Destination, [string]$LogPath, [string[]]$ExcludePatterns = @())
    $target = Join-Path $SourcePath $Work.project_msbuild_target_path
    Assert-SafeChildPath $target $SourcePath
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Build target not found: $target" }
    $configuration = if ($Work.project_msbuild_configuration) { $Work.project_msbuild_configuration } else { 'Release' }
    $buildArgs = @($target, '/t:Build', "/p:Configuration=$configuration", '/v:minimal', '/nr:false')
    # Override projects that otherwise write outside their source tree.
    $buildRoot = Join-Path $SourcePath '.pipeline_build'
    New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
    $buildArgs += '/p:OutDir=' + (Join-Path $buildRoot 'Output') + '\'
    # Do not pass a literal $(MSBuildProjectName) in a global IntDir property:
    # C++ evaluates it inconsistently between directory creation and compilation.
    # The selected anAlive solution keeps its own per-project objects in
    # the surrounding work_XX/generated directory, still inside Intermediate.
    $buildArgs += @('/m:1', '/p:PreferredToolArchitecture=x64')
    $buildArgs += @('/fl', "/flp:LogFile=$LogPath;Verbosity=normal")
    if ($Work.project_msbuild_platform) { $buildArgs += "/p:Platform=$($Work.project_msbuild_platform)" }
    $msbuild = Find-MSBuildPath
    Write-Host "MSBuild log: $LogPath"
    $consoleLog = Join-Path (Split-Path $LogPath -Parent) 'msbuild-console.log'
    $null = Invoke-NativeCommand $msbuild $buildArgs $consoleLog
    if ($Work.project_build_copy_list -and $Work.project_build_copy_list.Count -gt 0) {
        foreach ($item in $Work.project_build_copy_list) {
            $inputPath = Join-Path $SourcePath $item
            Assert-SafeChildPath $inputPath $SourcePath
            Copy-ItemWithExclude $inputPath (Join-Path $Destination (Split-Path $item -Leaf)) $ExcludePatterns
        }
    } else {
        $inputPath = Join-Path $SourcePath $Work.project_build_output_relative_path
        Assert-SafeChildPath $inputPath $SourcePath
        Copy-ItemWithExclude $inputPath $Destination $ExcludePatterns
    }
}
