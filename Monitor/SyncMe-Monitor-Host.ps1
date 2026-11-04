#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe Monitor - self-hosted fleet status host (HTML + HttpListener).
#>
[CmdletBinding()]
param(
    [int]$Port = 17846,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot
$UiRoot = Join-Path $ScriptRoot 'ui'
$DataRoot = Join-Path $ScriptRoot 'Data\sites'
$utf8 = New-Object System.Text.UTF8Encoding $false

if (-not (Test-Path -LiteralPath $DataRoot)) {
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
}

function New-MonitorToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $b64 = [Convert]::ToBase64String($bytes).TrimEnd('=')
    return (('sm_' + $b64) -replace '\+', '-') -replace '/', '_'
}

function Test-MonitorTokenWeak {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $true }
    $t = $Token.Trim()
    if ($t -eq 'change-me') { return $true }
    if ($t.Length -lt 24) { return $true }
    return $false
}

function Save-MonitorConfigFile {
    param($Config)
    $path = Join-Path $ScriptRoot 'Config\Monitor.json'
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ordered = [ordered]@{
        Token                  = [string]$Config.Token
        Port                   = [int]$Config.Port
        Bind                   = [string]$Config.Bind
        WebhookUrl             = [string]$Config.WebhookUrl
        WebhookOnFail          = [bool]$Config.WebhookOnFail
        WebhookOnStale         = [bool]$Config.WebhookOnStale
        StaleHours             = [int]$Config.StaleHours
        WebhookCooldownMinutes = [int]$Config.WebhookCooldownMinutes
    }
    [IO.File]::WriteAllText($path, (($ordered | ConvertTo-Json) + "`r`n"), $utf8)
}

function Get-MonitorConfig {
    $path = Join-Path $ScriptRoot 'Config\Monitor.json'
    $defaults = [ordered]@{
        Token            = ''
        Port             = $Port
        Bind             = 'loopback'  # loopback | lan
        WebhookUrl       = ''
        WebhookOnFail    = $true
        WebhookOnStale   = $true
        StaleHours       = 36
        WebhookCooldownMinutes = 60
    }
    $created = $false
    if (Test-Path -LiteralPath $path) {
        try {
            $obj = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json
            if ($null -ne $obj.PSObject.Properties['Token']) { $defaults.Token = [string]$obj.Token }
            if ($obj.Port) { $defaults.Port = [int]$obj.Port }
            if ($null -ne $obj.PSObject.Properties['Bind'] -and $obj.Bind) { $defaults.Bind = [string]$obj.Bind }
            if ($null -ne $obj.PSObject.Properties['WebhookUrl']) { $defaults.WebhookUrl = [string]$obj.WebhookUrl }
            if ($null -ne $obj.PSObject.Properties['WebhookOnFail']) { $defaults.WebhookOnFail = [bool]$obj.WebhookOnFail }
            if ($null -ne $obj.PSObject.Properties['WebhookOnStale']) { $defaults.WebhookOnStale = [bool]$obj.WebhookOnStale }
            if ($null -ne $obj.PSObject.Properties['StaleHours'] -and [int]$obj.StaleHours -gt 0) { $defaults.StaleHours = [int]$obj.StaleHours }
            if ($null -ne $obj.PSObject.Properties['WebhookCooldownMinutes'] -and [int]$obj.WebhookCooldownMinutes -gt 0) {
                $defaults.WebhookCooldownMinutes = [int]$obj.WebhookCooldownMinutes
            }
        } catch { }
    } else {
        $created = $true
    }

    if (Test-MonitorTokenWeak -Token ([string]$defaults.Token)) {
        $defaults.Token = New-MonitorToken
        $created = $true
        Write-Host "Monitor token was missing/placeholder; generated a new token and saved Config\Monitor.json" -ForegroundColor Yellow
    }
    if ([string]$defaults.Bind -notin @('loopback', 'lan')) { $defaults.Bind = 'loopback' }
    if ($created) { Save-MonitorConfigFile -Config ([pscustomobject]$defaults) }
    return [pscustomobject]$defaults
}

function Get-MonitorWebhookStatePath {
    return (Join-Path $ScriptRoot 'Data\webhook-state.json')
}

function Get-MonitorWebhookState {
    $path = Get-MonitorWebhookStatePath
    if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{} }
    try {
        $obj = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json
        $map = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $map[[string]$p.Name] = [string]$p.Value }
        return $map
    } catch {
        return [ordered]@{}
    }
}

function Save-MonitorWebhookState {
    param($Map)
    $dir = Join-Path $ScriptRoot 'Data'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $payload = [ordered]@{}
    if ($Map -is [hashtable] -or $Map -is [System.Collections.IDictionary]) {
        foreach ($k in $Map.Keys) { $payload[[string]$k] = [string]$Map[$k] }
    } else {
        foreach ($p in $Map.PSObject.Properties) { $payload[[string]$p.Name] = [string]$p.Value }
    }
    [IO.File]::WriteAllText((Get-MonitorWebhookStatePath), (($payload | ConvertTo-Json -Compress) + "`r`n"), $utf8)
}

function Send-MonitorWebhook {
    param(
        [string]$Url,
        [string]$Event,
        $Site,
        [string]$Detail = ''
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    $siteId = if ($Site.siteId) { [string]$Site.siteId } else { 'unknown' }
    $text = "SyncMe Monitor: $Event — $siteId"
    if ($Detail) { $text += " — $Detail" }
    $payload = @{
        text      = $text
        event     = $Event
        siteId    = $siteId
        hostname  = $(if ($Site.hostname) { [string]$Site.hostname } else { '' })
        summary   = $(if ($Site.summary) { [string]$Site.summary } else { '' })
        success   = $(if ($null -ne $Site.success) { [bool]$Site.success } else { $false })
        endedUtc  = $(if ($Site.endedUtc) { [string]$Site.endedUtc } else { '' })
        exitCode  = $(if ($Site.exitCode) { [string]$Site.exitCode } else { '' })
        detail    = $Detail
    } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri $Url -Method Post -Body $payload -ContentType 'application/json; charset=utf-8' -TimeoutSec 8 | Out-Null
    } catch {
        Write-Host ("Webhook failed: " + $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Test-MonitorWebhookCooldown {
    param([string]$Key, [int]$CooldownMinutes, $StateMap)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    if (-not $StateMap.Contains($Key)) { return $true }
    try {
        $last = [datetime]::Parse([string]$StateMap[$Key], $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return ((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalMinutes -ge $CooldownMinutes
    } catch {
        return $true
    }
}

function Invoke-MonitorStaleWebhooks {
    param($Config)
    if ([string]::IsNullOrWhiteSpace([string]$Config.WebhookUrl)) { return }
    if (-not [bool]$Config.WebhookOnStale) { return }
    $staleHours = [int]$Config.StaleHours
    if ($staleHours -lt 1) { $staleHours = 36 }
    $cooldown = [int]$Config.WebhookCooldownMinutes
    if ($cooldown -lt 1) { $cooldown = 60 }
    $state = Get-MonitorWebhookState
    $now = (Get-Date).ToUniversalTime()
    foreach ($site in @(Get-MonitorSites)) {
        $ended = $null
        try {
            if ($site.endedUtc) {
                $ended = [datetime]::Parse([string]$site.endedUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            } elseif ($site.receivedUtc) {
                $ended = [datetime]::Parse([string]$site.receivedUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            }
        } catch { continue }
        if (-not $ended) { continue }
        $ageH = ($now - $ended).TotalHours
        if ($ageH -lt $staleHours) { continue }
        $key = 'stale:' + [string]$site.siteId
        if (-not (Test-MonitorWebhookCooldown -Key $key -CooldownMinutes $cooldown -StateMap $state)) { continue }
        Send-MonitorWebhook -Url ([string]$Config.WebhookUrl) -Event 'stale' -Site $site -Detail ("No heartbeat for {0:N0}h (threshold {1}h)" -f $ageH, $staleHours)
        $state[$key] = $now.ToString('o')
    }
    Save-MonitorWebhookState -Map $state
}

function Write-JsonResponse {
    param($Object, $Response, [int]$StatusCode = 200)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    $bytes = $utf8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Read-Body {
    param($Request)
    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { return $reader.ReadToEnd() } finally { $reader.Close() }
}

function Test-MonitorConstantTimeEquals {
    param([string]$A, [string]$B)
    if ($null -eq $A) { $A = '' }
    if ($null -eq $B) { $B = '' }
    $ba = [Text.Encoding]::UTF8.GetBytes($A)
    $bb = [Text.Encoding]::UTF8.GetBytes($B)
    $diff = $ba.Length -bxor $bb.Length
    $len = [Math]::Min($ba.Length, $bb.Length)
    for ($i = 0; $i -lt $len; $i++) {
        $diff = $diff -bor ($ba[$i] -bxor $bb[$i])
    }
    return ($diff -eq 0 -and $ba.Length -eq $bb.Length)
}

function Test-MonitorAuth {
    param($Request, [string]$Token)
    if (Test-MonitorTokenWeak -Token $Token) { return $false }
    $hdr = [string]$Request.Headers['Authorization']
    if ($hdr -match '^\s*Bearer\s+(.+)\s*$') {
        return (Test-MonitorConstantTimeEquals -A $Matches[1].Trim() -B $Token)
    }
    # Query-string tokens are rejected (leaked via logs/Referer/history).
    return $false
}

function Get-MonitorSites {
    $items = @()
    Get-ChildItem -LiteralPath $DataRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $items += ((Get-Content -LiteralPath $_.FullName -Raw) | ConvertFrom-Json)
        } catch { }
    }
    return @($items | Sort-Object { $_.siteId })
}

function Save-MonitorHeartbeat {
    param($BodyObj, $Config)
    $siteId = [string]$BodyObj.siteId
    if ([string]::IsNullOrWhiteSpace($siteId)) { $siteId = [string]$BodyObj.hostname }
    if ([string]::IsNullOrWhiteSpace($siteId)) { throw 'siteId is required' }
    $safe = ($siteId -replace '[^A-Za-z0-9._-]', '_')
    $path = Join-Path $DataRoot ($safe + '.json')
    $prev = $null
    if (Test-Path -LiteralPath $path) {
        try { $prev = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json } catch { }
    }
    $exitCode = $(if ($null -ne $BodyObj.exitCode) { [string]$BodyObj.exitCode } else { '' })
    $status = $(if ($BodyObj.status) { [string]$BodyObj.status } else { '' })
    $phase = $(if ($BodyObj.phase) { [string]$BodyObj.phase } else { '' })
    if ([string]::IsNullOrWhiteSpace($status)) {
        if ($exitCode -eq '3' -or $phase -eq 'degraded') { $status = 'degraded' }
        elseif ([bool]$BodyObj.success) { $status = 'ok' }
        else { $status = 'failed' }
    }
    if ($status -eq 'degraded' -and [string]::IsNullOrWhiteSpace($phase)) { $phase = 'degraded' }

    $rec = [ordered]@{
        siteId     = $siteId
        hostname   = $(if ($BodyObj.hostname) { [string]$BodyObj.hostname } else { '' })
        version    = $(if ($BodyObj.version) { [string]$BodyObj.version } else { '' })
        setId      = $(if ($BodyObj.setId) { [string]$BodyObj.setId } else { '' })
        setName    = $(if ($BodyObj.setName) { [string]$BodyObj.setName } else { '' })
        success    = [bool]$BodyObj.success
        status     = $status
        summary    = $(if ($BodyObj.summary) { [string]$BodyObj.summary } else { '' })
        snapshotId = $(if ($BodyObj.snapshotId) { [string]$BodyObj.snapshotId } else { '' })
        exitCode   = $exitCode
        phase      = $phase
        percent    = $(if ($null -ne $BodyObj.percent) { [int]$BodyObj.percent } else { 0 })
        endedUtc   = $(if ($BodyObj.endedUtc) { [string]$BodyObj.endedUtc } else { (Get-Date).ToUniversalTime().ToString('o') })
        receivedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    [IO.File]::WriteAllText($path, (($rec | ConvertTo-Json -Depth 6) + "`r`n"), $utf8)

    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.WebhookUrl) -and [bool]$Config.WebhookOnFail) {
        $isFail = -not [bool]$rec.success
        $wasFail = $false
        if ($prev -and $null -ne $prev.success) { $wasFail = -not [bool]$prev.success }
        $isTest = ([string]$rec.setId -eq 'test') -or (([string]$rec.summary).StartsWith('Test heartbeat'))
        if ($isFail -and -not $wasFail -and -not $isTest) {
            $state = Get-MonitorWebhookState
            $key = 'fail:' + $siteId
            $cooldown = [int]$Config.WebhookCooldownMinutes
            if ($cooldown -lt 1) { $cooldown = 60 }
            if (Test-MonitorWebhookCooldown -Key $key -CooldownMinutes $cooldown -StateMap $state) {
                Send-MonitorWebhook -Url ([string]$Config.WebhookUrl) -Event 'fail' -Site ([pscustomobject]$rec) -Detail ([string]$rec.summary)
                $state[$key] = (Get-Date).ToUniversalTime().ToString('o')
                Save-MonitorWebhookState -Map $state
            }
        }
    }

    return [pscustomobject]$rec
}

function Send-Static {
    param([string]$RelPath, $Response)
    if ([string]::IsNullOrWhiteSpace($RelPath)) {
        $Response.StatusCode = 404
        $Response.Close()
        return
    }
    $safe = ($RelPath -replace '/', '\').TrimStart('\')
    if ($safe -match '(^|[\\/])\.\.([\\/]|$)') {
        $Response.StatusCode = 403
        $Response.Close()
        return
    }
    $full = [IO.Path]::GetFullPath((Join-Path $UiRoot $safe))
    $rootFull = [IO.Path]::GetFullPath($UiRoot)
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        $Response.StatusCode = 403
        $Response.Close()
        return
    }
    if (-not (Test-Path -LiteralPath $full)) {
        $Response.StatusCode = 404
        $Response.Close()
        return
    }
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    $ctype = switch ($ext) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.svg'  { 'image/svg+xml' }
        '.png'  { 'image/png' }
        default { 'application/octet-stream' }
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    $Response.StatusCode = 200
    $Response.ContentType = $ctype
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

$cfg = Get-MonitorConfig
if ($cfg.Port -gt 0) { $Port = [int]$cfg.Port }
if (Test-MonitorTokenWeak -Token ([string]$cfg.Token)) {
    throw 'Monitor refused to start: token is missing, placeholder (change-me), or shorter than 24 characters. Edit Config\Monitor.json.'
}

$bindMode = ([string]$cfg.Bind).ToLowerInvariant()
if ($bindMode -eq 'lan') {
    $prefixCandidates = @("http://+:$Port/", "http://127.0.0.1:$Port/")
} else {
    $prefixCandidates = @("http://127.0.0.1:$Port/")
}

$listener = New-Object System.Net.HttpListener
$bound = $false
$boundPrefix = ''
foreach ($p in $prefixCandidates) {
    try {
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add($p)
        $listener.Start()
        $bound = $true
        $boundPrefix = $p
        Write-Host "SyncMe Monitor listening on $p" -ForegroundColor Green
        if ($p.StartsWith('http://+:')) {
            Write-Host "LAN/Tailscale: http://<this-pc>:$Port/ (Bind=lan). Protect with firewall; keep Token secret." -ForegroundColor Cyan
        }
        break
    } catch {
        try { $listener.Stop() } catch { }
        $listener = New-Object System.Net.HttpListener
    }
}
if (-not $bound) {
    if ($bindMode -eq 'lan') {
        throw "Failed to bind port $Port. Run as Administrator once, or: netsh http add urlacl url=http://+:$Port/ user=Everyone"
    }
    throw "Failed to bind loopback port $Port (http://127.0.0.1:$Port/)."
}

Write-Host "Token configured: yes (Authorization: Bearer …). Bind=$bindMode" -ForegroundColor Green
$tokenPreview = if ($cfg.Token.Length -gt 10) { $cfg.Token.Substring(0, 6) + '…' } else { '(set)' }
Write-Host "Token preview: $tokenPreview (full value in Config\Monitor.json)" -ForegroundColor DarkGray

$prefix = "http://127.0.0.1:$Port/"
if (-not $NoBrowser) {
    try { Start-Process $prefix } catch { }
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    try {
        $path = $req.Url.AbsolutePath
        if ($path -eq '/' -or $path -eq '/index.html') {
            Send-Static -RelPath 'index.html' -Response $res
            continue
        }
        if ($path.StartsWith('/ui/')) {
            Send-Static -RelPath $path.Substring(4) -Response $res
            continue
        }
        if ($path -eq '/api/sites' -and $req.HttpMethod -eq 'GET') {
            # Read-only dashboard for LAN/Tailscale operators (v1). Heartbeat ingest still requires the token.
            try { Invoke-MonitorStaleWebhooks -Config $cfg } catch { }
            Write-JsonResponse @{ ok = $true; sites = @(Get-MonitorSites) } -Response $res
            continue
        }
        if ($path -eq '/api/heartbeat' -and $req.HttpMethod -eq 'POST') {
            if (-not (Test-MonitorAuth -Request $req -Token $cfg.Token)) {
                Write-JsonResponse @{ ok = $false; message = 'Unauthorized' } -StatusCode 401 -Response $res
                continue
            }
            $raw = Read-Body $req
            $body = $raw | ConvertFrom-Json
            $saved = Save-MonitorHeartbeat -BodyObj $body -Config $cfg
            Write-JsonResponse @{ ok = $true; site = $saved } -Response $res
            continue
        }
        if ($path -eq '/api/status' -and $req.HttpMethod -eq 'GET') {
            Write-JsonResponse @{
                ok      = $true
                product = 'SyncMe Monitor'
                version = $(if (Test-Path (Join-Path $ScriptRoot 'VERSION.txt')) { (Get-Content (Join-Path $ScriptRoot 'VERSION.txt') -TotalCount 1).Trim() } else { '1.0.0' })
                port    = $Port
                sites   = @(Get-MonitorSites).Count
            } -Response $res
            continue
        }
        $res.StatusCode = 404
        $res.Close()
    } catch {
        try {
            Write-JsonResponse @{ ok = $false; message = $_.Exception.Message } -StatusCode 500 -Response $res
        } catch {
            try { $res.Abort() } catch { }
        }
    }
}
