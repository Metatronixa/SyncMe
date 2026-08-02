#Requires -Version 5.1
<#
.SYNOPSIS
  Compatibility stub — use SyncMe-Backup.ps1.
#>
[CmdletBinding()]
param(
    [switch]$SkipArchive,
    [switch]$ForceArchive,
    [switch]$SkipPrune,
    [switch]$NoNotify,
    [switch]$WhatIf,
    [switch]$SkipCheck,
    [switch]$RunDataCheck,
    [switch]$CheckOnly,
    [switch]$PruneOnly,
    [string]$SetId = ''
)
$target = Join-Path $PSScriptRoot 'SyncMe-Backup.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Missing SyncMe-Backup.ps1 next to this stub ($PSScriptRoot)."
}
$forward = @{}
foreach ($k in @(
    'SkipArchive','ForceArchive','SkipPrune','NoNotify','WhatIf',
    'SkipCheck','RunDataCheck','CheckOnly','PruneOnly'
)) {
    if ($PSBoundParameters.ContainsKey($k)) { $forward[$k] = $true }
}
if ($PSBoundParameters.ContainsKey('SetId')) { $forward['SetId'] = $SetId }
& $target @forward
exit $LASTEXITCODE
