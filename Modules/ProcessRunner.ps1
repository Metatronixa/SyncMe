#Requires -Version 5.1
<#
.SYNOPSIS
  Sole external-process spawn helper for SyncMe (restic/rclone/tools).
  Never pass secrets on argv; use env / Credential Manager.
#>

function Invoke-SyncMeExternalProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 0,
        [switch]$NoWindow
    )
    if ([string]::IsNullOrWhiteSpace($FilePath)) { throw 'FilePath is required.' }
    if (-not (Test-Path -LiteralPath $FilePath) -and $FilePath -notmatch '^(?i)[a-z0-9._-]+$') {
        # Allow bare names on PATH (e.g. restic) when not a rooted path
        if ($FilePath.Contains('\') -or $FilePath.Contains('/')) {
            throw "Executable not found: $FilePath"
        }
    }

    $outFile = Join-Path ([IO.Path]::GetTempPath()) ('syncme-proc-out-' + [guid]::NewGuid().ToString('n') + '.txt')
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ('syncme-proc-err-' + [guid]::NewGuid().ToString('n') + '.txt')
    $saved = @{}
    foreach ($k in @($Environment.Keys)) {
        $name = [string]$k
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$Environment[$k], 'Process')
    }
    try {
        $start = @{
            FilePath               = $FilePath
            ArgumentList           = $ArgumentList
            PassThru               = $true
            Wait                   = $false
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
            NoNewWindow            = $true
        }

        $p = Start-Process @start
        if ($TimeoutSec -gt 0) {
            if (-not $p.WaitForExit($TimeoutSec * 1000)) {
                try { $p.Kill() } catch { }
                throw "Process timed out after ${TimeoutSec}s: $FilePath"
            }
        } else {
            $p.WaitForExit() | Out-Null
        }
        $stdout = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } else { '' }
        return @{
            ExitCode = [int]$p.ExitCode
            StdOut   = if ($stdout) { $stdout.TrimEnd() } else { '' }
            StdErr   = if ($stderr) { $stderr.TrimEnd() } else { '' }
            FilePath = $FilePath
        }
    } finally {
        foreach ($k in @($saved.Keys)) {
            [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process')
        }
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}
