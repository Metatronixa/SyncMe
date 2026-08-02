#Requires -Version 5.1
<#
.SYNOPSIS
  Registers a Scheduled Task for SyncMe backup (SyncMe-Backup.ps1).
  Default LogonType is Password (run whether logged on or not) — required for Windows Server.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'SyncMe-Backup',
    [string]$Time = '01:00',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'SyncMe-Backup.ps1'),
    [ValidateSet('Interactive', 'Password')]
    [string]$LogonType = 'Password',
    [securestring]$UserPassword,
    [string]$TaskPassword = '',
    [string]$TaskPasswordFile = '',
    [string]$UserId = $env:USERNAME,
    [switch]$Unregister,
    [switch]$RegisterWatchdog,
    [string]$WatchdogTime = '09:00',
    [string]$WatchdogTaskName = 'SyncMe-Watchdog',
    [string]$SetId = '',
    [ValidateSet('Once', 'Daily', 'Weekly')]
    [string]$Recurrence = 'Daily',
    [string]$StartDate = '',
    [string]$EndDate = '',
    [string[]]$DaysOfWeek = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot
. (Join-Path $ScriptRoot 'Modules\Common.ps1')

function Get-SyncMeTaskPasswordPlain {
    if ($UserPassword) {
        $cred = New-Object System.Management.Automation.PSCredential ('x', $UserPassword)
        return $cred.GetNetworkCredential().Password
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskPasswordFile) -and (Test-Path -LiteralPath $TaskPasswordFile)) {
        try {
            return (Get-Content -LiteralPath $TaskPasswordFile -Raw -ErrorAction Stop).TrimEnd("`r", "`n")
        } finally {
            Remove-Item -LiteralPath $TaskPasswordFile -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskPassword)) {
        return $TaskPassword
    }
    return $null
}

if (-not (Test-MonarchIsAdmin)) {
    if ($LogonType -eq 'Password' -and -not $Unregister) {
        $plainForElevate = Get-SyncMeTaskPasswordPlain
        if ([string]::IsNullOrEmpty($plainForElevate)) {
            Write-Host "For 'run whether logged on or not', provide the Windows account password and run elevated." -ForegroundColor Yellow
            exit 1
        }
        $pwdFile = Join-Path $env:TEMP ('syncme-task-pwd-' + [guid]::NewGuid().ToString('n') + '.txt')
        Set-Content -LiteralPath $pwdFile -Value $plainForElevate -Encoding UTF8 -NoNewline
        try {
            $acl = Get-Acl -LiteralPath $pwdFile
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl',
                'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $pwdFile -AclObject $acl
        } catch { }

        $passArgs = [System.Collections.Generic.List[string]]::new()
        $passArgs.Add('-TaskName'); $passArgs.Add($TaskName)
        $passArgs.Add('-Time'); $passArgs.Add($Time)
        $passArgs.Add('-ScriptPath'); $passArgs.Add($ScriptPath)
        $passArgs.Add('-LogonType'); $passArgs.Add($LogonType)
        $passArgs.Add('-TaskPasswordFile'); $passArgs.Add($pwdFile)
        $passArgs.Add('-UserId'); $passArgs.Add($UserId)
        $passArgs.Add('-WatchdogTaskName'); $passArgs.Add($WatchdogTaskName)
        $passArgs.Add('-Recurrence'); $passArgs.Add($Recurrence)
        if ($StartDate) { $passArgs.Add('-StartDate'); $passArgs.Add($StartDate) }
        if ($EndDate) { $passArgs.Add('-EndDate'); $passArgs.Add($EndDate) }
        if ($DaysOfWeek -and $DaysOfWeek.Count -gt 0) {
            $passArgs.Add('-DaysOfWeek'); $passArgs.Add(($DaysOfWeek -join ','))
        }
        if ($RegisterWatchdog) {
            $passArgs.Add('-RegisterWatchdog')
            $passArgs.Add('-WatchdogTime'); $passArgs.Add($WatchdogTime)
        }
        if ($SetId) { $passArgs.Add('-SetId'); $passArgs.Add($SetId) }
        $code = Request-MonarchElevation -ScriptPath $PSCommandPath -ArgumentList $passArgs.ToArray()
        if (Test-Path -LiteralPath $pwdFile) {
            Remove-Item -LiteralPath $pwdFile -Force -ErrorAction SilentlyContinue
        }
        exit $(if ($null -eq $code) { 0 } else { $code })
    }

    $passArgs = [System.Collections.Generic.List[string]]::new()
    $passArgs.Add('-TaskName'); $passArgs.Add($TaskName)
    $passArgs.Add('-Time'); $passArgs.Add($Time)
    $passArgs.Add('-ScriptPath'); $passArgs.Add($ScriptPath)
    $passArgs.Add('-LogonType'); $passArgs.Add($LogonType)
    $passArgs.Add('-UserId'); $passArgs.Add($UserId)
    $passArgs.Add('-WatchdogTaskName'); $passArgs.Add($WatchdogTaskName)
    $passArgs.Add('-Recurrence'); $passArgs.Add($Recurrence)
    if ($StartDate) { $passArgs.Add('-StartDate'); $passArgs.Add($StartDate) }
    if ($EndDate) { $passArgs.Add('-EndDate'); $passArgs.Add($EndDate) }
    if ($DaysOfWeek -and $DaysOfWeek.Count -gt 0) {
        $passArgs.Add('-DaysOfWeek'); $passArgs.Add(($DaysOfWeek -join ','))
    }
    if ($Unregister) { $passArgs.Add('-Unregister') }
    if ($RegisterWatchdog) {
        $passArgs.Add('-RegisterWatchdog')
        $passArgs.Add('-WatchdogTime'); $passArgs.Add($WatchdogTime)
    }
    if ($SetId) { $passArgs.Add('-SetId'); $passArgs.Add($SetId) }
    $code = Request-MonarchElevation -ScriptPath $PSCommandPath -ArgumentList $passArgs.ToArray()
    exit $(if ($null -eq $code) { 0 } else { $code })
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Script not found: $ScriptPath"
}

if ($Unregister) {
    foreach ($n in @($TaskName, $WatchdogTaskName, 'Backup-OfficeToHome', 'Monarch-BackupWatchdog')) {
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false
            Write-Host "Removed scheduled task '$n'."
        }
    }
    return
}

# Elevation may pass DaysOfWeek as a single comma-separated string
if ($DaysOfWeek.Count -eq 1 -and $DaysOfWeek[0] -match ',') {
    $DaysOfWeek = @($DaysOfWeek[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-SyncMeScheduleDateTime {
    param([string]$DateYmd, [string]$TimeHHmm)
    $d = if ($DateYmd -and $DateYmd -match '^\d{4}-\d{2}-\d{2}$') {
        [datetime]::ParseExact($DateYmd, 'yyyy-MM-dd', $null)
    } else {
        (Get-Date).Date
    }
    if ($TimeHHmm -notmatch '^(\d{1,2}):(\d{2})$') {
        throw "Invalid time: $TimeHHmm (use HH:mm)."
    }
    $h = [int]$Matches[1]
    $m = [int]$Matches[2]
    return $d.Date.AddHours($h).AddMinutes($m)
}

function New-SyncMeBackupTrigger {
    param(
        [string]$Recurrence,
        [string]$Time,
        [string]$StartDate,
        [string]$EndDate,
        [string[]]$DaysOfWeek
    )
    $at = Get-SyncMeScheduleDateTime -DateYmd $StartDate -TimeHHmm $Time
    $trigger = $null
    switch ($Recurrence) {
        'Once' {
            $trigger = New-ScheduledTaskTrigger -Once -At $at
        }
        'Weekly' {
            $valid = @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')
            $days = @($DaysOfWeek | Where-Object { $valid -contains $_ } | Select-Object -Unique)
            if ($days.Count -eq 0) { $days = @('Monday') }
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $at
        }
        default {
            $trigger = New-ScheduledTaskTrigger -Daily -At $at
        }
    }
    if ($StartDate -and $StartDate -match '^\d{4}-\d{2}-\d{2}$' -and $Recurrence -ne 'Once') {
        try { $trigger.StartBoundary = $at.ToString('s') } catch { }
    }
    if ($EndDate -and $EndDate -match '^\d{4}-\d{2}-\d{2}$' -and $Recurrence -ne 'Once') {
        $endAt = Get-SyncMeScheduleDateTime -DateYmd $EndDate -TimeHHmm '23:59'
        try { $trigger.EndBoundary = $endAt.ToString('s') } catch { }
    }
    return $trigger
}

$scriptFull = (Resolve-Path -LiteralPath $ScriptPath).Path
$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFull`""
if (-not [string]::IsNullOrWhiteSpace($SetId)) {
    $arg += " -SetId `"$SetId`""
}

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-SyncMeBackupTrigger -Recurrence $Recurrence -Time $Time -StartDate $StartDate -EndDate $EndDate -DaysOfWeek $DaysOfWeek
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 24) `
    -MultipleInstances IgnoreNew

$recLabel = $Recurrence.ToLowerInvariant()
$plain = $null
if ($LogonType -eq 'Password') {
    $plain = Get-SyncMeTaskPasswordPlain
    if ([string]::IsNullOrEmpty($plain)) {
        $UserPassword = Read-Host "Windows password for $UserId (stored in Task Scheduler; required for Server / unattended)" -AsSecureString
        $cred = New-Object System.Management.Automation.PSCredential ($UserId, $UserPassword)
        $plain = $cred.GetNetworkCredential().Password
    }
    if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task (Password logon)')) {
        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -User $UserId `
            -Password $plain `
            -Force | Out-Null
        Write-Host "Registered $recLabel task '$TaskName' at $Time (run whether logged on or not as $UserId)."
        Write-Host "Credential Manager secrets for SyncMe must also belong to this same Windows account." -ForegroundColor Yellow
    }
} else {
    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
    if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task (Interactive)')) {
        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Force | Out-Null
        Write-Host "Registered $recLabel task '$TaskName' at $Time (interactive / while logged on)."
        Write-Host "WARNING: Interactive tasks do not run after logout/reboot without a session. Prefer Password logon on Windows Server." -ForegroundColor Yellow
    }
}

Write-Host "Script: $scriptFull"

if ($RegisterWatchdog) {
    $watch = Join-Path $ScriptRoot 'SyncMe-Watchdog.ps1'
    if (-not (Test-Path -LiteralPath $watch)) {
        $watch = Join-Path $ScriptRoot 'Watchdog-MonarchBackup.ps1'
    }
    $warg = "-NoProfile -ExecutionPolicy Bypass -File `"$watch`""
    $waction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $warg
    $wtrigger = New-ScheduledTaskTrigger -Daily -At $WatchdogTime
    if ($LogonType -eq 'Password') {
        if ([string]::IsNullOrEmpty($plain)) {
            throw 'Windows password required to register SyncMe-Watchdog with Password logon.'
        }
        Register-ScheduledTask `
            -TaskName $WatchdogTaskName `
            -Action $waction `
            -Trigger $wtrigger `
            -Settings $settings `
            -User $UserId `
            -Password $plain `
            -Force | Out-Null
    } else {
        $wprincipal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask `
            -TaskName $WatchdogTaskName `
            -Action $waction `
            -Trigger $wtrigger `
            -Settings $settings `
            -Principal $wprincipal `
            -Force | Out-Null
    }
    Write-Host "Registered multi-set watchdog task '$WatchdogTaskName' at $WatchdogTime."
}
