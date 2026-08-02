#Requires -Version 5.1
<#
.SYNOPSIS
  Compatibility stub — use SyncMe-Watchdog.ps1.
#>
[CmdletBinding()]
param(
    [switch]$NoNotify
)
$target = Join-Path $PSScriptRoot 'SyncMe-Watchdog.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Missing SyncMe-Watchdog.ps1 next to this stub ($PSScriptRoot)."
}
if ($NoNotify) {
    & $target -NoNotify
} else {
    & $target
}
exit $LASTEXITCODE
