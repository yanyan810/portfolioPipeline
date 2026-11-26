function Resolve-ProjectPath {
    param([string]$Path, [string]$RootPath)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not allowed.' }
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $RootPath $Path }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-PathWithinRoot {
    param([string]$Path, [string]$Root)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePoint {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Links/junctions are not allowed here: $cursor" }
        }
        $parent = Split-Path -Path $cursor -Parent
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-SafeChildPath {
    param([string]$Path, [string]$AllowedRoot)
    if (-not (Test-PathWithinRoot $Path $AllowedRoot)) { throw "Path is outside the allowed root: $Path" }
    Assert-NoReparsePoint $Path
}

function Initialize-ManagedRoot {
    param([string]$Path, [string]$ProjectRoot)
    Assert-SafeChildPath $Path $ProjectRoot
    $marker = Join-Path $Path '.portfolio-pipeline-output'
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Not a directory: $Path" }
        if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0 -and -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            throw "Refusing to use a nonempty unmanaged output directory: $Path"
        }
    } else { New-Item -ItemType Directory -Path $Path | Out-Null }
    if (-not (Test-Path -LiteralPath $marker)) { Set-Content -LiteralPath $marker -Value 'PortfolioPipeline output directory' -Encoding ASCII }
}

function Remove-SafeItem {
    param([string]$Path, [string]$AllowedRoot)
    Assert-SafeChildPath $Path $AllowedRoot
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
}

function Recreate-Directory {
    param([string]$Path, [string]$AllowedRoot)
    Remove-SafeItem $Path $AllowedRoot
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Test-ExcludedName {
    param([string]$Name, [string[]]$ExcludePatterns = @())
    # Preserve required dotfiles such as .editorconfig and .clang-format.
    $patterns = @('.git', '.vs', '.vscode', '__MACOSX', '__pycache__', 'desktop.ini', 'Thumbs.db', '*.pdb', '*.pyc', '.env', 'credentials.json', 'token.json') + $ExcludePatterns
    foreach ($pattern in $patterns) { if ($Name -like $pattern) { return $true } }
    return $false
}

function Copy-ItemWithExclude {
    param([string]$Source, [string]$Destination, [string[]]$ExcludePatterns = @())
    $sourceFull = [IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    $destFull = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    if ($sourceFull -eq $destFull -or (Test-PathWithinRoot $destFull $sourceFull) -or (Test-PathWithinRoot $sourceFull $destFull)) { throw 'Copy source and destination must not overlap.' }
    Assert-NoReparsePoint $sourceFull
    Assert-NoReparsePoint $destFull
    $item = Get-Item -LiteralPath $sourceFull -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        if (Test-ExcludedName $item.Name $ExcludePatterns) { return }
        [IO.Directory]::CreateDirectory((Split-Path $destFull -Parent)) | Out-Null
        [IO.File]::Copy($sourceFull, $destFull, $true)
        return
    }
    [IO.Directory]::CreateDirectory($destFull) | Out-Null
    # Validate ancestors once, then inspect every traversed entry for links.
    $pending = New-Object 'System.Collections.Generic.Stack[object]'
    $pending.Push(@{ source = $sourceFull; dest = $destFull })
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($child in Get-ChildItem -LiteralPath $directory.source -Force) {
            if (Test-ExcludedName $child.Name $ExcludePatterns) { continue }
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Links/junctions cannot be collected: $($child.FullName)" }
            $target = Join-Path $directory.dest $child.Name
            if (Test-Path -LiteralPath $target) {
                $existing = Get-Item -LiteralPath $target -Force
                if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Destination is a link: $target" }
            }
            if ($child.PSIsContainer) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
                $pending.Push(@{ source = $child.FullName; dest = $target })
            } else { [IO.File]::Copy($child.FullName, $target, $true) }
        }
    }
}

function Expand-AndFlattenArchive {
    param([string]$ZipPath, [string]$TempExtractDir, [string]$DestinationDir, [string[]]$ExcludePatterns = @())
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $TempExtractDir) { throw "Extraction directory must be new: $TempExtractDir" }
    New-Item -ItemType Directory -Path $TempExtractDir -Force | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $relative = $entry.FullName.Replace('/', '\')
            if ($relative -match '(^[\\/]|:|(^|[\\/])\.\.([\\/]|$))' -or $relative -match '[<>"|?*]') { throw "Unsafe ZIP entry: $($entry.FullName)" }
            foreach ($part in ($relative.TrimEnd('\') -split '\\')) {
                if (-not $part -or $part -match '[. ]$|[\x00-\x1f]' -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') { throw "Unsafe ZIP path component: $part" }
            }
            $unixType = ($entry.ExternalAttributes -shr 16) -band 61440
            if ($unixType -eq 40960 -or ($entry.ExternalAttributes -band 1024)) { throw 'ZIP links are not supported.' }
            $target = [IO.Path]::GetFullPath((Join-Path $TempExtractDir $relative))
            Assert-SafeChildPath $target $TempExtractDir
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
            } else {
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            }
        }
    } finally { $archive.Dispose() }
    $top = @(Get-ChildItem -LiteralPath $TempExtractDir -Force | Where-Object { -not (Test-ExcludedName $_.Name $ExcludePatterns) })
    $copySource = $TempExtractDir
    if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $copySource = $top[0].FullName }
    Copy-ItemWithExclude $copySource $DestinationDir $ExcludePatterns
}

function New-SubmissionArchive {
    param([string]$Source, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Assert-NoReparsePoint $Destination
    [IO.Compression.ZipFile]::CreateFromDirectory($Source, $Destination, [IO.Compression.CompressionLevel]::Optimal, $false)
}

function Publish-Directory {
    param([string]$Source, [string]$Destination, [string]$AllowedRoot)
    Assert-SafeChildPath $Destination $AllowedRoot
    Assert-SafeChildPath $Source (Split-Path $AllowedRoot -Parent)
    $backup = $Destination + '.backup_' + [guid]::NewGuid().ToString('N')
    $hadOld = Test-Path -LiteralPath $Destination
    if ($hadOld) { Move-Item -LiteralPath $Destination -Destination $backup }
    try { Move-Item -LiteralPath $Source -Destination $Destination }
    catch {
        if ($hadOld) { Move-Item -LiteralPath $backup -Destination $Destination }
        throw
    }
    if ($hadOld) { Remove-SafeItem $backup $AllowedRoot }
}

function Publish-Package {
    param([string]$Source, [string]$ZipSource, [string]$Destination, [string]$ZipDestination, [string]$AllowedRoot)
    Assert-SafeChildPath $Destination $AllowedRoot
    Assert-SafeChildPath $ZipDestination $AllowedRoot
    Assert-SafeChildPath $Source (Split-Path $AllowedRoot -Parent)
    Assert-SafeChildPath $ZipSource (Split-Path $AllowedRoot -Parent)
    $suffix = '.backup_' + [guid]::NewGuid().ToString('N')
    $pairs = @(@{ source = $Source; dest = $Destination }, @{ source = $ZipSource; dest = $ZipDestination })
    $backedUp = @()
    $published = @()
    try {
        foreach ($pair in $pairs) {
            if (Test-Path -LiteralPath $pair.dest) {
                Move-Item -LiteralPath $pair.dest -Destination ($pair.dest + $suffix)
                $backedUp += $pair
            }
        }
        foreach ($pair in $pairs) {
            Move-Item -LiteralPath $pair.source -Destination $pair.dest
            $published += $pair
        }
    } catch {
        foreach ($pair in $published) { Remove-SafeItem $pair.dest $AllowedRoot }
        foreach ($pair in $backedUp) { Move-Item -LiteralPath ($pair.dest + $suffix) -Destination $pair.dest }
        throw
    }
    foreach ($pair in $backedUp) { Remove-SafeItem ($pair.dest + $suffix) $AllowedRoot }
}
