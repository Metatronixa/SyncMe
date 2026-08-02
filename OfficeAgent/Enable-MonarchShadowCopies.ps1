#Requires -Version 5.1
<#
.SYNOPSIS
  Compatibility stub — use Enable-SyncMeShadowCopies.ps1.
#>
[CmdletBinding()]
param(
    [string]$Volume = '',
    [string]$ShareRoot = '',
    [string]$ShareUncBase = '',
    [string]$ScheduleTime = '00:30',
    [string]$MaxShadowSize = '20%'
)
$target = Join-Path $PSScriptRoot 'Enable-SyncMeShadowCopies.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Missing Enable-SyncMeShadowCopies.ps1 in $PSScriptRoot"
}
& $target @PSBoundParameters
exit $LASTEXITCODE
