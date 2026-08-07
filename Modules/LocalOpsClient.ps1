#Requires -Version 5.1
<#
.SYNOPSIS
  Optional registration / status POST to LocalOps Console SyncMe tab (non-fatal).
#>

function Test-SyncMeLocalOpsLoopbackUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $true }
    try {
        $u = [Uri]$Url
        if ($u.Scheme -notin @('http', 'https')) { return $false }
        $hostName = $u.DnsSafeHost
        if ([string]::IsNullOrWhiteSpace($hostName)) { return $false }
        if ($hostName -match '^(?i)(localhost|127\.0\.0\.1|::1)$') { return $true }
        $ip = $null
        if ([System.Net.IPAddress]::TryParse($hostName, [ref]$ip)) {
            return [System.Net.IPAddress]::IsLoopback($ip)
        }
        return $false
    } catch {
        return $false
    }
}

function Get-SyncMeLocalOpsBaseUrl {
    param([string]$ScriptRoot)
    $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
    $enabled = $true
    if ($null -ne $opts.PSObject.Properties['LocalOpsEnabled']) {
        $raw = $opts.LocalOpsEnabled
        if ($raw -is [bool]) { $enabled = [bool]$raw }
        else {
            $s = ([string]$raw).Trim().ToLowerInvariant()
            if ($s -in @('0', 'false', 'no', 'off')) { $enabled = $false }
        }
    }
    if (-not $enabled) { return $null }

    $url = ([string]$opts.LocalOpsUrl).Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($url)) {
        $url = 'http://127.0.0.1:8787'
    }
    if (-not (Test-SyncMeLocalOpsLoopbackUrl -Url $url)) {
        return $null
    }
    return $url
}

function Test-SyncMeLocalOpsReachable {
    param([string]$BaseUrl)
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return $false }
    $health = $BaseUrl.TrimEnd('/') + '/api/v1/health'
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    try {
        $resp = Invoke-RestMethod -Uri $health -Method Get -TimeoutSec 3
        if ($null -eq $resp) { return $false }
        if ($resp.PSObject.Properties['Success']) { return [bool]$resp.Success }
        return $true
    } catch {
        return $false
    }
}

function Send-SyncMeLocalOpsRegister {
    param(
        [string]$ScriptRoot,
        [string]$SetId = '',
        [object]$RunInfo = $null,
        [string]$LogPath = '',
        [switch]$Force
    )

    if (-not (Get-Command Get-SyncMeOptions -ErrorAction SilentlyContinue)) {
        $updateMod = Join-Path $ScriptRoot 'Modules\Update.ps1'
        if (Test-Path -LiteralPath $updateMod) { . $updateMod }
    }

    $base = Get-SyncMeLocalOpsBaseUrl -ScriptRoot $ScriptRoot
    if ([string]::IsNullOrWhiteSpace($base)) {
        return @{ Ok = $false; Skipped = $true; Message = 'LocalOps registration disabled'; Endpoint = '' }
    }

    if (-not $Force -and -not (Test-SyncMeLocalOpsReachable -BaseUrl $base)) {
        return @{ Ok = $false; Skipped = $true; Message = "LocalOps not reachable at $base"; Endpoint = $base }
    }

    $ver = ''
    $verFile = Join-Path $ScriptRoot 'VERSION.txt'
    if (Test-Path -LiteralPath $verFile) {
        try { $ver = ((Get-Content -LiteralPath $verFile -TotalCount 1).Trim()) } catch { }
    }

    $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
    $siteId = ([string]$opts.MonitorSiteId).Trim()
    if ([string]::IsNullOrWhiteSpace($siteId)) { $siteId = $env:COMPUTERNAME }

    $listening = $false
    try {
        if (Get-NetTCPConnection -LocalPort 17845 -State Listen -ErrorAction SilentlyContinue) { $listening = $true }
    } catch { }

    $payload = @{
        installPath = $ScriptRoot
        version     = $ver
        hostname    = $env:COMPUTERNAME
        siteId      = $siteId
        consoleUrl  = 'http://127.0.0.1:17845/'
        listening   = $listening
    }

    if ($RunInfo) {
        $payload['success'] = [bool]$RunInfo.Success
        $payload['summary'] = $(if ($RunInfo.Summary) { [string]$RunInfo.Summary } else { '' })
        $payload['setId'] = $(if ($SetId) { $SetId } else { 'set1' })
        $payload['setName'] = $(if ($RunInfo.DisplayName) { [string]$RunInfo.DisplayName } elseif ($SetId) { $SetId } else { '' })
        $payload['endedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    }

    $endpoint = $base.TrimEnd('/') + '/api/v1/syncme/register'
    $body = $payload | ConvertTo-Json -Depth 6 -Compress
    $headers = @{ 'User-Agent' = 'SyncMe' }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    try {
        Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -Headers $headers -TimeoutSec 15 | Out-Null
        if ($LogPath) {
            try { Add-Content -LiteralPath $LogPath -Value ("[{0}] LocalOps register sent to {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $endpoint) -Encoding UTF8 } catch { }
        }
        return @{ Ok = $true; Skipped = $false; Message = "Registered with LocalOps at $endpoint"; Endpoint = $endpoint }
    } catch {
        $msg = "LocalOps register failed (non-fatal): $($_.Exception.Message)"
        if ($LogPath) {
            try { Add-Content -LiteralPath $LogPath -Value ("[{0}] WARN {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
        }
        return @{ Ok = $false; Skipped = $false; Message = $msg; Endpoint = $endpoint }
    }
}

function Send-SyncMeLocalOpsTestRegister {
    param([string]$ScriptRoot)
    $run = [pscustomobject]@{
        Success     = $true
        Summary     = 'Test registration from SyncMe console'
        DisplayName = 'LocalOps test'
    }
    return (Send-SyncMeLocalOpsRegister -ScriptRoot $ScriptRoot -SetId 'test' -RunInfo $run -Force)
}
