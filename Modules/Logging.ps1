#Requires -Version 5.1
<#
.SYNOPSIS
  Structured SyncMe log lines (JSON-ish key=value for machine parsing).
  Classes: INFO, WARN, ERROR, AUDIT, SECURITY. SECRET must never be persisted.
#>

function Test-SyncMeLogLooksLikeSecret {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '(?i)(password|passwd|secret|token|bearer\s+[A-Za-z0-9\-._~+/]+=*|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY)') { return $true }
    if ($Text -match '(?i)(RESTIC_PASSWORD|Authorization:\s*Bearer)') { return $true }
    return $false
}

function Write-SyncMeStructuredLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'AUDIT', 'SECURITY', 'SECRET')]
        [string]$Level = 'INFO',
        [string]$LogPath = '',
        [hashtable]$Fields = @{},
        [string]$ScriptRoot = ''
    )
    # SECRET class: never write to disk (and scrub accidental secret-like payloads).
    if ($Level -eq 'SECRET' -or (Test-SyncMeLogLooksLikeSecret -Text $Message)) {
        return 'level=SECRET msg="(redacted - not persisted)"'
    }
    $ts = (Get-Date).ToUniversalTime().ToString('o')
    $parts = [System.Collections.Generic.List[string]]::new()
    [void]$parts.Add(('ts={0}' -f $ts))
    [void]$parts.Add(('level={0}' -f $Level))
    foreach ($k in @($Fields.Keys | Sort-Object)) {
        $keyName = [string]$k
        if ($keyName -match '(?i)(password|secret|token|authorization)') { continue }
        $v = [string]$Fields[$k]
        if (Test-SyncMeLogLooksLikeSecret -Text $v) { continue }
        $v = $v -replace '[\r\n]+', ' ' -replace '"', ''''
        if ($v.Length -gt 200) { $v = $v.Substring(0, 200) + '…' }
        [void]$parts.Add(('{0}="{1}"' -f $keyName, $v))
    }
    $msg = $Message -replace '[\r\n]+', ' '
    [void]$parts.Add(('msg="{0}"' -f ($msg -replace '"', '''')))
    $line = $parts -join ' '

    if ([string]::IsNullOrWhiteSpace($LogPath) -and $ScriptRoot) {
        $dir = Join-Path $ScriptRoot 'Logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $LogPath = Join-Path $dir 'syncme-structured.log'
    }
    if ($LogPath) {
        try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
    }
    return $line
}
