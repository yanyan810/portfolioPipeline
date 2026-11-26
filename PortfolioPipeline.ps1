#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [string]$TargetWork,
    [switch]$SkipDownload,
    [switch]$SkipBuild,
    [switch]$SkipSmokeTest,
    [switch]$KeepIntermediate,
    [switch]$UseCachedSpecs,
    [switch]$CheckEnvironmentOnly,
    [string]$PythonCommand = 'python'
)
$ErrorActionPreference = 'Stop'
foreach ($library in @('FileUtils', 'ConfigAssert', 'BuildUtils', 'PipelineTasks')) {
    . (Join-Path $PSScriptRoot "lib/$library.ps1")
}
$runDir = $null
$succeeded = $false
$transcribing = $false
try {
    if ($CheckEnvironmentOnly) {
        Initialize-PipelineEnvironment $PSScriptRoot $PythonCommand -RequireGit -RequirePython
        Write-Host 'Environment check completed.' -ForegroundColor Green
        exit 0
    }
    $configFullPath = Resolve-ProjectPath $ConfigPath $PSScriptRoot
    if (-not (Test-Path -LiteralPath $configFullPath -PathType Leaf)) { throw "Configuration not found: $configFullPath" }
    $config = Import-PowerShellDataFile -LiteralPath $configFullPath
    Assert-Config -Config $config -RootPath $PSScriptRoot
    $selected = @($config.works | Where-Object { -not $TargetWork -or $_.work_folder_name -eq $TargetWork })
    if ($selected.Count -eq 0) { throw "No matching work: '$TargetWork'. works must not be empty." }
    $generatedDir = Resolve-ProjectPath $config.output.generated_dir $PSScriptRoot
    $intermediateDir = Join-Path $PSScriptRoot 'Intermediate'
    Initialize-ManagedRoot $generatedDir $PSScriptRoot
    Initialize-ManagedRoot $intermediateDir $PSScriptRoot
    # Failed runs retain their own logs, even after the next run.
    $runId = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $runDir = Join-Path $intermediateDir $runId
    New-Item -ItemType Directory -Path $runDir | Out-Null
    Start-Transcript -LiteralPath (Join-Path $runDir 'pipeline.log') | Out-Null
    $transcribing = $true
    $packageStage = Join-Path $runDir 'Package'
    New-Item -ItemType Directory -Path $packageStage | Out-Null
    $needsGit = @($selected | Where-Object { $_.git_repository_url }).Count -gt 0
    $needsPython = -not $SkipDownload -and @($selected | Where-Object { ($_.google_drive_file_id -and -not $UseCachedSpecs) -or $_.google_drive_zip_id }).Count -gt 0
    Initialize-PipelineEnvironment $PSScriptRoot $PythonCommand -RequireGit:$needsGit -RequirePython:$needsPython
    $results = @()
    $index = 0
    foreach ($work in $selected) {
        $index++
        Write-Host "[$index/$($selected.Count)] $($work.work_folder_name)"
        $options = @{
            Work = $work; Output = $config.output; RootPath = $PSScriptRoot
            WorkTemp = (Join-Path $runDir ('work_{0:00}' -f $index))
            WorkStage = (Join-Path $packageStage $work.work_folder_name)
            PythonCommand = $PythonCommand
            SkipDownload = $SkipDownload; SkipBuild = $SkipBuild; SkipSmokeTest = $SkipSmokeTest
            UseCachedSpecs = $UseCachedSpecs
        }
        $results += Invoke-CollectWork @options
    }
    $workDir = Join-Path $generatedDir $config.output.zip_name
    if ($TargetWork) {
        Assert-NoReparsePoint $workDir
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        Publish-Directory -Source (Join-Path $packageStage $TargetWork) -Destination (Join-Path $workDir $TargetWork) -AllowedRoot $generatedDir
        $oldZip = Join-Path $generatedDir ($config.output.zip_name + '.zip')
        if (Test-Path -LiteralPath $oldZip) { Remove-SafeItem $oldZip $generatedDir }
        Write-Host 'Targeted run: ZIP invalidated. Run all works to create a complete ZIP.'
    } else {
        ConvertTo-Json -InputObject @($results) -Depth 8 | Set-Content -LiteralPath (Join-Path $packageStage 'pipeline-result.json') -Encoding UTF8
        $zipStage = Join-Path $runDir 'submission.zip'
        New-SubmissionArchive $packageStage $zipStage
        Publish-Package -Source $packageStage -ZipSource $zipStage -Destination $workDir -ZipDestination (Join-Path $generatedDir ($config.output.zip_name + '.zip')) -AllowedRoot $generatedDir
    }
    $succeeded = $true
    Write-Host "Completed: $workDir" -ForegroundColor Green
} catch {
    Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($runDir) { Write-Host "Diagnostics retained: $runDir" }
} finally {
    if ($transcribing) { Stop-Transcript | Out-Null }
    if ($succeeded -and $runDir -and -not $KeepIntermediate) { Remove-SafeItem $runDir (Join-Path $PSScriptRoot 'Intermediate') }
}
if (-not $succeeded) { exit 1 }
