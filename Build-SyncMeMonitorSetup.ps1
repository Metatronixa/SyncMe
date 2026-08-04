#Requires -Version 5.1
<#
.SYNOPSIS
  Builds SyncMe-Monitor-Setup-<ver> customer package.
#>
[CmdletBinding()]
param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot 'Monitor'
if (-not (Test-Path -LiteralPath (Join-Path $root 'SyncMe-Monitor-Host.ps1'))) {
    throw "Monitor source not found: $root"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $PSScriptRoot 'dist' }

$verFile = Join-Path $root 'VERSION.txt'
$pkgVer = '1.0.0'
if (Test-Path -LiteralPath $verFile) {
    try { $pkgVer = ((Get-Content -LiteralPath $verFile -TotalCount 1).Trim()) } catch { }
}

$setupDir = Join-Path $OutDir ("SyncMe-Monitor-Setup-" + $pkgVer)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (Test-Path $setupDir) { Remove-Item $setupDir -Recurse -Force }
New-Item -ItemType Directory -Path $setupDir -Force | Out-Null

$include = @(
    'SyncMe-Monitor.bat',
    'SyncMe-Monitor-Host.ps1',
    'START-HERE.txt',
    'VERSION.txt',
    'Config',
    'ui'
)
foreach ($item in $include) {
    $src = Join-Path $root $item
    if (-not (Test-Path $src)) { Write-Warning "Missing: $item"; continue }
    Copy-Item $src (Join-Path $setupDir $item) -Recurse -Force
}

# Design mockups are for local UI work - never ship to customers.
$mockups = Join-Path $setupDir 'ui\mockups'
if (Test-Path -LiteralPath $mockups) {
    Remove-Item -LiteralPath $mockups -Recurse -Force
}

New-Item -ItemType Directory -Path (Join-Path $setupDir 'Data\sites') -Force | Out-Null
Set-Content -Path (Join-Path $setupDir 'Data\sites\.gitkeep') -Value '' -Encoding ASCII

# Ensure Monitor.bat has no UTF-8 BOM (cmd.exe breaks on BOM before @echo off).
$monBat = Join-Path $setupDir 'SyncMe-Monitor.bat'
if (Test-Path -LiteralPath $monBat) {
    $raw = [IO.File]::ReadAllText($monBat)
    $raw = $raw -replace "^\uFEFF", ''
    [IO.File]::WriteAllBytes($monBat, [Text.Encoding]::ASCII.GetBytes($raw))
}

$zipPath = Join-Path $OutDir ("SyncMe-Monitor-Setup-$pkgVer.zip")
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($setupDir, $zipPath)

Write-Host "Created: $setupDir" -ForegroundColor Green
Write-Host "Created: $zipPath" -ForegroundColor Green
