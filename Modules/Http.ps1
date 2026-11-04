#Requires -Version 5.1
<#
.SYNOPSIS
  HTTP request/response helpers for SyncMe HttpListener.
#>

function Write-SyncMeJson {
    param($Object, [int]$StatusCode = 200, $Response)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Read-SyncMeBody {
    param(
        $Request,
        [long]$MaxBodyBytes = 1048576
    )
    if (-not $Request.HasEntityBody) { return $null }
    if ($Request.ContentLength64 -gt $MaxBodyBytes) {
        throw "Payload too large (max $MaxBodyBytes bytes)."
    }
    $ct = [string]$Request.ContentType
    if (-not [string]::IsNullOrWhiteSpace($ct) -and ($ct -notmatch '(?i)^application/json(\s*;|$)')) {
        throw 'Unsupported Media Type: application/json required.'
    }
    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        $raw = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt $MaxBodyBytes) {
            throw "Payload too large (max $MaxBodyBytes bytes)."
        }
        return $raw | ConvertFrom-Json
    } finally {
        $reader.Close()
    }
}

function Get-SyncMeMimeType {
    param([string]$Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.js'   { return 'application/javascript; charset=utf-8' }
        '.svg'  { return 'image/svg+xml' }
        '.png'  { return 'image/png' }
        '.jpg'  { return 'image/jpeg' }
        '.ico'  { return 'image/x-icon' }
        '.json' { return 'application/json; charset=utf-8' }
        default { return 'application/octet-stream' }
    }
}

function Send-SyncMeStaticFile {
    param(
        [string]$UiRoot,
        [string]$RelPath,
        $Response
    )
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
    $bytes = [IO.File]::ReadAllBytes($full)
    $Response.StatusCode = 200
    $Response.ContentType = (Get-SyncMeMimeType -Path $full)
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}
