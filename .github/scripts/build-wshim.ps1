#requires -Version 7.0
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'
$target = 'x86_64-pc-windows-msvc'
$root = Join-Path $env:RUNNER_TEMP ('wshim-release-' + [guid]::NewGuid().ToString('N'))
$copyA = Join-Path $root 'a'
$copyB = Join-Path $root 'b'

function Write-Step([string]$Text) {
    Write-Host "== $Text"
}

function New-Copy([string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($file in @('Cargo.toml', 'Cargo.lock', 'rust-toolchain.toml')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $file) -Destination $Destination
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'src') -Destination $Destination -Recurse
    Copy-Item -LiteralPath (Join-Path $RepoRoot '.cargo') -Destination $Destination -Recurse
}

function Get-PeTime([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    return [BitConverter]::ToUInt32($bytes, $pe + 8)
}

function Get-PeSections([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x00004550) {
        throw "not a PE image: $Path"
    }
    $count = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $table = $pe + 24 + $optionalSize
    $names = for ($i = 0; $i -lt $count; $i++) {
        $offset = $table + $i * 40
        [Text.Encoding]::ASCII.GetString($bytes, $offset, 8).TrimEnd([char]0)
    }
    return @($names)
}

function Get-Leaks([string]$Path, [string]$Copy) {
    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    $needles = @('C:\Users\', '\.rustup\', 'rust-src', 'rustup', 'hostedtoolcache', 'C:\Program Files', '/home/', '/tmp/', 'D:\a', $Copy)
    return @($needles | Where-Object { $text.Contains($_) } | Select-Object -Unique)
}

function Get-BinaryInfo([string]$Path, [string]$Dumpbin, [string]$Copy) {
    $size = (Get-Item -LiteralPath $Path).Length
    $imports = @()
    $sections = @(Get-PeSections $Path)
    $debugDirectories = -1
    $coffSymbols = -1

    if ($Dumpbin) {
        $dependents = @(& $Dumpbin /dependents $Path)
        $imports = @($dependents | ForEach-Object {
            if ($_ -match '^\s+([A-Za-z0-9_.-]+\.dll)\s*$') { $Matches[1] }
        })
        $headers = @(& $Dumpbin /headers $Path)
        $debugDirectories = @($headers | Select-String 'Debug Directories').Count
        $coffSymbols = @($headers | Select-String 'COFF Symbols').Count
    }

    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    $rustcPaths = ([regex]::Matches($text, '/rustc/[0-9a-f]+/')).Count
    $pdbPaths = ([regex]::Matches($text, '[A-Za-z0-9_.-]+\.pdb')).Count
    $time = Get-PeTime $Path
    $leaks = @(Get-Leaks $Path $Copy)
    $pdbFiles = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Filter '*.pdb' -ErrorAction SilentlyContinue).Count

    return [pscustomobject]@{
        size = $size
        dumpbin_available = [bool]$Dumpbin
        imports = @($imports)
        sections = @($sections)
        debug_directory = $debugDirectories
        coff_symbols = $coffSymbols
        pdb_paths = $pdbPaths
        pdb_files = $pdbFiles
        rustc_paths = $rustcPaths
        pe_time = ('0x{0:X8}' -f $time)
        leaks = @($leaks)
    }
}

function Get-ToolchainInfo() {
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
    $result = [ordered]@{ visual_studio = ''; msvc_toolsets = @(); sdks = @() }
    if (Test-Path -LiteralPath $vswhere) {
        $vs = @(& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)[0]
        if ($vs) {
            $result.visual_studio = $vs
            $result.msvc_toolsets = @(Get-ChildItem -Path (Join-Path $vs 'VC\Tools\MSVC\*') -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^[0-9]+\.[0-9]+\.[0-9]+$' } |
                Sort-Object { [version]$_.Name } -Descending |
                Select-Object -ExpandProperty Name)
        }
    }
    $sdkRoot = Join-Path $pf86 'Windows Kits\10\Include'
    if (Test-Path -LiteralPath $sdkRoot) {
        $result.sdks = @(Get-ChildItem -LiteralPath $sdkRoot -Directory | Select-Object -ExpandProperty Name)
    }
    return $result
}

function Build-One([string]$Copy, [string]$Dumpbin) {
    $env:CARGO_TARGET_DIR = Join-Path $Copy 'target'
    $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = "-C target-feature=+crt-static -C link-arg=/Brepro -C link-arg=/DEBUG:NONE --remap-path-prefix=$Copy=/wshim"

    Push-Location $Copy
    try {
        & cargo build --release --locked --target $target -j 1
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed in $Copy"
        }
    } finally {
        Pop-Location
    }

    $release = Join-Path $env:CARGO_TARGET_DIR (Join-Path $target 'release')
    $exeC = Join-Path $release 'wshim-c.exe'
    $exeW = Join-Path $release 'wshim-w.exe'
    $infoC = Get-BinaryInfo $exeC $Dumpbin $Copy
    $infoW = Get-BinaryInfo $exeW $Dumpbin $Copy
    return [pscustomobject]@{
        C = $exeC
        W = $exeW
        HashC = (Get-FileHash -LiteralPath $exeC -Algorithm SHA256).Hash
        HashW = (Get-FileHash -LiteralPath $exeW -Algorithm SHA256).Hash
        InfoC = $infoC
        InfoW = $infoW
    }
}

Write-Step "tag $Tag"
Write-Step "repo $RepoRoot"
$env:SOURCE_DATE_EPOCH = '0'
$env:CARGO_INCREMENTAL = '0'
$env:RUSTUP_AUTO_INSTALL = '1'
Remove-Item Env:\RUSTFLAGS -ErrorAction SilentlyContinue
Remove-Item Env:\CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS -ErrorAction SilentlyContinue

$toolchain = Get-ToolchainInfo
$dumpbin = $null
if ($toolchain.visual_studio) {
    $dumpbin = Get-ChildItem -Path (Join-Path $toolchain.visual_studio 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe') -ErrorAction SilentlyContinue | Select-Object -First 1
}
$dumpbinPath = if ($null -ne $dumpbin) { $dumpbin.FullName } else { '' }
if (-not $dumpbinPath) {
    Write-Step 'dumpbin not found; metadata will be incomplete (manual inspection still required)'
}

New-Copy $copyA
New-Copy $copyB
$a = Build-One $copyA $dumpbinPath
$b = Build-One $copyB $dumpbinPath
if ($a.HashC -ne $b.HashC -or $a.HashW -ne $b.HashW) {
    throw 'A/B hashes differ'
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Copy-Item -LiteralPath $a.C -Destination (Join-Path $OutputDir 'wshim-c.exe')
Copy-Item -LiteralPath $a.W -Destination (Join-Path $OutputDir 'wshim-w.exe')
@(
    "$($a.HashC)  wshim-c.exe",
    "$($a.HashW)  wshim-w.exe"
) | Set-Content -LiteralPath (Join-Path $OutputDir 'sha256.txt') -Encoding ascii

$commit = (& git -C $RepoRoot rev-parse HEAD).Trim()
Push-Location $copyA
$activeToolchain = ((& rustup show active-toolchain) -join ' ').Trim()
$rustc = ((& rustc -Vv) -join ' | ')
$cargo = (& cargo -V)
Pop-Location
$toolchainName = ($activeToolchain -split '\s+')[0]
$manifest = [ordered]@{
    tag = $Tag
    commit = $commit
    ref = "refs/tags/$Tag"
    image_os = $env:ImageOS
    image_version = $env:ImageVersion
    target = $target
    toolchain = $toolchainName
    rustc = $rustc
    cargo = $cargo
    visual_studio = $toolchain.visual_studio
    msvc_toolsets = @($toolchain.msvc_toolsets)
    sdks = @($toolchain.sdks)
    flags = $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS
    hash_c = $a.HashC
    hash_w = $a.HashW
    pe_time_c = $a.InfoC.pe_time
    pdb = $a.InfoC.pdb_files
    leaks = @($a.InfoC.leaks)
    size_c = $a.InfoC.size
    binary_c = $a.InfoC
    binary_w = $a.InfoW
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDir 'manifest.json') -Encoding utf8

Write-Step 'artifact'
Get-ChildItem -LiteralPath $OutputDir | Format-Table -AutoSize
