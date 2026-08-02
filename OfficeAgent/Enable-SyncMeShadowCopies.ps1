#Requires -Version 5.1
<#
.SYNOPSIS
  Location A helper: enable VSS shadow storage, schedule nightly snapshot+pointer update.
  Run elevated on the OFFICE PC.
#>
[CmdletBinding()]
param(
    [string]$Volume = '',
    [string]$ShareRoot = '',
    [string]$ShareUncBase = '',
    [string]$ScheduleTime = '00:30',
    [string]$MaxShadowSize = '20%'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path (Split-Path $here -Parent) 'Modules\Common.ps1')

if (-not (Test-MonarchIsAdmin)) {
    $args = @()
    if ($Volume) { $args += @('-Volume', $Volume) }
    if ($ShareRoot) { $args += @('-ShareRoot', $ShareRoot) }
    if ($ShareUncBase) { $args += @('-ShareUncBase', $ShareUncBase) }
    if ($ScheduleTime) { $args += @('-ScheduleTime', $ScheduleTime) }
    if ($MaxShadowSize) { $args += @('-MaxShadowSize', $MaxShadowSize) }
    $code = Request-MonarchElevation -ScriptPath $PSCommandPath -ArgumentList $args
    exit $(if ($null -eq $code) { 0 } else { $code })
}

function Read-Default([string]$Prompt, [string]$Default = '') {
    if ($Default) {
        $r = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
        return $r.Trim()
    }
    do { $r = Read-Host $Prompt } while ([string]::IsNullOrWhiteSpace($r))
    return $r.Trim()
}

Write-Host "SyncMe — Office Shadow Copies setup" -ForegroundColor Cyan
Write-Host "By Bradford Lotriet"
Write-Host "This runs on the source PC (office) and must be elevated."
Write-Host ""

if (-not $Volume) { $Volume = Read-Default 'Data volume drive letter (e.g. D:)' 'D:' }
if ($Volume -notmatch ':$') { $Volume = "${Volume}:" }
if (-not $ShareRoot) { $ShareRoot = Read-Default 'Local path of the shared folder' 'D:\Data' }
if (-not $ShareUncBase) { $ShareUncBase = Read-Default 'UNC base as seen from Backup PC (e.g. \\office-pc\Data)' }

if (-not (Test-Path -LiteralPath $ShareRoot)) {
    throw "Share root not found: $ShareRoot"
}

Write-Host "Configuring shadow storage on $Volume (max $MaxShadowSize)..."
$addOut = cmd /c "vssadmin Add ShadowStorage /For=$Volume /On=$Volume /MaxSize=$MaxShadowSize" 2>&1
Write-Host $addOut
# Resize if already exists
cmd /c "vssadmin Resize ShadowStorage /For=$Volume /On=$Volume /MaxSize=$MaxShadowSize" 2>&1 | Out-Null

$updater = Join-Path $here 'Update-SyncMeShadowPointer.ps1'
if (-not (Test-Path -LiteralPath $updater)) {
    throw "Missing Update-SyncMeShadowPointer.ps1 in $here"
}

$taskName = 'SyncMe-OfficeShadowPointer'
$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -Volume `"$Volume`" -ShareRoot `"$ShareRoot`" -ShareUncBase `"$ShareUncBase`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -Daily -At $ScheduleTime
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Registered daily task '$taskName' at $ScheduleTime (SYSTEM)." -ForegroundColor Green

Write-Host "Creating an initial shadow + pointer now..."
& $updater -Volume $Volume -ShareRoot $ShareRoot -ShareUncBase $ShareUncBase
if ($LASTEXITCODE -ne 0) {
    Write-Host "Initial pointer update failed (exit $LASTEXITCODE). Fix and re-run updater." -ForegroundColor Yellow
} else {
    Write-Host "Pointer file written under share root." -ForegroundColor Green
}

Write-Host ""
Write-Host "IMPORTANT: Also enable Shadow Copies for Shared Folders in the GUI:"
Write-Host "  This PC -> right-click $Volume -> Configure Shadow Copies -> Enable"
Write-Host "  so home can reach \\server\share\@GMT-... over SMB."
Write-Host ""
Write-Host "Schedule the home backup AFTER $ScheduleTime so the pointer is fresh."
Write-Host "Done."
