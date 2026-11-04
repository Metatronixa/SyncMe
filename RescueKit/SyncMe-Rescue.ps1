#Requires -Version 5.1
<#
.SYNOPSIS
  Recover SyncMe without a healthy Host (stop, previous release, config check, diagnostics, safe mode, health).
#>
[CmdletBinding()]
param(
    [ValidateSet('Stop', 'RestorePrevious', 'ValidateConfig', 'Diagnostics', 'SafeMode', 'Health', 'Help')]
    [string]$Action = 'Diagnostics',
    [string]$InstallRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Write-Rescue([string]$Msg, [string]$Level = 'INFO') {
    Write-Host ("[{0}] {1}" -f $Level, $Msg)
}

function Stop-SyncMeProcesses {
    $killed = @()
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'powershell' -and (
                $_.CommandLine -match 'SyncMe-Host\.ps1' -or
                $_.CommandLine -match 'SyncMe-Backup\.ps1' -or
                $_.CommandLine -match 'SyncMe-Restore\.ps1'
            )
        } | ForEach-Object {
            try {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                $killed += [string]$_.ProcessId
            } catch { }
        }
    if ($killed.Count) {
        Write-Rescue ("Stopped process(es): " + ($killed -join ', '))
    } else {
        Write-Rescue 'No SyncMe PowerShell host/backup/restore process found.'
    }
}

function Get-SyncMePreviousReleaseDir {
    $logs = Join-Path $InstallRoot 'Logs'
    $named = Join-Path $logs 'previous-release'
    if (Test-Path -LiteralPath (Join-Path $named 'SyncMe-Host.ps1')) { return $named }
    $dirs = @(Get-ChildItem -LiteralPath $logs -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'previous-release-*' } |
        Sort-Object LastWriteTime -Descending)
    if ($dirs.Count) { return $dirs[0].FullName }
    return $null
}

function Restore-SyncMePreviousRelease {
    $src = Get-SyncMePreviousReleaseDir
    if (-not $src) { throw 'No previous-release backup found under Logs\previous-release.' }
    Stop-SyncMeProcesses
    Start-Sleep -Seconds 2
    foreach ($rel in @('SyncMe-Host.ps1', 'SyncMe-Backup.ps1', 'SyncMe-Restore.ps1', 'VERSION.txt', 'Modules', 'ui', 'RescueKit')) {
        $from = Join-Path $src $rel
        $to = Join-Path $InstallRoot $rel
        if (-not (Test-Path -LiteralPath $from)) { continue }
        if (Test-Path -LiteralPath $from -PathType Container) {
            if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
            Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
        } else {
            Copy-Item -LiteralPath $from -Destination $to -Force
        }
        Write-Rescue ("Restored " + $rel)
    }
}

function Test-SyncMeConfigFile {
    $cfg = Join-Path $InstallRoot 'Config.ps1'
    if (-not (Test-Path -LiteralPath $cfg)) {
        Write-Rescue 'Config.ps1 missing (fresh install or wiped config).' 'WARN'
        return $false
    }
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($cfg, [ref]$null, [ref]$errs)
    if ($errs) {
        Write-Rescue 'Config.ps1 parse failed:' 'ERROR'
        $errs | ForEach-Object { Write-Rescue $_.Message 'ERROR' }
        return $false
    }
    Write-Rescue 'Config.ps1 parses.'
    return $true
}

function Export-SyncMeRescueDiagnostics {
    $outDir = Join-Path $InstallRoot ('Logs\rescue-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $ver = Join-Path $InstallRoot 'VERSION.txt'
    $hostPs1 = Join-Path $InstallRoot 'SyncMe-Host.ps1'
    $schema = Join-Path $InstallRoot 'Config\schema-version.txt'
    $lines = @(
        ("Computer=" + $env:COMPUTERNAME),
        ("Install=" + $InstallRoot),
        ("Version=" + $(if (Test-Path $ver) { (Get-Content $ver -TotalCount 1).Trim() } else { '?' })),
        ("HostExists=" + (Test-Path -LiteralPath $hostPs1)),
        ("ConfigExists=" + (Test-Path -LiteralPath (Join-Path $InstallRoot 'Config.ps1'))),
        ("SchemaVersion=" + $(if (Test-Path $schema) { (Get-Content $schema -TotalCount 1).Trim() } else { 'none' })),
        ("PreviousRelease=" + [bool](Get-SyncMePreviousReleaseDir)),
        ("TimeUtc=" + (Get-Date).ToUniversalTime().ToString('o'))
    )
    $lines | Set-Content -LiteralPath (Join-Path $outDir 'diagnostics.txt') -Encoding UTF8
    foreach ($f in @('Logs\update-apply.log', 'Logs\update-state.json', 'Logs\syncme-structured.log')) {
        $p = Join-Path $InstallRoot $f
        if (Test-Path -LiteralPath $p) {
            Copy-Item -LiteralPath $p -Destination (Join-Path $outDir (Split-Path $f -Leaf)) -Force
        }
    }
    Write-Rescue ("Diagnostics written to " + $outDir + " (no secrets).")
    return $outDir
}

function Invoke-SyncMeRescueHealth {
    $health = Join-Path $InstallRoot 'Modules\Health.ps1'
    $sets = Join-Path $InstallRoot 'Modules\Sets.ps1'
    $update = Join-Path $InstallRoot 'Modules\Update.ps1'
    if (-not (Test-Path -LiteralPath $health)) { throw 'Modules\Health.ps1 missing.' }
    . $health
    if (Test-Path -LiteralPath $sets) { . $sets }
    if (Test-Path -LiteralPath $update) { . $update }
    $probe = Get-SyncMeHealthProbe -ScriptRoot $InstallRoot
    Write-Rescue ("Health status=" + $probe.status + " version=" + $probe.version)
    foreach ($c in @($probe.checks)) {
        Write-Rescue (('  [{0}] {1} {2}' -f $c.status, $c.name, $c.detail))
    }
    return $probe
}

function Show-SyncMeRescueHelp {
    $readme = Join-Path $PSScriptRoot 'README.txt'
    if (Test-Path -LiteralPath $readme) {
        Get-Content -LiteralPath $readme | Write-Host
    } else {
        Write-Rescue 'See RescueKit\README.txt and docs\DISASTER-RECOVERY.md'
    }
}

switch ($Action) {
    'Help' { Show-SyncMeRescueHelp }
    'Stop' { Stop-SyncMeProcesses }
    'RestorePrevious' { Restore-SyncMePreviousRelease }
    'ValidateConfig' { [void](Test-SyncMeConfigFile) }
    'Diagnostics' { [void](Export-SyncMeRescueDiagnostics) }
    'Health' { [void](Invoke-SyncMeRescueHealth) }
    'SafeMode' {
        Stop-SyncMeProcesses
        $hostPs1 = Join-Path $InstallRoot 'SyncMe-Host.ps1'
        if (-not (Test-Path -LiteralPath $hostPs1)) { throw 'SyncMe-Host.ps1 missing.' }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $ps -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $hostPs1, '-NoBrowser'
        ) -WindowStyle Minimized
        Write-Rescue 'Started Host with -NoBrowser (safe mode). Open http://127.0.0.1:17845/ if the listener binds.'
    }
}
