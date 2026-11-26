function Invoke-PipelineTask {
    param([string]$Message, [scriptblock]$Action)
    Write-Host "  -> $Message"
    try { & $Action; Write-Host '     OK' -ForegroundColor Green }
    catch { throw "$Message failed. $($_.Exception.Message)" }
}

function Get-SourceFromGit {
    param([string]$RepoUrl, [string]$CloneDestPath)
    $oldPrompt = $env:GIT_TERMINAL_PROMPT
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $null = Invoke-NativeCommand 'git' @('clone', '--depth', '1', '--', $RepoUrl, $CloneDestPath)
        $commit = Invoke-NativeCommand 'git' @('-C', $CloneDestPath, 'rev-parse', 'HEAD')
    } finally { $env:GIT_TERMINAL_PROMPT = $oldPrompt }
    # Keep provenance outside .git before excluding the management directory.
    return @{ type = 'git'; repository = $RepoUrl; commit = $commit.Trim(); shallow_depth = 1 }
}

function Download-ProgramSpec {
    param([string]$SpecId, [string]$WorkPath, [string]$PythonCommand, [string]$PyScriptPath)
    Write-Host (Invoke-NativeCommand $PythonCommand @($PyScriptPath, $SpecId, $WorkPath, '--no-browser'))
}

function Deploy-ExecutableFromZip {
    param([string]$ZipId, [string]$Destination, [string]$TempPath, [string]$PythonCommand, [string]$PyScriptPath, [string[]]$ExcludePatterns = @())
    New-Item -ItemType Directory -Path $TempPath -Force | Out-Null
    Download-ProgramSpec $ZipId $TempPath $PythonCommand $PyScriptPath
    $zips = @(Get-ChildItem -LiteralPath $TempPath -File -Filter '*.zip')
    if ($zips.Count -ne 1) { throw "Exactly one ZIP is required; found $($zips.Count)." }
    Expand-AndFlattenArchive $zips[0].FullName (Join-Path $TempPath 'Extracted') $Destination $ExcludePatterns
}

function Deploy-ExecutableFromLocal {
    param([string]$LocalPath, [string]$Destination, [string]$TempPath, [string[]]$ExcludePatterns = @())
    if (Test-Path -LiteralPath $LocalPath -PathType Container) {
        Copy-ItemWithExclude $LocalPath $Destination $ExcludePatterns
    } elseif ([IO.Path]::GetExtension($LocalPath) -eq '.zip') {
        Expand-AndFlattenArchive $LocalPath $TempPath $Destination $ExcludePatterns
    } else { throw 'Local executable input must be a folder or ZIP.' }
}

function Test-ExecutableSmoke {
    param([string]$ExecDir, [string]$TestExecutableName, [switch]$Required, [int]$WaitSeconds = 3)
    if ($TestExecutableName) {
        $exe = Join-Path $ExecDir $TestExecutableName
        Assert-SafeChildPath $exe $ExecDir
        # Explicit names are a contract, even when automatic detection is optional.
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Configured executable not found: $exe" }
    } else {
        $files = @()
        if (Test-Path -LiteralPath $ExecDir) { $files = @(Get-ChildItem -LiteralPath $ExecDir -File -Filter '*.exe') }
        if ($files.Count -eq 0) {
            if ($Required) { throw 'Smoke test is required, but no EXE was found.' }
            Write-Host 'Smoke test: not applicable (no EXE).'
            return 'not_applicable'
        }
        if ($files.Count -gt 1) { throw 'Multiple EXEs found; set test_executable_name.' }
        $exe = $files[0].FullName
    }
    $process = $null
    try {
        $process = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($WaitSeconds -gt 0) { Start-Sleep -Seconds $WaitSeconds }
        $process.Refresh()
        if ($process.HasExited -and $process.ExitCode -ne 0) { throw "Executable crashed (exit $($process.ExitCode))." }
        Write-Host 'Smoke test: passed (startup only).'
        return 'passed'
    } finally {
        if ($process) {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
        }
    }
}

function Invoke-CollectWork {
    param([hashtable]$Work, [hashtable]$Output, [string]$RootPath, [string]$WorkTemp, [string]$WorkStage, [string]$PythonCommand, [switch]$SkipDownload, [switch]$SkipBuild, [switch]$SkipSmokeTest, [switch]$UseCachedSpecs)
    New-Item -ItemType Directory -Path $WorkTemp, $WorkStage | Out-Null
    $source = Join-Path $WorkTemp 'Source'
    $projFolder = if ($Output.project_folder_name) { $Output.project_folder_name } else { 'SourceCode' }
    $execFolder = if ($Output.executable_folder_name) { $Output.executable_folder_name } else { 'Executable' }
    $execDest = Join-Path $WorkStage $execFolder
    $record = [ordered]@{ work = $Work.work_folder_name; collected_at = [DateTime]::UtcNow.ToString('o') }
    $excludes = @($Work.exclude_patterns | Where-Object { $_ })
    Invoke-PipelineTask 'Collect source' {
        if ($Work.git_repository_url) {
            $record.source = Get-SourceFromGit $Work.git_repository_url $source
        } else {
            $local = Resolve-ProjectPath $Work.local_source_path $RootPath
            $record.source = @{ type = 'local'; path = $Work.local_source_path }
            if (Test-Path -LiteralPath $local -PathType Container) { Copy-ItemWithExclude $local $source $excludes }
            else { Deploy-ExecutableFromLocal $local $execDest (Join-Path $WorkTemp 'LocalZip') $excludes }
        }
        if (Test-Path -LiteralPath $source) { Copy-ItemWithExclude $source (Join-Path $WorkStage $projFolder) $excludes }
    }
    $pythonScript = Join-Path $RootPath 'lib/download_file.py'
    if ($Work.google_drive_file_id -and -not $SkipDownload) {
        if ($UseCachedSpecs) {
            $cached = Join-Path $RootPath ('inputs/specs/' + $Work.google_drive_file_id + '.pdf')
            if (-not (Test-Path -LiteralPath $cached -PathType Leaf)) { throw "Cached description not found: $cached" }
            Assert-NoReparsePoint $cached
            Copy-Item -LiteralPath $cached -Destination (Join-Path $WorkStage 'Description.pdf')
            $record.description = @{ type = 'cached_pdf'; file_id = $Work.google_drive_file_id; sha256 = (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash }
            Write-Host 'Description: using explicitly selected cached PDF.'
        } else {
            Invoke-PipelineTask 'Download description' { Download-ProgramSpec $Work.google_drive_file_id $WorkStage $PythonCommand $pythonScript }
            $record.description = @{ type = 'google_drive'; file_id = $Work.google_drive_file_id }
        }
    }
    if ($Work.google_drive_zip_id -and -not $SkipDownload) {
        Invoke-PipelineTask 'Download executable ZIP' { Deploy-ExecutableFromZip $Work.google_drive_zip_id $execDest (Join-Path $WorkTemp 'DriveZip') $PythonCommand $pythonScript $excludes }
    }
    if ($Work.local_executable_path) {
        Invoke-PipelineTask 'Collect local executable' { Deploy-ExecutableFromLocal (Resolve-ProjectPath $Work.local_executable_path $RootPath) $execDest (Join-Path $WorkTemp 'ExecutableZip') $excludes }
    }
    if ($Work.project_msbuild_target_path -and -not $SkipBuild) {
        Invoke-PipelineTask 'Build and deploy' { Invoke-MSBuildAndDeploy $Work $source $execDest (Join-Path $WorkTemp 'msbuild.log') $excludes }
    }
    $record.smoke_test = 'skipped'
    if (-not $SkipSmokeTest) {
        $wait = if ($null -ne $Work.smoke_test_wait_seconds) { $Work.smoke_test_wait_seconds } else { 3 }
        # Games may create logs, saves or settings on startup. Run a disposable
        # copy so these side effects cannot enter the submitted executable tree.
        $smokeDir = Join-Path $WorkTemp 'Smoke'
        if (Test-Path -LiteralPath $execDest -PathType Container) { Copy-ItemWithExclude $execDest $smokeDir $excludes }
        $record.smoke_test = Test-ExecutableSmoke $smokeDir $Work.test_executable_name -Required:([bool]$Work.smoke_test_required) -WaitSeconds $wait
    }
    $record.skipped = @{ download = [bool]$SkipDownload; build = [bool]$SkipBuild; smoke_test = [bool]$SkipSmokeTest }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $WorkStage 'collection.json') -Encoding UTF8
    return $record
}
