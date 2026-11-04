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
$restoreMod = Join-Path $ScriptRoot 'Modules\Restore.ps1'
if (Test-Path -LiteralPath $restoreMod) { . $restoreMod }

$sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
if ($sets.Count -eq 0) {
    # Legacy single config
    $legacy = Get-BackupConfig
    if ($legacy) { $sets = @($legacy) }
}

$maxDaysDefault = 2
$verifyMaxDaysDefault = 14
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
    $backupOk = $false
    try {
        $last = [datetime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $age = ((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalDays
        if ($age -gt $maxDays) {
            [void]$overdueItems.Add("[$setLabel] Last success $([math]::Round($age, 1)) days ago (limit $maxDays). Stamp: $raw")
        } else {
            $backupOk = $true
            $msg = "[$setLabel] OK: last success $raw ($([math]::Round($age, 2)) days ago)."
            [void]$okItems.Add($msg)
            Write-Host $msg
        }
    } catch {
        [void]$overdueItems.Add("[$setLabel] Could not parse last-success stamp: $raw")
    }

    # Restore verification evidence (hash/read) — Watchdog expects periodic proof of restorability.
    $verifyMaxDays = $verifyMaxDaysDefault
    if ($Config.PSObject.Properties.Name -contains 'WatchdogVerifyMaxAgeDays' -and $null -ne $Config.WatchdogVerifyMaxAgeDays) {
        $verifyMaxDays = [double]$Config.WatchdogVerifyMaxAgeDays
    }
    $ev = $null
    if (Get-Command Get-SyncMeRestoreVerifyEvidence -ErrorAction SilentlyContinue) {
        $ev = Get-SyncMeRestoreVerifyEvidence -ScriptRoot $ScriptRoot -SetId $setId
    }
    if (-not $ev) {
        [void]$overdueItems.Add("[$setLabel] No restore-verify evidence (Logs\\sets\\$setId\\restore-verify-evidence.json). Run a weekly data check / restore drill.")
    } else {
        $evUtc = $null
        try {
            if ($ev.verifiedUtc) {
                $evUtc = [datetime]::Parse([string]$ev.verifiedUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
            }
        } catch { }
        if (-not $evUtc) {
            [void]$overdueItems.Add("[$setLabel] Restore-verify evidence missing verifiedUtc.")
        } else {
            $evAge = ((Get-Date).ToUniversalTime() - $evUtc.ToUniversalTime()).TotalDays
            $shaShort = if ($ev.sha256) { ([string]$ev.sha256).Substring(0, [Math]::Min(12, ([string]$ev.sha256).Length)) + '…' } else { '?' }
            if ($evAge -gt $verifyMaxDays) {
                [void]$overdueItems.Add("[$setLabel] Restore verification evidence is $([math]::Round($evAge, 1)) days old (limit $verifyMaxDays). Last sha256=$shaShort")
            } elseif ($backupOk) {
                $vm = "[$setLabel] Restore verify OK: age=$([math]::Round($evAge, 1))d size=$($ev.size) sha256=$shaShort"
                [void]$okItems.Add($vm)
                Write-Host $vm
            }
        }
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
