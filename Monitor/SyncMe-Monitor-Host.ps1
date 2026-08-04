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

function Get-MonitorConfig {
    $path = Join-Path $ScriptRoot 'Config\Monitor.json'
    $defaults = [ordered]@{
        Token = 'change-me'
        Port  = $Port
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $obj = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json
            if ($obj.Token) { $defaults.Token = [string]$obj.Token }
            if ($obj.Port) { $defaults.Port = [int]$obj.Port }
        } catch { }
    } else {
        $dir = Split-Path $path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($path, (($defaults | ConvertTo-Json) + "`r`n"), $utf8)
    }
    return [pscustomobject]$defaults
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

function Test-MonitorAuth {
    param($Request, [string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    $hdr = [string]$Request.Headers['Authorization']
    if ($hdr -match '^\s*Bearer\s+(.+)\s*$') {
        return ($Matches[1].Trim() -eq $Token)
    }
    $q = [string]$Request.QueryString['token']
    if (-not [string]::IsNullOrWhiteSpace($q) -and $q -eq $Token) { return $true }
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
    param($BodyObj)
    $siteId = [string]$BodyObj.siteId
    if ([string]::IsNullOrWhiteSpace($siteId)) { $siteId = [string]$BodyObj.hostname }
    if ([string]::IsNullOrWhiteSpace($siteId)) { throw 'siteId is required' }
    $safe = ($siteId -replace '[^A-Za-z0-9._-]', '_')
    $rec = [ordered]@{
        siteId     = $siteId
        hostname   = $(if ($BodyObj.hostname) { [string]$BodyObj.hostname } else { '' })
        version    = $(if ($BodyObj.version) { [string]$BodyObj.version } else { '' })
        setId      = $(if ($BodyObj.setId) { [string]$BodyObj.setId } else { '' })
        setName    = $(if ($BodyObj.setName) { [string]$BodyObj.setName } else { '' })
        success    = [bool]$BodyObj.success
        summary    = $(if ($BodyObj.summary) { [string]$BodyObj.summary } else { '' })
        snapshotId = $(if ($BodyObj.snapshotId) { [string]$BodyObj.snapshotId } else { '' })
        exitCode   = $(if ($null -ne $BodyObj.exitCode) { [string]$BodyObj.exitCode } else { '' })
        phase      = $(if ($BodyObj.phase) { [string]$BodyObj.phase } else { '' })
        percent    = $(if ($null -ne $BodyObj.percent) { [int]$BodyObj.percent } else { 0 })
        endedUtc   = $(if ($BodyObj.endedUtc) { [string]$BodyObj.endedUtc } else { (Get-Date).ToUniversalTime().ToString('o') })
        receivedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $path = Join-Path $DataRoot ($safe + '.json')
    [IO.File]::WriteAllText($path, (($rec | ConvertTo-Json -Depth 6) + "`r`n"), $utf8)
    return [pscustomobject]$rec
}

function Send-Static {
    param([string]$RelPath, $Response)
    $full = Join-Path $UiRoot ($RelPath -replace '/', '\')
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

$listener = New-Object System.Net.HttpListener
$bound = $false
foreach ($p in @("http://+:$Port/", "http://127.0.0.1:$Port/")) {
    try {
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add($p)
        $listener.Start()
        $bound = $true
        Write-Host "SyncMe Monitor listening on $p" -ForegroundColor Green
        if ($p.StartsWith('http://+:')) {
            Write-Host "LAN/Tailscale: http://<this-pc>:$Port/" -ForegroundColor Cyan
        }
        break
    } catch {
        try { $listener.Stop() } catch { }
        $listener = New-Object System.Net.HttpListener
    }
}
if (-not $bound) {
    throw "Failed to bind port $Port. Run as Administrator once, or: netsh http add urlacl url=http://+:$Port/ user=Everyone"
}

Write-Host "Token configured: $(if ($cfg.Token -and $cfg.Token -ne 'change-me') { 'yes' } else { 'DEFAULT - edit Config\Monitor.json' })" -ForegroundColor Yellow

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
            $saved = Save-MonitorHeartbeat -BodyObj $body
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
