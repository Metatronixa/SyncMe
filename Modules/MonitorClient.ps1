#Requires -Version 5.1
<#
.SYNOPSIS
  Optional heartbeat POST to SyncMe Monitor (non-fatal).
#>

function Send-SyncMeMonitorHeartbeat {
    param(
        [string]$ScriptRoot,
        [string]$SetId,
        [object]$RunInfo,
        [string]$LogPath = ''
    )

    if (-not (Get-Command Get-SyncMeOptions -ErrorAction SilentlyContinue)) {
        $updateMod = Join-Path $ScriptRoot 'Modules\Update.ps1'
        if (Test-Path -LiteralPath $updateMod) { . $updateMod }
    }

    $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
    $url = ([string]$opts.MonitorUrl).Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($url)) { return }

    $token = ([string]$opts.MonitorToken).Trim()
    $siteId = ([string]$opts.MonitorSiteId).Trim()
    if ([string]::IsNullOrWhiteSpace($siteId)) {
        $siteId = $env:COMPUTERNAME
    }

    $ver = ''
    $verFile = Join-Path $ScriptRoot 'VERSION.txt'
    if (Test-Path -LiteralPath $verFile) {
        try { $ver = ((Get-Content -LiteralPath $verFile -TotalCount 1).Trim()) } catch { }
    }

    $endpoint = $url
    if ($endpoint -notmatch '/api/heartbeat/?$') {
        $endpoint = $url + '/api/heartbeat'
    }

    $payload = @{
        siteId      = $siteId
        hostname    = $env:COMPUTERNAME
        version     = $ver
        setId       = $(if ($SetId) { $SetId } else { 'set1' })
        setName     = $(if ($RunInfo -and $RunInfo.DisplayName) { [string]$RunInfo.DisplayName } else { $SetId })
        success     = [bool]($RunInfo -and $RunInfo.Success)
        summary     = $(if ($RunInfo -and $RunInfo.Summary) { [string]$RunInfo.Summary } else { '' })
        snapshotId  = $(if ($RunInfo -and $RunInfo.SnapshotId) { [string]$RunInfo.SnapshotId } else { '' })
        exitCode    = $(if ($RunInfo -and $null -ne $RunInfo.BackupExitCode) { [string]$RunInfo.BackupExitCode } else { '' })
        phase       = $(if ($RunInfo -and $RunInfo.Success) { 'done' } else { 'error' })
        percent     = 100
        endedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        receivedUtc = $null
    }

    $body = $payload | ConvertTo-Json -Depth 6 -Compress
    $headers = @{
        'User-Agent' = 'SyncMe'
    }
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers['Authorization'] = "Bearer $token"
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    try {
        Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -Headers $headers -TimeoutSec 15 | Out-Null
        if ($LogPath) {
            try { Add-Content -LiteralPath $LogPath -Value ("[{0}] Monitor heartbeat sent to {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $endpoint) -Encoding UTF8 } catch { }
        }
        return @{ Ok = $true; Message = "Heartbeat sent to $endpoint"; Endpoint = $endpoint }
    } catch {
        $msg = "Monitor heartbeat failed (non-fatal): $($_.Exception.Message)"
        if ($LogPath) {
            try { Add-Content -LiteralPath $LogPath -Value ("[{0}] WARN {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
        }
        return @{ Ok = $false; Message = $msg; Endpoint = $endpoint }
    }
}

function Send-SyncMeMonitorTestHeartbeat {
    param([string]$ScriptRoot)
    $run = [pscustomobject]@{
        Success        = $true
        Summary        = 'Test heartbeat from SyncMe console'
        DisplayName    = 'Monitor test'
        SnapshotId     = ''
        BackupExitCode = '0'
    }
    return (Send-SyncMeMonitorHeartbeat -ScriptRoot $ScriptRoot -SetId 'test' -RunInfo $run)
}
