#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$ArtifactDir
)

$ErrorActionPreference = 'Stop'

function Get-PeTime([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    return [BitConverter]::ToUInt32($bytes, $pe + 8)
}

$pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
$vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
$dumpbin = $null
if (Test-Path -LiteralPath $vswhere) {
    $vs = @(& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)[0]
    if ($vs) {
        $dumpbin = Get-ChildItem -Path (Join-Path $vs 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe') -ErrorAction SilentlyContinue | Select-Object -First 1
    }
}
if ($null -eq $dumpbin) {
    $cmd = Get-Command dumpbin -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { $dumpbin = Get-Item $cmd.Source }
}

Write-Host "artifact: $ArtifactDir"
Write-Host "dumpbin:  $(if ($dumpbin) { $dumpbin.FullName } else { '(not found)' })"
Write-Host ''

foreach ($name in @('wshim-c.exe', 'wshim-w.exe')) {
    $exe = Join-Path $ArtifactDir $name
    if (-not (Test-Path -LiteralPath $exe)) { continue }
    $size = (Get-Item -LiteralPath $exe).Length
    $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    $time = Get-PeTime $exe
    Write-Host "=== $name ==="
    Write-Host "size: $size bytes"
    Write-Host "sha256: $hash"
    Write-Host ("pe timestamp: 0x{0:X8}" -f $time)
    Write-Host "pdb files beside: $(@(Get-ChildItem -LiteralPath $ArtifactDir -Filter '*.pdb' -ErrorAction SilentlyContinue).Count)"

    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($exe))
    foreach ($needle in @('C:\Users\', 'D:\a', '/rustc/', 'rustup', 'rust-src', '/home/', '/tmp/', '.pdb')) {
        $count = ([regex]::Matches($text, [regex]::Escape($needle))).Count
        Write-Host ("path-string {0,-12} {1}" -f $needle, $count)
    }

    if ($dumpbin) {
        Write-Host '-- dependents --'
        & $dumpbin.FullName /dependents $exe
        Write-Host '-- headers (selected) --'
        & $dumpbin.FullName /headers $exe | Select-String 'Debug Directories|COFF Symbols|SECTION HEADER|name$|size of raw data|time date stamp'
    }
    Write-Host ''
}

Write-Host 'Manual review: paths, timestamp, imports/CRT, PDB/debug, sections, size. This script only reports.'
