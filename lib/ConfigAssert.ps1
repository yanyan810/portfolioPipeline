function Assert-PathComponent {
    param([string]$Value, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[<>:"/\\|?*\x00-\x1f]' -or $Value -match '[. ]$' -or $Value -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') {
        throw "Invalid $Label (use a single Windows-safe name): '$Value'"
    }
}

function Assert-RelativePath {
    param([string]$Value, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Value) -or [IO.Path]::IsPathRooted($Value)) { throw "$Label must be relative." }
    foreach ($part in ($Value -split '[\\/]')) { Assert-PathComponent $part $Label }
}

function Assert-Config {
    param([hashtable]$Config, [string]$RootPath)
    if ($Config.output -isnot [hashtable]) { throw 'output must be a hashtable.' }
    Assert-PathComponent $Config.output.zip_name 'output.zip_name'
    if (-not $Config.output.generated_dir) { throw 'output.generated_dir is required.' }
    $generated = Resolve-ProjectPath $Config.output.generated_dir $RootPath
    $intermediate = Join-Path $RootPath 'Intermediate'
    Assert-SafeChildPath $generated $RootPath
    # Only a dedicated top-level output folder is allowed, never code folders.
    if ((Split-Path $generated -Parent) -ne [IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')) { throw 'generated_dir must be a dedicated top-level project folder.' }
    if ((Split-Path $generated -Leaf) -in @('.git', '.agents', '.codex', '.aws', 'lib', 'tests', 'docs', 'examples', 'Intermediate')) { throw 'generated_dir conflicts with a protected project folder.' }
    foreach ($name in @('project_folder_name', 'executable_folder_name')) {
        if ($Config.output.ContainsKey($name)) { Assert-PathComponent $Config.output.$name "output.$name" }
    }
    $proj = if ($Config.output.project_folder_name) { $Config.output.project_folder_name } else { 'SourceCode' }
    $exec = if ($Config.output.executable_folder_name) { $Config.output.executable_folder_name } else { 'Executable' }
    if ($proj -eq $exec -or $proj -eq 'collection.json' -or $exec -eq 'collection.json') { throw 'Source, executable and metadata names must be distinct.' }
    if ($null -eq $Config.works -or $Config.works -is [string] -or @($Config.works).Count -eq 0) { throw 'works must contain at least one work.' }
    $names = @{}
    foreach ($work in $Config.works) {
        if ($work -isnot [hashtable]) { throw 'Each work must be a hashtable.' }
        Assert-PathComponent $work.work_folder_name 'work_folder_name'
        if ($work.work_folder_name -eq 'pipeline-result.json' -or $names.ContainsKey($work.work_folder_name)) { throw "Duplicate/reserved work name: $($work.work_folder_name)" }
        $names[$work.work_folder_name] = $true
        foreach ($key in @('git_repository_url', 'local_source_path', 'local_executable_path', 'google_drive_file_id', 'google_drive_zip_id', 'project_msbuild_target_path')) {
            if ($work.ContainsKey($key) -and ($work.$key -isnot [string] -or [string]::IsNullOrWhiteSpace($work.$key))) { throw "$key must be a nonempty string when specified." }
        }
        $sourceCount = [int](-not [string]::IsNullOrWhiteSpace($work.git_repository_url)) + [int](-not [string]::IsNullOrWhiteSpace($work.local_source_path))
        if ($sourceCount -ne 1) { throw "Specify exactly one source (Git or local) for $($work.work_folder_name)." }
        if ($work.git_repository_url -and $work.git_repository_url -match '^https?://[^/]*@') { throw 'Do not embed credentials in a repository URL.' }
        foreach ($key in @('local_source_path', 'local_executable_path')) {
            if (-not $work.$key) { continue }
            $local = Resolve-ProjectPath $work.$key $RootPath
            if (-not (Test-Path -LiteralPath $local)) { throw "$key not found: $local" }
            Assert-NoReparsePoint $local
            if ($local -eq $generated -or $local -eq $intermediate -or (Test-PathWithinRoot $generated $local) -or (Test-PathWithinRoot $intermediate $local) -or (Test-PathWithinRoot $local $generated) -or (Test-PathWithinRoot $local $intermediate)) { throw 'A local input must not overlap pipeline output or intermediate folders.' }
            if ((Test-Path -LiteralPath $local -PathType Leaf) -and [IO.Path]::GetExtension($local) -ne '.zip') { throw "$key must be a folder or ZIP." }
        }
        foreach ($key in @('google_drive_file_id', 'google_drive_zip_id')) {
            if ($work.$key -and $work.$key -notmatch '^[A-Za-z0-9_-]+$') { throw "$key must contain a file ID, not a URL." }
        }
        foreach ($key in @('project_msbuild_target_path', 'project_build_output_relative_path', 'test_executable_name')) {
            if ($work.$key) { Assert-RelativePath $work.$key $key }
        }
        if ($work.ContainsKey('project_build_copy_list')) {
            if ($work.project_build_copy_list -is [string]) { throw 'project_build_copy_list must be an array.' }
            $leafNames = @{}
            foreach ($item in $work.project_build_copy_list) {
                Assert-RelativePath $item 'project_build_copy_list'
                $leaf = Split-Path $item -Leaf
                if ($leafNames.ContainsKey($leaf)) { throw "Build copy destinations collide: $leaf" }
                $leafNames[$leaf] = $true
            }
        }
        if ($work.project_msbuild_target_path) {
            if ($work.local_source_path -and (Test-Path -LiteralPath (Resolve-ProjectPath $work.local_source_path $RootPath) -PathType Leaf)) { throw 'A build requires a source directory, not a ZIP.' }
            if (-not $work.project_build_output_relative_path -and -not $work.project_build_copy_list) { throw 'A build requires project_build_output_relative_path or project_build_copy_list.' }
        }
        $execSources = [int][bool]$work.google_drive_zip_id + [int][bool]$work.local_executable_path + [int][bool]$work.project_msbuild_target_path
        if ($work.local_source_path -and (Test-Path -LiteralPath (Resolve-ProjectPath $work.local_source_path $RootPath) -PathType Leaf)) { $execSources++ }
        if ($execSources -gt 1) { throw 'Choose only one executable provider: build, Drive ZIP, or local.' }
        if ($work.ContainsKey('smoke_test_required') -and $work.smoke_test_required -isnot [bool]) { throw 'smoke_test_required must be a boolean.' }
        if ($work.ContainsKey('smoke_test_wait_seconds') -and ($work.smoke_test_wait_seconds -isnot [int] -or $work.smoke_test_wait_seconds -lt 0 -or $work.smoke_test_wait_seconds -gt 60)) { throw 'smoke_test_wait_seconds must be an integer from 0 to 60.' }
        if ($work.exclude_patterns -is [string]) { throw 'exclude_patterns must be an array.' }
        foreach ($pattern in $work.exclude_patterns) {
            if ($pattern -isnot [string] -or [string]::IsNullOrWhiteSpace($pattern) -or $pattern -match '[\\/]') { throw 'exclude_patterns must contain file/folder name patterns.' }
        }
    }
}
