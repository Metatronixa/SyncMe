#Requires -Version 5.1
<#
.SYNOPSIS
  Copies THIS SyncMe project folder onto a Backup PC install path (default C:\SyncMe).

.DESCRIPTION
  Preserves target Config.ps1 and Logs\sets\*.json. Does not wipe Logs or Reports.

.EXAMPLE
  .\Deploy-SyncMe.ps1
  .\Deploy-SyncMe.ps1 -Target C:\SyncMe
#>
[CmdletBinding()]
param(
    [string]$Target = 'C:\SyncMe',

    [switch]$SkipStopHost
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }

$marker = Join-Path $root 'SyncMe-Host.ps1'
$verSrc = Join-Path $root 'VERSION.txt'
if (-not (Test-Path -LiteralPath $marker)) {
    throw "Not a SyncMe project root (missing SyncMe-Host.ps1): $root"
}
if (-not (Test-Path -LiteralPath $verSrc)) {
    throw "Missing VERSION.txt in $root — deploy from the SyncMe project that contains it."
}

$include = @(
    'SyncMe.bat', 'SyncMe-Menu.bat', 'SyncMe-Host.ps1',
    'SyncMe-Backup.ps1', 'Config.ps1',
    'Register-BackupTask.ps1', 'SyncMe-Watchdog.ps1',
    'Deploy-SyncMe.ps1', 'Build-SyncMePackage.ps1', 'Build-SyncMeSetup.ps1',
    'START-HERE.txt', 'RecoveryChecklist.txt', 'UserGuide.html', 'README.md',
    'LICENSE.txt', 'THIRD-PARTY-NOTICES.txt',
    'VERSION.txt',
    'Modules', 'ui', 'OfficeAgent', 'tools'
)

Write-Host "Source: $root" -ForegroundColor Cyan
Write-Host "Target: $Target" -ForegroundColor Cyan

if (-not $SkipStopHost) {
    $stopped = 0
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'powershell|pwsh' -and
            $_.CommandLine -and
            $_.CommandLine -match 'SyncMe-Host\.ps1'
        } |
        ForEach-Object {
            Write-Host "Stopping SyncMe host PID $($_.ProcessId)…" -ForegroundColor Yellow
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    if ($stopped -gt 0) { Start-Sleep -Seconds 1 }
}

if (-not (Test-Path -LiteralPath $Target)) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
}

$preserveConfig = $false
$configTarget = Join-Path $Target 'Config.ps1'
if (Test-Path -LiteralPath $configTarget) {
    $preserveConfig = $true
    Write-Host 'Keeping existing Config.ps1' -ForegroundColor Green
}

$setsPreserve = @()
$setsDir = Join-Path $Target 'Logs\sets'
if (Test-Path -LiteralPath $setsDir) {
    Get-ChildItem -LiteralPath $setsDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { $setsPreserve += $_ }
    if ($setsPreserve.Count -gt 0) {
        Write-Host ("Keeping {0} set config JSON file(s) under Logs\\sets" -f $setsPreserve.Count) -ForegroundColor Green
    }
}

foreach ($item in $include) {
    if ($item -eq 'Config.ps1' -and $preserveConfig) { continue }

    $src = Join-Path $root $item
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warning "Missing in source: $item"
        continue
    }
    $dest = Join-Path $Target $item
    if (Test-Path -LiteralPath $src -PathType Container) {
        if ($item -eq 'tools') {
            # Ensure portable restic/rclone land on the Backup PC
            if (-not (Test-Path -LiteralPath $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dest $_.Name) -Force
            }
        } else {
            if (-not (Test-Path -LiteralPath $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
        }
    } else {
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dest -Force
    }
}

foreach ($d in @('Logs', 'Reports')) {
    $p = Join-Path $Target $d
    if (-not (Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
}

$installedVer = (Get-Content -LiteralPath (Join-Path $Target 'VERSION.txt') -TotalCount 1).Trim()
$reportCheck = Select-String -Path (Join-Path $Target 'Modules\Report.ps1') -Pattern 'Backup by SyncMe' -Quiet
if (-not $reportCheck) {
    Write-Warning 'Modules\Report.ps1 does not contain "Backup by SyncMe" — wrong source?'
}

Write-Host ''
Write-Host "Deployed SyncMe build $installedVer → $Target" -ForegroundColor Green
Write-Host 'Start SyncMe again (SyncMe.bat). New reports must show: Backup by SyncMe · build '"$installedVer"
