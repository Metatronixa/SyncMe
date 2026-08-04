#Requires -Version 5.1
<#
.SYNOPSIS
  Builds a customer zip package for SyncMe (HTML console + engine).
#>
[CmdletBinding()]
param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $root 'dist' }

$verFile = Join-Path $root 'VERSION.txt'
$pkgVer = '0.0.0'
if (Test-Path -LiteralPath $verFile) {
    try { $pkgVer = ((Get-Content -LiteralPath $verFile -TotalCount 1).Trim()) } catch { }
}
if ([string]::IsNullOrWhiteSpace($pkgVer)) { $pkgVer = '0.0.0' }

$stageStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stage = Join-Path $OutDir ("SyncMe-stage-" + $stageStamp)
$zip = Join-Path $OutDir ("SyncMe-" + $pkgVer + ".zip")

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# Customer ship list only - never add website/ (local marketing site).
$include = @(
    'SyncMe.bat', 'SyncMe-Menu.bat', 'SyncMe-Host.ps1',
    'SyncMe-Backup.ps1', 'SyncMe-Restore.ps1', 'Config.ps1',
    'Register-BackupTask.ps1', 'SyncMe-Watchdog.ps1',
    'Deploy-SyncMe.ps1',
    'START-HERE.txt', 'RecoveryChecklist.txt', 'UserGuide.html', 'README.md', 'TECHNICAL.md',
    'LICENSE.txt', 'THIRD-PARTY-NOTICES.txt', 'VERSION.txt',
    'Modules', 'ui', 'OfficeAgent'
)

foreach ($item in $include) {
    $src = Join-Path $root $item
    if (-not (Test-Path $src)) {
        Write-Warning "Missing: $item"
        continue
    }
    $dest = Join-Path $stage $item
    if (Test-Path $src -PathType Container) {
        Copy-Item $src $dest -Recurse -Force
    } else {
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $src $dest -Force
    }
}

# Design mockups are for local UI work - never ship to customers.
$mockups = Join-Path $stage 'ui\mockups'
if (Test-Path -LiteralPath $mockups) {
    Remove-Item -LiteralPath $mockups -Recurse -Force
}

# restic/rclone/WinFsp/WinSCP are installed from the console (or PATH) - never bundle binaries.
$toolsDir = Join-Path $stage 'tools'
if (-not (Test-Path -LiteralPath $toolsDir)) {
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
}
Get-ChildItem -LiteralPath $toolsDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match '^\.(exe|msi|msix|zip)$' -or $_.Name -match '(?i)restic|rclone|winscp|winfsp' } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
Set-Content -Path (Join-Path $toolsDir '.gitkeep') -Value '' -Encoding ASCII

# Empty Logs/Reports placeholders
New-Item -ItemType Directory -Path (Join-Path $stage 'Logs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'Reports') -Force | Out-Null
Set-Content -Path (Join-Path $stage 'Logs\.gitkeep') -Value '' -Encoding ASCII
Set-Content -Path (Join-Path $stage 'Reports\.gitkeep') -Value '' -Encoding ASCII

if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

$zipCheck = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $blocked = @($zipCheck.Entries | Where-Object {
        $n = $_.FullName -replace '\\', '/'
        $n -match '(^|/)website(/|$)' -or
        $n -match '(^|/)ui/mockups(/|$)' -or
        $n -match '(?i)\.(exe|msi)$' -or
        $n -match '(?i)(^|/)(restic|rclone|winscp|winfsp)[^/]*$'
    })
    if ($blocked.Count -gt 0) {
        throw ("Package must not include website/, ui/mockups/, or tool installers (found: {0})" -f ($blocked[0].FullName))
    }
}
finally {
    $zipCheck.Dispose()
}

Write-Host "Created: $zip" -ForegroundColor Green
Write-Host "Give customers the zip and tell them to open START-HERE.txt"
