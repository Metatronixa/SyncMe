#Requires -Version 5.1
<#
.SYNOPSIS
  Builds a minimal customer hand-off: SyncMe-Setup.cmd + SyncMe-Payload.zip only.

.DESCRIPTION
  Payload unpacks into the install folder (default C:\SyncMe), then launches SyncMe.
  Do not ship a loose app tree next to the setup files.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [string]$InstallDir = 'C:\SyncMe'
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
$stage = Join-Path $OutDir ("SyncMe-payload-stage-" + $stageStamp)
$setupDir = Join-Path $OutDir ("SyncMe-Setup-" + $pkgVer)
$payloadZip = Join-Path $setupDir 'SyncMe-Payload.zip'
$setupCmd = Join-Path $setupDir 'SyncMe-Setup.cmd'

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $setupDir) { Remove-Item $setupDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path $setupDir -Force | Out-Null

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

New-Item -ItemType Directory -Path (Join-Path $stage 'Logs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'Reports') -Force | Out-Null
Set-Content -Path (Join-Path $stage 'Logs\.gitkeep') -Value '' -Encoding ASCII
Set-Content -Path (Join-Path $stage 'Reports\.gitkeep') -Value '' -Encoding ASCII

# Customer-facing start note (minimal)
$startHere = @"
SyncMe setup package $pkgVer
====================
1. Double-click SyncMe-Setup.cmd (Run as administrator recommended on Windows Server).
2. Files unpack to $InstallDir (existing Config.ps1 is kept if present).
3. SyncMe opens the browser wizard.
4. Use a dedicated Windows account for unattended backups; enter that password in Schedule.
5. Each backup set needs its own restic repository path (dedicated subfolder - never a drive root).

Passwords stay in Windows Credential Manager. See START-HERE.txt, LICENSE.txt, and THIRD-PARTY-NOTICES.txt after install.
Confirm VERSION.txt shows $pkgVer after install.
"@
Set-Content -Path (Join-Path $setupDir 'START-HERE.txt') -Value $startHere.Trim() -Encoding UTF8

Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $payloadZip) { Remove-Item $payloadZip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $payloadZip)
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

$zipCheck = [System.IO.Compression.ZipFile]::OpenRead($payloadZip)
try {
    $blocked = @($zipCheck.Entries | Where-Object {
        $n = $_.FullName -replace '\\', '/'
        $n -match '(^|/)website(/|$)' -or
        $n -match '(^|/)ui/mockups(/|$)' -or
        $n -match '(?i)\.(exe|msi)$' -or
        $n -match '(?i)(^|/)(restic|rclone|winscp|winfsp)[^/]*$'
    })
    if ($blocked.Count -gt 0) {
        throw ("Payload must not include website/, ui/mockups/, or tool installers (found: {0})" -f ($blocked[0].FullName))
    }
}
finally {
    $zipCheck.Dispose()
}

$cmd = @"
@echo off
setlocal EnableExtensions
title SyncMe Setup
echo Copyright (c) 2026 Bradford Lotriet - brad@web-zilla.co.za
set "INSTALL=$InstallDir"
set "HERE=%~dp0"
set "PAYLOAD=%HERE%SyncMe-Payload.zip"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PAYLOAD%" (
  echo Missing SyncMe-Payload.zip next to this script.
  pause
  exit /b 1
)

echo SyncMe setup
echo Install folder: %INSTALL%
echo.

"%PS%" -NoProfile -ExecutionPolicy Bypass -Command ^
  "`$ErrorActionPreference='Stop';" ^
  "`$install='%INSTALL%';" ^
  "`$zip='%PAYLOAD%';" ^
  "if (-not (Test-Path -LiteralPath `$install)) { New-Item -ItemType Directory -Path `$install -Force | Out-Null };" ^
  "`$cfg = Join-Path `$install 'Config.ps1';" ^
  "`$preserve = `$false; `$tmp = `$null;" ^
  "if (Test-Path -LiteralPath `$cfg) { `$preserve = `$true; `$tmp = Join-Path `$env:TEMP ('SyncMe-Config-' + [guid]::NewGuid().ToString() + '.ps1'); Copy-Item -LiteralPath `$cfg -Destination `$tmp -Force };" ^
  "Add-Type -AssemblyName System.IO.Compression.FileSystem;" ^
  "`$tmpExtract = Join-Path `$env:TEMP ('SyncMe-Extract-' + [guid]::NewGuid().ToString());" ^
  "New-Item -ItemType Directory -Path `$tmpExtract -Force | Out-Null;" ^
  "[IO.Compression.ZipFile]::ExtractToDirectory(`$zip, `$tmpExtract);" ^
  ". (Join-Path `$tmpExtract 'Modules\InstallMerge.ps1');" ^
  "Copy-SyncMeTreeMerge -SourceRoot `$tmpExtract -DestRoot `$install;" ^
  "Clear-SyncMeNestedInstallJunk -InstallRoot `$install;" ^
  "Remove-Item -LiteralPath `$tmpExtract -Recurse -Force -ErrorAction SilentlyContinue;" ^
  "if (`$preserve -and `$tmp -and (Test-Path -LiteralPath `$tmp)) { Copy-Item -LiteralPath `$tmp -Destination `$cfg -Force; Remove-Item -LiteralPath `$tmp -Force -ErrorAction SilentlyContinue };" ^
  "foreach (`$req in @('SyncMe-Host.ps1','Modules\Update.ps1','Modules\MonitorClient.ps1','Modules\InstallMerge.ps1','ui\js\app.js')) { if (-not (Test-Path -LiteralPath (Join-Path `$install `$req))) { throw ('Setup incomplete: missing ' + `$req + ' under ' + `$install) } };" ^
  "Write-Host ('Installed to ' + `$install) -ForegroundColor Green"

if errorlevel 1 (
  echo Setup failed.
  pause
  exit /b 1
)

echo.
echo Starting SyncMe...
start "" "%INSTALL%\SyncMe.bat"
exit /b 0
"@

Set-Content -Path $setupCmd -Value $cmd.Trim() -Encoding ASCII
# cmd.exe breaks if Setup.cmd has a UTF-8 BOM - rewrite as raw ASCII bytes.
[IO.File]::WriteAllBytes($setupCmd, [Text.Encoding]::ASCII.GetBytes(((Get-Content -LiteralPath $setupCmd -Raw) -replace "^\uFEFF", '')))

# Customer download zip + website update feed artifacts
Add-Type -AssemblyName System.IO.Compression.FileSystem
$setupZipName = "SyncMe-Setup-$pkgVer.zip"
$setupZipPath = Join-Path $OutDir $setupZipName
if (Test-Path -LiteralPath $setupZipPath) { Remove-Item -LiteralPath $setupZipPath -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($setupDir, $setupZipPath)
$sha = (Get-FileHash -LiteralPath $setupZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

$updatesDir = Join-Path $OutDir 'updates'
if (-not (Test-Path -LiteralPath $updatesDir)) {
    New-Item -ItemType Directory -Path $updatesDir -Force | Out-Null
}
Copy-Item -LiteralPath $setupZipPath -Destination (Join-Path $updatesDir $setupZipName) -Force

$notes = @"
SyncMe $pkgVer - HTTPS in-app updates, Monitor add-on test heartbeat on Save, install merge fixes, ASCII setup scripts (no BOM). Optional SyncMe Monitor package is separate (same version).
"@
$latest = [ordered]@{
    version = $pkgVer
    file    = $setupZipName
    sha256  = $sha
    notes   = $notes.Trim()
    url     = "https://www.syncme.co.za/updates/$setupZipName"
}
$latestJson = ($latest | ConvertTo-Json -Depth 4) + "`r`n"
$latestPath = Join-Path $updatesDir 'latest.json'
[IO.File]::WriteAllText($latestPath, $latestJson, (New-Object System.Text.UTF8Encoding $false))

$websiteUpdates = Join-Path $root 'website\updates'
if (Test-Path -LiteralPath (Join-Path $root 'website')) {
    if (-not (Test-Path -LiteralPath $websiteUpdates)) {
        New-Item -ItemType Directory -Path $websiteUpdates -Force | Out-Null
    }
    Copy-Item -LiteralPath $setupZipPath -Destination (Join-Path $websiteUpdates $setupZipName) -Force
    [IO.File]::WriteAllText((Join-Path $websiteUpdates 'latest.json'), $latestJson, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Staged website/updates/ for FTP upload." -ForegroundColor Cyan
}

# Build Monitor add-on (same version line) and assemble SyncMe-Release-<ver>
$monitorBuild = Join-Path $root 'Build-SyncMeMonitorSetup.ps1'
$monitorZipName = "SyncMe-Monitor-Setup-$pkgVer.zip"
$monitorZipPath = Join-Path $OutDir $monitorZipName
if (Test-Path -LiteralPath $monitorBuild) {
    & $monitorBuild -OutDir $OutDir
    if (-not (Test-Path -LiteralPath $monitorZipPath)) {
        Write-Warning "Monitor zip missing after build: $monitorZipPath"
    }
}

$releaseDir = Join-Path $OutDir ("SyncMe-Release-" + $pkgVer)
if (Test-Path -LiteralPath $releaseDir) { Remove-Item -LiteralPath $releaseDir -Recurse -Force }
New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
Copy-Item -LiteralPath $setupZipPath -Destination (Join-Path $releaseDir $setupZipName) -Force
if (Test-Path -LiteralPath $monitorZipPath) {
    Copy-Item -LiteralPath $monitorZipPath -Destination (Join-Path $releaseDir $monitorZipName) -Force
}
$releaseStart = @"
SyncMe Release $pkgVer
======================
This folder contains both customer packages:

1) $setupZipName
   Backup PC console (wizard, backups, restore, schedule, HTTPS updates).
   Unzip, then run SyncMe-Setup.cmd (admin recommended on Windows Server).

2) $monitorZipName  (optional add-on)
   Self-hosted fleet dashboard for LAN / Tailscale.
   Unzip to a Monitor PC, edit Config\Monitor.json token, run SyncMe-Monitor.bat.
   On each Backup PC: Operations → Monitor add-on → Save (sends a test ping).

Update feed (website): upload dist\updates\latest.json and $setupZipName
to https://www.syncme.co.za/updates/

SHA256 ($setupZipName): $sha
"@
Set-Content -Path (Join-Path $releaseDir 'START-HERE.txt') -Value $releaseStart.Trim() -Encoding UTF8

Write-Host "Created setup folder: $setupDir" -ForegroundColor Green
Write-Host "  Version: $pkgVer"
Write-Host "  SyncMe-Setup.cmd"
Write-Host "  SyncMe-Payload.zip"
Write-Host "  START-HERE.txt"
Write-Host "Created download zip: $setupZipPath" -ForegroundColor Green
Write-Host "  SHA256: $sha"
Write-Host "Created update feed: $latestPath" -ForegroundColor Green
Write-Host "Created release folder: $releaseDir" -ForegroundColor Green
Write-Host "Hand customers only the setup folder (or the .zip). Upload dist/updates/* to https://www.syncme.co.za/updates/"

