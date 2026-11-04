#Requires -Version 5.1
<#
.SYNOPSIS
  Shared helpers for Monarch Offsite Backup launchers (elevation, Tailscale, logging).
#>

function Test-MonarchIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-MonarchElevation {
    <#
      Relaunches the current script elevated with the same arguments and waits.
      Returns the elevated process exit code. Caller should exit with that code.
      If already admin, returns $null (caller continues).
    #>
    param(
        [string]$ScriptPath = $PSCommandPath,
        [string[]]$ArgumentList = @()
    )
    if (Test-MonarchIsAdmin) { return $null }

    $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    foreach ($a in $ArgumentList) {
        if ($null -eq $a) { continue }
        $s = [string]$a
        if ($s -match '\s') {
            $argString += " `"$s`""
        } else {
            $argString += " $s"
        }
    }
    Write-Host "Administrator rights required. Requesting elevation..." -ForegroundColor Yellow
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argString -Wait -PassThru
        return [int]$p.ExitCode
    } catch {
        Write-Host "Elevation cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
        return 1
    }
}

function Test-MonarchTailscale {
    <#
      Returns a hashtable: Ok (bool), Message (string), Detail (string)
    #>
    $result = @{ Ok = $false; Message = ''; Detail = '' }

    $svc = Get-Service -Name 'Tailscale','TailscaleService' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $svc) {
        $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Tailscale*' } | Select-Object -First 1
    }
    if ($svc) {
        $result.Detail = "Service $($svc.Name)=$($svc.Status)"
        if ($svc.Status -ne 'Running') {
            $result.Message = "Tailscale service is $($svc.Status). Start Tailscale before backing up."
            return $result
        }
    } else {
        $result.Detail = 'Tailscale service not found by name'
    }

    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $statusOut = & tailscale status 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                $result.Message = "tailscale status failed (exit $LASTEXITCODE). Is Tailscale logged in?"
                $result.Detail = ($result.Detail + '; ' + $statusOut.Trim()).Trim('; ')
                return $result
            }
            $result.Ok = $true
            $result.Message = 'Tailscale appears active.'
            $result.Detail = ($result.Detail + '; tailscale status OK').Trim('; ')
            return $result
        } catch {
            $result.Message = "tailscale status error: $($_.Exception.Message)"
            return $result
        }
    }

    # No CLI: trust service Running if found
    if ($svc -and $svc.Status -eq 'Running') {
        $result.Ok = $true
        $result.Message = 'Tailscale service is running (CLI not on PATH).'
        return $result
    }

    $result.Message = 'Could not verify Tailscale. Install/start Tailscale if backups use MagicDNS/UNC over the tailnet.'
    return $result
}

function Start-MonarchLauncherTranscript {
    param(
        [string]$ScriptRoot,
        [string]$Prefix = 'launcher'
    )
    $logsDir = Join-Path $ScriptRoot 'Logs'
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    $path = Join-Path $logsDir ("{0}-{1}.log" -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        Start-Transcript -Path $path -Force | Out-Null
    } catch {
        # Fallback: still return path for bat redirection
    }
    return $path
}

function Stop-MonarchLauncherTranscript {
    try { Stop-Transcript | Out-Null } catch { }
}

function Add-SyncMeSharedLine {
    <#
      Append one line with FileShare.ReadWrite so the console can tail the same file.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    for ($i = 0; $i -lt 8; $i++) {
        try {
            $fs = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                $sw = New-Object System.IO.StreamWriter($fs, $utf8)
                try {
                    $sw.WriteLine($Line)
                    $sw.Flush()
                } finally {
                    $sw.Dispose()
                }
            } finally {
                $fs.Dispose()
            }
            return
        } catch {
            Start-Sleep -Milliseconds (40 * ($i + 1))
        }
    }
    # Last resort - may still fail under hard lock
    Add-Content -LiteralPath $Path -Value $Line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Show-SyncMeFolderPicker {
    <#
      Native Windows folder picker (Explorer-style FolderBrowserDialog) on an STA thread.
      Returns @{ Ok; Path; Cancelled; Message }.
    #>
    param(
        [string]$Description = 'Select a folder',
        [string]$InitialPath = ''
    )
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $ps = [powershell]::Create()
    try {
        $ps.Runspace = $runspace
        [void]$ps.AddScript({
            param([string]$Desc, [string]$Init)
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = $(if ([string]::IsNullOrWhiteSpace($Desc)) { 'Select a folder' } else { $Desc })
            $dlg.ShowNewFolderButton = $true
            if (-not [string]::IsNullOrWhiteSpace($Init)) {
                try {
                    if (Test-Path -LiteralPath $Init) {
                        $dlg.SelectedPath = (Resolve-Path -LiteralPath $Init).Path
                    } else {
                        $parent = Split-Path -Parent $Init
                        if ($parent -and (Test-Path -LiteralPath $parent)) {
                            $dlg.SelectedPath = (Resolve-Path -LiteralPath $parent).Path
                        }
                    }
                } catch { }
            }
            $form = New-Object System.Windows.Forms.Form
            $form.TopMost = $true
            $form.ShowInTaskbar = $false
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
            $form.Opacity = 0
            try {
                [void]$form.Show()
                $form.Activate()
                $r = $dlg.ShowDialog($form)
                if ($r -eq [System.Windows.Forms.DialogResult]::OK -and -not [string]::IsNullOrWhiteSpace($dlg.SelectedPath)) {
                    return [pscustomobject]@{ Ok = $true; Path = [string]$dlg.SelectedPath; Cancelled = $false; Message = '' }
                }
                return [pscustomobject]@{ Ok = $false; Path = ''; Cancelled = $true; Message = 'Cancelled' }
            } finally {
                try { $form.Close() } catch { }
                try { $form.Dispose() } catch { }
                try { $dlg.Dispose() } catch { }
            }
        }).AddArgument([string]$Description).AddArgument([string]$InitialPath)
        $out = $ps.Invoke()
        if ($ps.HadErrors) {
            $err = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
            return [pscustomobject]@{ Ok = $false; Path = ''; Cancelled = $false; Message = $(if ($err) { $err } else { 'Folder picker failed.' }) }
        }
        $first = @($out) | Select-Object -First 1
        if ($first) { return $first }
        return [pscustomobject]@{ Ok = $false; Path = ''; Cancelled = $true; Message = 'No selection' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Path = ''; Cancelled = $false; Message = $_.Exception.Message }
    } finally {
        try { $ps.Dispose() } catch { }
        try { $runspace.Close() } catch { }
        try { $runspace.Dispose() } catch { }
    }
}

function Read-SyncMeSharedTextTail {
    <#
      Read last N lines with FileShare.ReadWrite (safe while backup appends).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Tail = 200
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $fs = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
                try {
                    $all = $sr.ReadToEnd()
                } finally {
                    $sr.Dispose()
                }
            } finally {
                $fs.Dispose()
            }
            if ([string]::IsNullOrEmpty($all)) { return @() }
            $lines = [regex]::Split($all.TrimEnd("`r", "`n"), '\r?\n')
            if ($lines.Count -le $Tail) { return @($lines) }
            return @($lines[($lines.Count - $Tail)..($lines.Count - 1)])
        } catch {
            Start-Sleep -Milliseconds (30 * ($i + 1))
        }
    }
    return @()
}

