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
$stamp = Get-Date -Format 'yyyyMMdd'
$stageStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stage = Join-Path $OutDir ("SyncMe-stage-" + $stageStamp)
$zip = Join-Path $OutDir ("SyncMe-" + $stamp + ".zip")

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$include = @(
    'SyncMe.bat', 'SyncMe-Menu.bat', 'SyncMe-Host.ps1',
    'SyncMe-Backup.ps1', 'Backup-OfficeToHome.ps1', 'Config.ps1',
    'Register-BackupTask.ps1', 'SyncMe-Watchdog.ps1', 'Watchdog-MonarchBackup.ps1',
    'Deploy-SyncMe.ps1',
    'START-HERE.txt', 'RecoveryChecklist.txt', 'UserGuide.html', 'README.md',
    'LICENSE.txt', 'VERSION.txt',
    'Modules', 'ui', 'OfficeAgent', 'tools'
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

# Empty Logs/Reports placeholders
New-Item -ItemType Directory -Path (Join-Path $stage 'Logs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'Reports') -Force | Out-Null
Set-Content -Path (Join-Path $stage 'Logs\.gitkeep') -Value '' -Encoding ASCII
Set-Content -Path (Join-Path $stage 'Reports\.gitkeep') -Value '' -Encoding ASCII

if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Created: $zip" -ForegroundColor Green
Write-Host "Give customers the zip and tell them to open START-HERE.txt"
