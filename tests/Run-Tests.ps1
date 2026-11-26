#requires -Version 5.1
param([string]$Shell = 'pwsh')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($lib in @('FileUtils', 'ConfigAssert', 'BuildUtils', 'PipelineTasks')) { . (Join-Path $root "lib/$lib.ps1") }
$caseRoot = Join-Path $root ('TestResults/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
$script:passed = 0
function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    & $Action
    $script:passed++
    Write-Host "PASS $Name" -ForegroundColor Green
}
$source = Join-Path $caseRoot 'source'
New-Item -ItemType Directory -Path (Join-Path $source 'src/nested'), (Join-Path $source '.git'), (Join-Path $source 'assets') -Force | Out-Null
foreach ($entry in @('src/nested/main.cpp', 'assets/settings.ini', 'LICENSE.txt', '.editorconfig', '.git/config', 'Thumbs.db', 'game.pdb', 'notes.tmp', 'token.json')) {
    Set-Content -LiteralPath (Join-Path $source $entry) -Value $entry -Encoding UTF8
}
$copy = Join-Path $caseRoot 'copy'
Test-Case 'Nested copy excludes unwanted files and preserves necessary dotfiles' {
    Copy-ItemWithExclude $source $copy @('*.tmp')
    foreach ($entry in @('src/nested/main.cpp', 'assets/settings.ini', 'LICENSE.txt', '.editorconfig')) { Assert-True (Test-Path -LiteralPath (Join-Path $copy $entry)) "Missing $entry" }
    foreach ($entry in @('.git', 'Thumbs.db', 'game.pdb', 'notes.tmp', 'token.json')) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $copy $entry))) "Unexpected $entry" }
}
Test-Case 'Recursive self-copy is refused' { Assert-Throws { Copy-ItemWithExclude $source (Join-Path $source 'child') } 'Self-copy was allowed' }
Test-Case 'Deletion refuses the root and its siblings' {
    Assert-Throws { Remove-SafeItem $caseRoot $caseRoot } 'Root deletion was allowed'
    Assert-Throws { Remove-SafeItem (Join-Path $root 'PortfolioPipeline.ps1') $caseRoot } 'Sibling deletion was allowed'
}
Test-Case 'Unmanaged nonempty outputs are refused' { Assert-Throws { Initialize-ManagedRoot $source $caseRoot } 'Unmanaged output was accepted' }
$config = @{
    output = @{ zip_name = 'TestSubmission'; generated_dir = './Generated' }
    works = @(@{ work_folder_name = '01_Work'; local_source_path = $source })
}
Test-Case 'Valid config' { Assert-Config $config $root }
Test-Case 'Empty work list is an error' {
    $bad = @{ output = $config.output; works = @() }
    Assert-Throws { Assert-Config $bad $root } 'Empty works was accepted'
}
Test-Case 'Ambiguous Git/local source is an error' {
    $work = $config.works[0].Clone(); $work.git_repository_url = 'https://example.com/repo.git'
    Assert-Throws { Assert-Config @{ output = $config.output; works = @($work) } $root } 'Ambiguous source was accepted'
}
Test-Case 'Missing local source is an error' {
    $work = $config.works[0].Clone(); $work.local_source_path = Join-Path $caseRoot 'does-not-exist'
    Assert-Throws { Assert-Config @{ output = $config.output; works = @($work) } $root } 'Missing source was accepted'
}
Test-Case 'Traversal and duplicate work names are errors' {
    $work = $config.works[0].Clone(); $work.work_folder_name = '..'
    Assert-Throws { Assert-Config @{ output = $config.output; works = @($work) } $root } 'Traversal name was accepted'
    Assert-Throws { Assert-Config @{ output = $config.output; works = @($config.works[0], $config.works[0]) } $root } 'Duplicate name was accepted'
}
Test-Case 'Output/source overlap and protected folders are errors' {
    $work = $config.works[0].Clone(); $work.local_source_path = $root
    Assert-Throws { Assert-Config @{ output = $config.output; works = @($work) } $root } 'Overlapping source was accepted'
    Assert-Throws { Assert-Config @{ output = @{ zip_name = 'x'; generated_dir = './lib' }; works = $config.works } $root } 'Code directory was accepted as output'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $caseRoot 'valid.zip'
$wrapper = Join-Path $caseRoot 'wrapper'
New-Item -ItemType Directory -Path (Join-Path $wrapper 'Game/data') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $wrapper 'Game/data/settings.txt') -Value 'keep'
[IO.Compression.ZipFile]::CreateFromDirectory($wrapper, $zip)
Test-Case 'ZIP wrapper is flattened and nested data survives' {
    $dest = Join-Path $caseRoot 'zip-output'
    Expand-AndFlattenArchive $zip (Join-Path $caseRoot 'extract') $dest
    Assert-True (Test-Path -LiteralPath (Join-Path $dest 'data/settings.txt')) 'ZIP structure was not flattened'
}
Test-Case 'ZIP traversal is rejected before writing outside extraction root' {
    $badZip = Join-Path $caseRoot 'bad.zip'
    $archive = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
    $entry = $archive.CreateEntry('../escape.txt'); $writer = New-Object IO.StreamWriter($entry.Open()); $writer.Write('bad'); $writer.Dispose(); $archive.Dispose()
    Assert-Throws { Expand-AndFlattenArchive $badZip (Join-Path $caseRoot 'bad-extract') (Join-Path $caseRoot 'bad-output') } 'ZIP traversal was accepted'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseRoot 'escape.txt'))) 'ZIP escaped'
}
Test-Case 'Published package restores old directory and ZIP on a failed replacement' {
    $out = Join-Path $caseRoot 'owned'; New-Item -ItemType Directory -Path $out | Out-Null
    $old = Join-Path $out 'Submission'; New-Item -ItemType Directory -Path $old | Out-Null
    Set-Content -LiteralPath (Join-Path $old 'previous.txt') -Value 'old'
    $oldZip = Join-Path $out 'Submission.zip'; Set-Content -LiteralPath $oldZip -Value 'old-zip'
    $stage = Join-Path $caseRoot 'staged'; New-Item -ItemType Directory -Path $stage | Out-Null
    Set-Content -LiteralPath (Join-Path $stage 'new.txt') -Value 'new'
    Assert-Throws { Publish-Package $stage (Join-Path $caseRoot 'missing.zip') $old $oldZip $out } 'Expected replacement failure'
    Assert-True (Test-Path -LiteralPath (Join-Path $old 'previous.txt')) 'Previous directory was lost'
    Assert-True ((Get-Content -LiteralPath $oldZip -Raw).Trim() -eq 'old-zip') 'Previous ZIP was lost'
}
Test-Case 'Smoke policy distinguishes missing optional and required EXE' {
    Assert-True ((Test-ExecutableSmoke (Join-Path $caseRoot 'no-exe')) -eq 'not_applicable') 'Optional missing EXE was not skipped'
    Assert-Throws { Test-ExecutableSmoke (Join-Path $caseRoot 'no-exe') -Required } 'Required EXE was skipped'
    Assert-Throws { Test-ExecutableSmoke $caseRoot 'missing.exe' } 'Explicit missing EXE was skipped'
}
Test-Case 'Nonzero external exit propagates and preserves a build log' {
    $log = Join-Path $caseRoot 'failed-msbuild.log'
    Assert-Throws { Invoke-NativeCommand $Shell @('-NoProfile', '-Command', "Write-Output 'build failed'; exit 7") $log } 'External failure was ignored'
    Assert-True ((Get-Content -LiteralPath $log -Raw) -match 'build failed') 'Failure log was lost'
}
Test-Case 'Git source is shallow, records its revision, and excludes repository metadata on deployment' {
    $origin = Join-Path $caseRoot 'git-origin'
    $null = Invoke-NativeCommand 'git' @('init', '-b', 'main', $origin)
    Set-Content -LiteralPath (Join-Path $origin 'source.txt') -Value 'tracked source'
    $null = Invoke-NativeCommand 'git' @('-C', $origin, 'add', 'source.txt')
    $null = Invoke-NativeCommand 'git' @('-C', $origin, '-c', 'user.name=Pipeline Test', '-c', 'user.email=pipeline-test@example.invalid', 'commit', '-m', 'Test source')
    $clone = Join-Path $caseRoot 'git-clone'
    $fileUrl = ([uri]($origin + '\')).AbsoluteUri.TrimEnd('/')
    $provenance = Get-SourceFromGit $fileUrl $clone
    Assert-True ($provenance.commit -match '^[0-9a-f]{40}$') 'Commit ID was not recorded'
    Assert-True (Test-Path -LiteralPath (Join-Path $clone '.git/shallow')) 'Clone was not shallow'
    $gitDest = Join-Path $caseRoot 'git-deployment'
    Copy-ItemWithExclude $clone $gitDest
    Assert-True (Test-Path -LiteralPath (Join-Path $gitDest 'source.txt')) 'Tracked source missing'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitDest '.git'))) 'Git metadata was deployed'
}
Test-Case 'Successful and failed MSBuild tasks retain logs and deploy selected artifacts only' {
    $buildSource = Join-Path $caseRoot 'build-source'
    New-Item -ItemType Directory -Path $buildSource | Out-Null
    $project = @'
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Target Name="Build"><MakeDir Directories="$(OutDir)" /><WriteLinesToFile File="$(OutDir)artifact.txt" Lines="built" Overwrite="true" /></Target>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $buildSource 'Test.proj') -Value $project -Encoding UTF8
    $buildWork = @{ project_msbuild_target_path = 'Test.proj'; project_build_copy_list = @('.pipeline_build/Output/artifact.txt') }
    $buildDest = Join-Path $caseRoot 'build-destination'
    $buildLog = Join-Path $caseRoot 'msbuild.log'
    Invoke-MSBuildAndDeploy $buildWork $buildSource $buildDest $buildLog
    Assert-True (Test-Path -LiteralPath (Join-Path $buildDest 'artifact.txt')) 'Build artifact was not deployed'
    Assert-True (Test-Path -LiteralPath $buildLog) 'Successful build log missing'
    $project = '<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003"><Target Name="Build"><Error Text="Intentional test failure" /></Target></Project>'
    Set-Content -LiteralPath (Join-Path $buildSource 'Test.proj') -Value $project -Encoding UTF8
    Assert-Throws { Invoke-MSBuildAndDeploy $buildWork $buildSource $buildDest $buildLog } 'Failed build was accepted'
    Assert-True ((Get-Content -LiteralPath $buildLog -Raw) -match 'Intentional test failure') 'MSBuild diagnostic was not retained'
}
Test-Case 'Smoke detects crashes and terminates an application that keeps running' {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $smokeDir = Join-Path $caseRoot 'smoke'
    New-Item -ItemType Directory -Path $smokeDir | Out-Null
    $crashSource = Join-Path $smokeDir 'Crash.cs'
    Set-Content -LiteralPath $crashSource -Value 'class Crash { static void Main() { System.Environment.Exit(9); } }'
    $crashExe = Join-Path $smokeDir 'Crash.exe'
    $null = Invoke-NativeCommand $csc @('/nologo', ('/out:' + $crashExe), $crashSource)
    Assert-Throws { Test-ExecutableSmoke $smokeDir 'Crash.exe' -Required -WaitSeconds 1 } 'Crash was accepted'
    $waitSource = Join-Path $smokeDir 'Wait.cs'
    $pidFile = Join-Path $smokeDir 'pid.txt'
    $pidLiteral = $pidFile.Replace('\', '\\')
    $program = 'class Wait { static void Main() { System.IO.File.WriteAllText("' + $pidLiteral + '", System.Diagnostics.Process.GetCurrentProcess().Id.ToString()); System.IO.File.WriteAllText("runtime-generated.txt", "startup side effect"); System.Threading.Thread.Sleep(30000); } }'
    Set-Content -LiteralPath $waitSource -Value $program
    $waitExe = Join-Path $smokeDir 'Wait.exe'
    $null = Invoke-NativeCommand $csc @('/nologo', ('/out:' + $waitExe), $waitSource)
    Assert-True ((Test-ExecutableSmoke $smokeDir 'Wait.exe' -Required -WaitSeconds 1) -eq 'passed') 'Running program failed smoke'
    $testProcessId = [int](Get-Content -LiteralPath $pidFile)
    Assert-True ($null -eq (Get-Process -Id $testProcessId -ErrorAction SilentlyContinue)) 'Smoke process was left running'
}
Test-Case 'Pipeline smoke side effects stay in Intermediate, outside submitted executable files' {
    $smokeInput = Join-Path $caseRoot 'smoke'
    Remove-SafeItem (Join-Path $smokeInput 'runtime-generated.txt') $caseRoot
    $isolatedTemp = Join-Path $caseRoot 'isolated-temp'
    $isolatedStage = Join-Path $caseRoot 'isolated-stage'
    $isolatedWork = @{ work_folder_name = 'isolated'; local_source_path = $source; local_executable_path = $smokeInput; test_executable_name = 'Wait.exe'; smoke_test_required = $true; smoke_test_wait_seconds = 1 }
    $record = Invoke-CollectWork -Work $isolatedWork -Output @{} -RootPath $root -WorkTemp $isolatedTemp -WorkStage $isolatedStage
    Assert-True ($record.smoke_test -eq 'passed') 'Isolated smoke failed'
    Assert-True (Test-Path -LiteralPath (Join-Path $isolatedTemp 'Smoke/runtime-generated.txt')) 'Smoke did not generate the expected fixture'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $isolatedStage 'Executable/runtime-generated.txt'))) 'Runtime side effect entered the submission'
}

# Exercise the public entry point in a separate process, including rerun/failure behavior.
$packageName = 'Test_' + [guid]::NewGuid().ToString('N')
$configFile = Join-Path $caseRoot 'config.psd1'
$escapedSource = $source.Replace("'", "''")
$configText = "@{ output = @{ zip_name = '$packageName'; generated_dir = './Generated' }; works = @(@{ work_folder_name = '01_A'; local_source_path = '$escapedSource'; google_drive_file_id = 'unused' }, @{ work_folder_name = '02_B'; local_source_path = '$escapedSource' }) }"
Set-Content -LiteralPath $configFile -Value $configText -Encoding UTF8
$pipeline = Join-Path $root 'PortfolioPipeline.ps1'
$package = Join-Path $root ('Generated/' + $packageName)
Test-Case 'End-to-end: SkipDownload calls no Python, full ZIP and clean successful run' {
    $beforeRuns = @(Get-ChildItem -LiteralPath (Join-Path $root 'Intermediate') -Directory | Select-Object -ExpandProperty Name)
    $null = Invoke-NativeCommand $Shell @('-NoProfile', '-File', $pipeline, '-ConfigPath', $configFile, '-SkipDownload', '-PythonCommand', 'THIS_PYTHON_MUST_NOT_RUN')
    Assert-True (Test-Path -LiteralPath ($package + '.zip')) 'Full ZIP missing'
    Assert-True (Test-Path -LiteralPath (Join-Path $package '01_A/SourceCode/src/nested/main.cpp')) 'Source missing'
    $record = Get-Content -LiteralPath (Join-Path $package '01_A/collection.json') -Raw | ConvertFrom-Json
    Assert-True $record.skipped.download 'SkipDownload not recorded'
    $afterRuns = @(Get-ChildItem -LiteralPath (Join-Path $root 'Intermediate') -Directory | Select-Object -ExpandProperty Name)
    Assert-True (@($afterRuns | Where-Object { $_ -notin $beforeRuns }).Count -eq 0) 'Successful run was not cleaned up'
}
Test-Case 'End-to-end: targeted rerun leaves other work alone and invalidates ZIP' {
    Set-Content -LiteralPath (Join-Path $package '02_B/sentinel.txt') -Value 'must stay'
    Set-Content -LiteralPath (Join-Path $package '01_A/obsolete.txt') -Value 'must go'
    $null = Invoke-NativeCommand $Shell @('-NoProfile', '-File', $pipeline, '-ConfigPath', $configFile, '-TargetWork', '01_A', '-SkipDownload')
    Assert-True (Test-Path -LiteralPath (Join-Path $package '02_B/sentinel.txt')) 'Other work was changed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $package '01_A/obsolete.txt'))) 'Stale target output survived'
    Assert-True (-not (Test-Path -LiteralPath ($package + '.zip'))) 'Stale full ZIP survived'
}
Test-Case 'End-to-end: unknown TargetWork fails without changing output' {
    Assert-Throws { Invoke-NativeCommand $Shell @('-NoProfile', '-File', $pipeline, '-ConfigPath', $configFile, '-TargetWork', 'UNKNOWN', '-SkipDownload') } 'Unknown target succeeded'
    Assert-True (Test-Path -LiteralPath (Join-Path $package '02_B/sentinel.txt')) 'Output changed'
}
Test-Case 'End-to-end: failed clone keeps previous submission and diagnostics' {
    $beforeRuns = @(Get-ChildItem -LiteralPath (Join-Path $root 'Intermediate') -Directory | Select-Object -ExpandProperty Name)
    $badUrl = (Join-Path $caseRoot 'missing-repository').Replace("'", "''")
    $badConfig = "@{ output = @{ zip_name = '$packageName'; generated_dir = './Generated' }; works = @(@{ work_folder_name = '01_A'; git_repository_url = '$badUrl' }) }"
    Set-Content -LiteralPath $configFile -Value $badConfig -Encoding UTF8
    Assert-Throws { Invoke-NativeCommand $Shell @('-NoProfile', '-File', $pipeline, '-ConfigPath', $configFile) } 'Bad clone succeeded'
    Assert-True (Test-Path -LiteralPath (Join-Path $package '02_B/sentinel.txt')) 'Previous package was destroyed'
    $failedRuns = @(Get-ChildItem -LiteralPath (Join-Path $root 'Intermediate') -Directory | Where-Object { $_.Name -notin $beforeRuns })
    Assert-True ($failedRuns.Count -eq 1) 'Failed run was not retained'
    Assert-True (Test-Path -LiteralPath (Join-Path $failedRuns[0].FullName 'pipeline.log')) 'Failed run log missing'
}
Write-Host "$script:passed PowerShell checks passed. Test evidence: $caseRoot" -ForegroundColor Green
