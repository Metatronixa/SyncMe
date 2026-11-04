#Requires -Version 5.1
<#
.SYNOPSIS
  Path and restore destination guards (V2.1 contracts on the 1.x host).
#>

function ConvertTo-SyncMeNormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $t = $Path.Trim()
    if ($t.IndexOfAny([char[]]@([char]0)) -ge 0) { throw 'Path contains a null character.' }
    if ($t -match ':[^\\/]') {
        # Alternate data stream (C:\file:stream) except drive letter
        if ($t -notmatch '^[A-Za-z]:[\\/]') { throw 'Path looks like an NTFS alternate data stream.' }
        if ($t.Substring(2) -match ':') { throw 'Path looks like an NTFS alternate data stream.' }
    }
    return [System.IO.Path]::GetFullPath($t)
}

function Test-SyncMePathHasDotDot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $parts = $Path -split '[\\/]'
    return [bool]($parts | Where-Object { $_ -eq '..' })
}

function Test-SyncMeReparsePoint {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $false }
    if (-not (Test-Path -LiteralPath $FullPath)) { return $false }
    try {
        $item = Get-Item -LiteralPath $FullPath -Force -ErrorAction Stop
        # Directory/file reparse (symlink, junction, mount point)
        return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } catch {
        return $false
    }
}

function Assert-SyncMeSafePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowUnc,
        [switch]$AllowReparse
    )
    if (Test-SyncMePathHasDotDot -Path $Path) {
        throw 'Access denied: path contains ..'
    }
    $full = ConvertTo-SyncMeNormalizedPath -Path $Path
    if (Test-SyncMePathHasDotDot -Path $full) {
        throw 'Access denied: resolved path still contains ..'
    }
    $isUnc = $full.StartsWith('\\')
    $isDrive = $full -match '^[A-Za-z]:\\'
    if ($isUnc) {
        if (-not $AllowUnc) { throw 'Access denied: UNC paths are not allowed here.' }
    } elseif (-not $isDrive) {
        throw 'Access denied: path must be a local drive path or UNC.'
    }
    if (-not $AllowReparse -and (Test-SyncMeReparsePoint -FullPath $full)) {
        throw 'Access denied: path is a reparse point (symlink/junction).'
    }
    # Reject intermediate reparse parents for local paths (best-effort)
    if (-not $AllowReparse -and $isDrive) {
        $parts = $full.TrimEnd('\').Split('\')
        if ($parts.Count -gt 1) {
            $acc = $parts[0]
            for ($i = 1; $i -lt ($parts.Count - 1); $i++) {
                $acc = Join-Path $acc $parts[$i]
                if (Test-SyncMeReparsePoint -FullPath $acc) {
                    throw "Access denied: path crosses reparse point at $acc"
                }
            }
        }
    }
    return $full
}

function Test-SyncMeDangerousWindowsRoot {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $true }
    $p = $FullPath.TrimEnd('\')
    $roots = @(
        "$env:SystemRoot",
        "$env:ProgramFiles",
        ${env:ProgramFiles(x86)},
        "$env:ProgramData",
        "$env:WINDIR"
    ) | Where-Object { $_ }
    foreach ($r in $roots) {
        try {
            $rf = [System.IO.Path]::GetFullPath($r).TrimEnd('\')
            if ($p -ieq $rf) { return $true }
            if ($p.StartsWith($rf + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        } catch { }
    }
    return $false
}

function Assert-SyncMeRestoreInclude {
    param([string]$Include)
    if ([string]::IsNullOrWhiteSpace($Include)) { return '' }
    $t = $Include.Trim()
    if (Test-SyncMePathHasDotDot -Path $t) {
        throw 'Include path must not contain ..'
    }
    if ($t.IndexOfAny([char[]]@([char]0)) -ge 0) { throw 'Include path contains a null character.' }
    return $t
}

function New-SyncMeCsrfToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $b64 = [Convert]::ToBase64String($bytes).TrimEnd('=')
    return (($b64 -replace '\+', '-') -replace '/', '_')
}

function Test-SyncMeConstantTimeEquals {
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

function Test-SyncMeRequestSameOrigin {
    param(
        $Request,
        [int]$ExpectedPort
    )
    $hostHdr = [string]$Request.Headers['Host']
    if ([string]::IsNullOrWhiteSpace($hostHdr)) { return $false }
    $expectedHosts = @(
        "127.0.0.1:$ExpectedPort",
        "localhost:$ExpectedPort",
        "[::1]:$ExpectedPort"
    )
    $hostOk = $false
    foreach ($h in $expectedHosts) {
        if ($hostHdr.Equals($h, [StringComparison]::OrdinalIgnoreCase)) { $hostOk = $true; break }
    }
    if (-not $hostOk) { return $false }

    $origin = [string]$Request.Headers['Origin']
    $referer = [string]$Request.Headers['Referer']
    $allowedOrigins = @(
        "http://127.0.0.1:$ExpectedPort",
        "http://localhost:$ExpectedPort",
        "http://[::1]:$ExpectedPort"
    )
    if (-not [string]::IsNullOrWhiteSpace($origin)) {
        foreach ($o in $allowedOrigins) {
            if ($origin.Equals($o, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($referer)) {
        foreach ($o in $allowedOrigins) {
            if ($referer.StartsWith($o + '/', [StringComparison]::OrdinalIgnoreCase) -or
                $referer.Equals($o, [StringComparison]::OrdinalIgnoreCase) -or
                $referer.StartsWith($o + '?', [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }
    # Non-browser clients (curl, LocalOps) often omit Origin/Referer; Host check alone is OK for loopback.
    return $true
}

function Assert-SyncMeApiRequestBasics {
    param(
        $Request,
        [long]$MaxQueryChars = 2048
    )
    $method = [string]$Request.HttpMethod
    if ($method -notin @('GET', 'HEAD', 'POST', 'OPTIONS')) {
        throw 'Method Not Allowed.'
    }
    $qs = ''
    try { $qs = [string]$Request.Url.Query } catch { }
    if ($qs.Length -gt $MaxQueryChars) {
        throw 'Query string too long.'
    }
    $path = ''
    try { $path = [string]$Request.Url.AbsolutePath } catch { }
    if ($path.Length -gt 512) {
        throw 'Request path too long.'
    }
    if ($path -match '[\x00-\x1F]') {
        throw 'Request path contains invalid characters.'
    }
}

function Assert-SyncMeMutatingApiRequest {
    param(
        $Request,
        [int]$ExpectedPort,
        [string]$CsrfToken,
        [long]$MaxBodyBytes = 1048576
    )
    $method = [string]$Request.HttpMethod
    if ($method -notin @('POST', 'PUT', 'PATCH', 'DELETE')) { return }

    if (-not (Test-SyncMeRequestSameOrigin -Request $Request -ExpectedPort $ExpectedPort)) {
        throw 'Forbidden: invalid Origin/Host for SyncMe API.'
    }

    $csrf = [string]$Request.Headers['X-SyncMe-CSRF']
    if ([string]::IsNullOrWhiteSpace($csrf) -or -not (Test-SyncMeConstantTimeEquals -A $csrf -B $CsrfToken)) {
        throw 'Forbidden: missing or invalid CSRF token.'
    }

    if ($Request.HasEntityBody) {
        $ct = [string]$Request.ContentType
        if ([string]::IsNullOrWhiteSpace($ct) -or ($ct -notmatch '(?i)^application/json(\s*;|$)')) {
            throw 'Unsupported Media Type: application/json required.'
        }
        if ($Request.ContentLength64 -gt $MaxBodyBytes) {
            throw "Payload too large (max $MaxBodyBytes bytes)."
        }
    }
}

function Get-SyncMeFleetOutcome {
    <#
      Maps backup run info to fleet health: ok | degraded | failed.
      restic exit 3 (incomplete snapshot / unread files) is degraded even when Success is true.
    #>
    param([object]$RunInfo)
    if (-not $RunInfo) { return 'failed' }
    $code = ''
    if ($null -ne $RunInfo.BackupExitCode) { $code = [string]$RunInfo.BackupExitCode }
    $ok = [bool]$RunInfo.Success
    if ($code -eq '3') { return 'degraded' }
    if ($ok) { return 'ok' }
    return 'failed'
}
