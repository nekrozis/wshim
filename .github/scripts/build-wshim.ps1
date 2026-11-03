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

function Get-Leaks([string]$Path, [string]$Copy) {
    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    $needles = @('C:\Users\', '\.rustup\', 'rust-src', 'rustup', 'hostedtoolcache', 'C:\Program Files', '/home/', '/tmp/', 'D:\a', $Copy)
    return @($needles | Where-Object { $text.Contains($_) } | Select-Object -Unique)
}

function Get-LinkInfo() {
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
    $result = [ordered]@{ visual_studio = ''; link_version = ''; sdks = @() }
    if (Test-Path -LiteralPath $vswhere) {
        $vs = @(& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)[0]
        if ($vs) {
            $result.visual_studio = $vs
            $link = Get-ChildItem -Path (Join-Path $vs 'VC\Tools\MSVC\*\bin\Hostx64\x64\link.exe') -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $link) {
                $result.link_version = $link.VersionInfo.FileVersion
            }
        }
    }
    $sdkRoot = Join-Path $pf86 'Windows Kits\10\Include'
    if (Test-Path -LiteralPath $sdkRoot) {
        $result.sdks = @(Get-ChildItem -LiteralPath $sdkRoot -Directory | Select-Object -ExpandProperty Name)
    }
    return $result
}

function Build-One([string]$Copy) {
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
    return [pscustomobject]@{
        C = $exeC
        W = $exeW
        HashC = (Get-FileHash -LiteralPath $exeC -Algorithm SHA256).Hash
        HashW = (Get-FileHash -LiteralPath $exeW -Algorithm SHA256).Hash
        TimeC = Get-PeTime $exeC
        Pdb = @(Get-ChildItem -LiteralPath $release -Filter '*.pdb' -ErrorAction SilentlyContinue).Count
        Leaks = @(Get-Leaks $exeC $Copy)
        SizeC = (Get-Item -LiteralPath $exeC).Length
    }
}

Write-Step "tag $Tag"
Write-Step "repo $RepoRoot"
$env:SOURCE_DATE_EPOCH = '0'
$env:CARGO_INCREMENTAL = '0'
$env:RUSTUP_AUTO_INSTALL = '1'
Remove-Item Env:\RUSTFLAGS -ErrorAction SilentlyContinue
Remove-Item Env:\CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS -ErrorAction SilentlyContinue

New-Copy $copyA
New-Copy $copyB
$a = Build-One $copyA
$b = Build-One $copyB
if ($a.HashC -ne $b.HashC -or $a.HashW -ne $b.HashW) {
    throw 'A/B hashes differ'
}
if ($a.Leaks.Count -gt 0 -or $b.Leaks.Count -gt 0) {
    throw ('path leaks: ' + (@($a.Leaks + $b.Leaks) -join ','))
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
$link = Get-LinkInfo
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
    visual_studio = $link.visual_studio
    link_version = $link.link_version
    sdks = @($link.sdks)
    flags = $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS
    hash_c = $a.HashC
    hash_w = $a.HashW
    pe_time_c = ('0x{0:X8}' -f $a.TimeC)
    pdb = $a.Pdb
    leaks = @($a.Leaks)
    size_c = $a.SizeC
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDir 'manifest.json') -Encoding utf8

Write-Step 'artifact'
Get-ChildItem -LiteralPath $OutputDir | Format-Table -AutoSize
