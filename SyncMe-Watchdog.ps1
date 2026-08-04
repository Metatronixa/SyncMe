#Requires -Version 5.1
<#
.SYNOPSIS
  Emails CRITICAL if any SyncMe backup set last-success stamp is missing or too old.
#>
[CmdletBinding()]
param(
    [switch]$NoNotify
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot
. (Join-Path $ScriptRoot 'Config.ps1')
. (Join-Path $ScriptRoot 'Modules\Notify.ps1')
. (Join-Path $ScriptRoot 'Modules\Sets.ps1')

$sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
if ($sets.Count -eq 0) {
    # Legacy single config
    $legacy = Get-BackupConfig
    if ($legacy) { $sets = @($legacy) }
}

$maxDaysDefault = 2
$overdueItems = New-Object System.Collections.Generic.List[string]
$okItems = New-Object System.Collections.Generic.List[string]
$emailConfig = $null

foreach ($Config in $sets) {
    if (-not $emailConfig -and $Config.EnableEmailNotifications) {
        $emailConfig = $Config
    }

    $setLabel = if ($Config.PSObject.Properties.Name -contains 'DisplayName' -and $Config.DisplayName) {
        [string]$Config.DisplayName
    } elseif ($Config.PSObject.Properties.Name -contains 'Id' -and $Config.Id) {
        [string]$Config.Id
    } else {
        'set1'
    }
    $setId = if ($Config.PSObject.Properties.Name -contains 'Id' -and $Config.Id) { [string]$Config.Id } else { 'set1' }

    $stampRel = "Logs\sets\$setId\last-success-utc.txt"
    if ($Config.PSObject.Properties.Name -contains 'LastSuccessStampFile' -and $Config.LastSuccessStampFile) {
        $stampRel = [string]$Config.LastSuccessStampFile
    } elseif ($setId -eq 'set1') {
        $legacyStamp = Join-Path $ScriptRoot 'Logs\last-success-utc.txt'
        $modernStamp = Join-Path $ScriptRoot $stampRel
        if (-not (Test-Path -LiteralPath $modernStamp) -and (Test-Path -LiteralPath $legacyStamp)) {
            $stampRel = 'Logs\last-success-utc.txt'
        }
    }

    $maxDays = $maxDaysDefault
    if ($Config.PSObject.Properties.Name -contains 'WatchdogMaxAgeDays' -and $null -ne $Config.WatchdogMaxAgeDays) {
        $maxDays = [double]$Config.WatchdogMaxAgeDays
    }

    $stampPath = if ([System.IO.Path]::IsPathRooted($stampRel)) { $stampRel } else { Join-Path $ScriptRoot $stampRel }

    if (-not (Test-Path -LiteralPath $stampPath)) {
        [void]$overdueItems.Add("[$setLabel] No last-success stamp at $stampPath. Backup may never have completed successfully.")
        continue
    }

    $raw = (Get-Content -LiteralPath $stampPath -Raw).Trim()
    try {
        $last = [datetime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $age = ((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalDays
        if ($age -gt $maxDays) {
            [void]$overdueItems.Add("[$setLabel] Last success $([math]::Round($age, 1)) days ago (limit $maxDays). Stamp: $raw")
        } else {
            $msg = "[$setLabel] OK: last success $raw ($([math]::Round($age, 2)) days ago)."
            [void]$okItems.Add($msg)
            Write-Host $msg
        }
    } catch {
        [void]$overdueItems.Add("[$setLabel] Could not parse last-success stamp: $raw")
    }
}

if ($overdueItems.Count -gt 0) {
    $detail = ($overdueItems -join "`r`n")
    if ($okItems.Count -gt 0) {
        $detail = $detail + "`r`n`r`nOther sets OK:`r`n" + ($okItems -join "`r`n")
    }
    Write-Host "WATCHDOG ALERT:`r`n$detail" -ForegroundColor Red
    if (-not $NoNotify -and $emailConfig -and $emailConfig.EnableEmailNotifications) {
        $body = @"
<!DOCTYPE html><html><body style="font-family:Segoe UI,sans-serif;color:#1c2430;">
<p><strong>SyncMe watchdog</strong> - one or more backup sets are overdue on <strong>$([System.Net.WebUtility]::HtmlEncode($env:COMPUTERNAME))</strong>.</p>
<pre style="background:#eef1f5;padding:12px;border-radius:8px;">$([System.Net.WebUtility]::HtmlEncode($detail))</pre>
<p>Check Task Scheduler (SyncMe-Backup*), Disk 1 free space, source shares, and <code>Logs\</code>.</p>
<p><strong>Backup by SyncMe</strong></p>
</body></html>
"@
        [void](Send-BackupEmailFromConfig `
            -Config $emailConfig `
            -Subject "[SyncMe] CRITICAL overdue on $env:COMPUTERNAME" `
            -Body $body `
            -BodyAsHtml)
    }
    exit 1
}

exit 0
