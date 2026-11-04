#Requires -Version 5.1
<#
.SYNOPSIS
  Optional heartbeat POST to SyncMe Monitor and/or LocalOps fleet (non-fatal).
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

    $outcome = 'failed'
    if (Get-Command Get-SyncMeFleetOutcome -ErrorAction SilentlyContinue) {
        $outcome = Get-SyncMeFleetOutcome -RunInfo $RunInfo
    } elseif ($RunInfo -and $RunInfo.Success) {
        $code = if ($null -ne $RunInfo.BackupExitCode) { [string]$RunInfo.BackupExitCode } else { '' }
        $outcome = if ($code -eq '3') { 'degraded' } else { 'ok' }
    }
    $phase = switch ($outcome) {
        'ok' { 'done' }
        'degraded' { 'degraded' }
        default { 'error' }
    }

    $payload = @{
        siteId      = $siteId
        hostname    = $env:COMPUTERNAME
        version     = $ver
        setId       = $(if ($SetId) { $SetId } else { 'set1' })
        setName     = $(if ($RunInfo -and $RunInfo.DisplayName) { [string]$RunInfo.DisplayName } else { $SetId })
        success     = ($outcome -ne 'failed')
        status      = $outcome
        summary     = $(if ($RunInfo -and $RunInfo.Summary) { [string]$RunInfo.Summary } else { '' })
        snapshotId  = $(if ($RunInfo -and $RunInfo.SnapshotId) { [string]$RunInfo.SnapshotId } else { '' })
        exitCode    = $(if ($RunInfo -and $null -ne $RunInfo.BackupExitCode) { [string]$RunInfo.BackupExitCode } else { '' })
        phase       = $phase
        percent     = 100
        endedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        receivedUtc = $null
    }

    $monitorOk = $null
    $monitorMsg = ''
    $endpoint = ''

    if (-not [string]::IsNullOrWhiteSpace($url)) {
        $endpoint = $url
        if ($endpoint -notmatch '/api/heartbeat/?$') {
            $endpoint = $url + '/api/heartbeat'
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
            $monitorOk = $true
            $monitorMsg = "Heartbeat sent to $endpoint"
            if ($LogPath) {
                try { Add-Content -LiteralPath $LogPath -Value ("[{0}] Monitor heartbeat sent to {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $endpoint) -Encoding UTF8 } catch { }
            }
        } catch {
            $monitorOk = $false
            $monitorMsg = "Monitor heartbeat failed (non-fatal): $($_.Exception.Message)"
            if ($LogPath) {
                try { Add-Content -LiteralPath $LogPath -Value ("[{0}] WARN {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $monitorMsg) -Encoding UTF8 } catch { }
            }
        }
    }

    # Dual-write: also POST to LocalOps loopback fleet ingest when configured
    $locOk = $null
    $locMsg = ''
    $locEndpoint = ''
    if (Get-Command Send-SyncMeLocalOpsFleetHeartbeat -ErrorAction SilentlyContinue) {
        try {
            $loc = Send-SyncMeLocalOpsFleetHeartbeat -ScriptRoot $ScriptRoot -SetId $SetId -RunInfo $RunInfo -LogPath $LogPath
            if ($loc -and -not $loc.Skipped) {
                $locOk = [bool]$loc.Ok
                $locMsg = [string]$loc.Message
                $locEndpoint = [string]$loc.Endpoint
            }
        } catch {
            $locOk = $false
            $locMsg = "LocalOps fleet dual-write failed (non-fatal): $($_.Exception.Message)"
        }
    }

    if ($null -eq $monitorOk -and $null -eq $locOk) {
        return @{ Ok = $true; Skipped = $true; Message = 'No Monitor URL and no LocalOps fleet target'; Endpoint = '' }
    }

    $parts = @()
    if ($null -ne $monitorOk) { $parts += $monitorMsg }
    if ($null -ne $locOk) { $parts += $locMsg }
    $ok = (($null -eq $monitorOk) -or $monitorOk) -and (($null -eq $locOk) -or $locOk)
    return @{
        Ok              = $ok
        Message         = ($parts -join ' | ')
        Endpoint        = $endpoint
        LocalOpsEndpoint = $locEndpoint
        MonitorOk       = $monitorOk
        LocalOpsOk      = $locOk
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
