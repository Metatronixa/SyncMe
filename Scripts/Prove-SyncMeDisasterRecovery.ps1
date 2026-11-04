#Requires -Version 5.1
<#
.SYNOPSIS
  Automated DR structure/health proof for a SyncMe install (no restic password required).
.DESCRIPTION
  Validates install layout, Rescue Kit, health probe modules, restore-guard behaviour,
  and schema marker. Use on a clean lab PC after installing SyncMe-Setup.
  Full data restore still requires the vault password — see docs/DISASTER-RECOVERY.md.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [switch]$SkipRestoreGuard
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

$failures = [System.Collections.Generic.List[string]]::new()
function Ok([string]$Msg) { Write-Host ("[PASS] " + $Msg) -ForegroundColor Green }
function Fail([string]$Msg) { Write-Host ("[FAIL] " + $Msg) -ForegroundColor Red; [void]$failures.Add($Msg) }

Write-Host "SyncMe DR proof against: $InstallRoot" -ForegroundColor Cyan

$required = @(
    'SyncMe-Host.ps1', 'SyncMe-Backup.ps1', 'SyncMe-Restore.ps1', 'VERSION.txt',
    'Modules\Security.ps1', 'Modules\Restore.ps1', 'Modules\Jobs.ps1', 'Modules\Router.ps1',
    'Modules\ProcessRunner.ps1', 'Modules\Health.ps1', 'Modules\Controllers\ApiDispatch.ps1',
    'Modules\UpdatePublicKey.xml', 'RescueKit\SyncMe-Rescue.ps1',
    'START-HERE.txt', 'RecoveryChecklist.txt', 'ui\js\app.js'
)
foreach ($rel in $required) {
    $p = Join-Path $InstallRoot $rel
    if (Test-Path -LiteralPath $p) { Ok $rel } else { Fail "Missing $rel" }
}

$ver = ''
try { $ver = (Get-Content (Join-Path $InstallRoot 'VERSION.txt') -TotalCount 1).Trim() } catch { }
if ($ver) { Ok ("VERSION.txt = " + $ver) } else { Fail 'VERSION.txt unreadable' }

. (Join-Path $InstallRoot 'Modules\Security.ps1')
. (Join-Path $InstallRoot 'Modules\Restore.ps1')
. (Join-Path $InstallRoot 'Modules\Health.ps1')
. (Join-Path $InstallRoot 'Modules\ConfigMigrate.ps1')
. (Join-Path $InstallRoot 'Modules\Sets.ps1')
. (Join-Path $InstallRoot 'Modules\Update.ps1')

try {
    $null = Invoke-SyncMeConfigMigrate -ScriptRoot $InstallRoot -TargetVersion 2
    Ok ('Config schema version = ' + (Get-SyncMeConfigSchemaVersion -ScriptRoot $InstallRoot))
} catch {
    Fail ('Config migrate: ' + $_.Exception.Message)
}

try {
    $probe = Get-SyncMeHealthProbe -ScriptRoot $InstallRoot
    Ok ('Health probe status = ' + $probe.status + ' (' + $probe.checks.Count + ' checks)')
} catch {
    Fail ('Health probe: ' + $_.Exception.Message)
}

if (-not $SkipRestoreGuard) {
    $tmp = Join-Path $env:TEMP ('SyncMe-DR-Guard-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    'sentinel' | Set-Content (Join-Path $tmp 'x.txt')
    try {
        $r = Test-SyncMeRestoreTargetSafe -TargetPath $tmp -ResticRepo 'D:\fake-repo-not-real' -ScriptRoot $InstallRoot
        if (-not $r.Ok) { Ok 'Non-empty restore target rejected' } else { Fail 'Non-empty restore target was accepted' }
        $d = Test-SyncMeRestoreTargetSafe -TargetPath 'C:\' -ResticRepo 'D:\fake-repo-not-real' -ScriptRoot $InstallRoot
        if (-not $d.Ok) { Ok 'Drive-root restore rejected' } else { Fail 'Drive-root restore was accepted' }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$rescue = Join-Path $InstallRoot 'RescueKit\SyncMe-Rescue.ps1'
try {
    & $rescue -Action Diagnostics -InstallRoot $InstallRoot | Out-Null
    Ok 'RescueKit Diagnostics completed'
} catch {
    Fail ('RescueKit Diagnostics: ' + $_.Exception.Message)
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'DR proof PASSED (structure/health/guards). Complete a passworded restic restore per docs/DISASTER-RECOVERY.md.' -ForegroundColor Green
    exit 0
}
Write-Host ("DR proof FAILED ({0}):" -f $failures.Count) -ForegroundColor Red
$failures | ForEach-Object { Write-Host (' - ' + $_) }
exit 1
