#Requires -Version 5.1
<#
.SYNOPSIS
  Compatibility stub — use Update-SyncMeShadowPointer.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Volume,
    [Parameter(Mandatory)]
    [string]$ShareRoot,
    [Parameter(Mandatory)]
    [string]$ShareUncBase,
    [string]$PointerFileName = '.syncme-latest-shadow.txt'
)
$target = Join-Path $PSScriptRoot 'Update-SyncMeShadowPointer.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Missing Update-SyncMeShadowPointer.ps1 in $PSScriptRoot"
}
& $target @PSBoundParameters
exit $LASTEXITCODE
