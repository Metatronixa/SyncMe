#Requires -Version 5.1
<#
.SYNOPSIS
  Creates a client-accessible volume shadow copy and writes .syncme-latest-shadow.txt
  for the Backup PC to consume over SMB (@GMT path).
  Run on the source PC (office), elevated / SYSTEM.
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

$ErrorActionPreference = 'Stop'

if ($Volume -notmatch ':$') { $Volume = "${Volume}:" }
$ShareUncBase = $ShareUncBase.TrimEnd('\')
$ShareRoot = $ShareRoot.TrimEnd('\')

if (-not (Test-Path -LiteralPath $ShareRoot)) {
    throw "ShareRoot not found: $ShareRoot"
}

Write-Host "Creating shadow copy for $Volume ..."
$class = [wmiclass]'Win32_ShadowCopy'
$out = $class.Create($Volume, 'ClientAccessible')
if ($out.ReturnValue -ne 0) {
    throw "Win32_ShadowCopy.Create failed with ReturnValue=$($out.ReturnValue)"
}
$shadowId = $out.ShadowID
$shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
if (-not $shadow) {
    # WMI fallback
    $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
}
if (-not $shadow) {
    throw "Shadow created but could not query ShadowID $shadowId"
}

# InstallDate is typically like 20260726123045.000000+000 - convert to @GMT token (UTC)
$install = $shadow.InstallDate
$dt = $null
if ($install -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})') {
    $dt = [datetime]::SpecifyKind(
        [datetime]::ParseExact("$($Matches[1])$($Matches[2])$($Matches[3])$($Matches[4])$($Matches[5])$($Matches[6])", 'yyyyMMddHHmmss', $null),
        [DateTimeKind]::Utc
    )
} else {
    $dt = [datetime]::UtcNow
}

$gmtToken = '@GMT-{0:yyyy.MM.dd-HH.mm.ss}' -f $dt
$uncShadowBase = "$ShareUncBase\$gmtToken"

# Also record device object for local debugging
$deviceObject = $shadow.DeviceObject

$pointerPath = Join-Path $ShareRoot $PointerFileName
$lines = @(
    $uncShadowBase
    $gmtToken
    "ShadowID=$shadowId"
    "DeviceObject=$deviceObject"
    "CreatedUtc=$($dt.ToString('o'))"
)
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($pointerPath, $lines, $utf8)

Write-Host "Wrote pointer: $pointerPath"
Write-Host "UNC shadow base: $uncShadowBase"
Write-Host "NOTE: Clients need Shadow Copies for Shared Folders enabled to open @GMT paths over SMB."
exit 0
