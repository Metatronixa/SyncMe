#Requires -Version 5.1
<#
.SYNOPSIS
  Snapshot list and restore helpers for SyncMe (restic).
#>

function Resolve-SyncMeResticExe {
    <#
      Finds restic.exe for SyncMe.
      Order: configured full path → SyncMe\tools\restic.exe → PATH → common install locations.
      Returns @{ Ok = $true/$false; Path = '...' }
    #>
    [CmdletBinding()]
    param(
        [string]$ConfiguredPath = 'restic',
        [string]$ScriptRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        if ($PSScriptRoot) {
            # Prefer caller context; when defined in Modules\, parent is SyncMe root
            $ScriptRoot = Split-Path -Parent $PSScriptRoot
        } else {
            $ScriptRoot = (Get-Location).Path
        }
    }

    $configured = if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) { 'restic' } else { $ConfiguredPath.Trim() }

    if ($configured -ne 'restic') {
        if (Test-Path -LiteralPath $configured) {
            try {
                return @{ Ok = $true; Path = [string]((Resolve-Path -LiteralPath $configured).Path) }
            } catch {
                return @{ Ok = $true; Path = $configured }
            }
        }
        $underRoot = Join-Path $ScriptRoot $configured
        if (Test-Path -LiteralPath $underRoot) {
            try {
                return @{ Ok = $true; Path = [string]((Resolve-Path -LiteralPath $underRoot).Path) }
            } catch {
                return @{ Ok = $true; Path = $underRoot }
            }
        }
    }

    $local = Join-Path $ScriptRoot 'tools\restic.exe'
    if (Test-Path -LiteralPath $local) {
        return @{ Ok = $true; Path = $local }
    }

    $cmd = Get-Command restic -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
        return @{ Ok = $true; Path = [string]$cmd.Source }
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'restic\restic.exe')) }
    if ($env:ProgramFiles) { [void]$candidates.Add((Join-Path $env:ProgramFiles 'restic\restic.exe')) }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($pf86) { [void]$candidates.Add((Join-Path $pf86 'restic\restic.exe')) }
    if ($env:USERPROFILE) { [void]$candidates.Add((Join-Path $env:USERPROFILE 'scoop\apps\restic\current\restic.exe')) }
    if ($env:ChocolateyInstall) { [void]$candidates.Add((Join-Path $env:ChocolateyInstall 'bin\restic.exe')) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return @{ Ok = $true; Path = $c }
        }
    }

    return @{ Ok = $false; Path = '' }
}

function Get-SyncMeResticExePath {
    <#
      Resolves restic from a set/config object. Throws if not found.
    #>
    param(
        $Config,
        [string]$ScriptRoot = ''
    )
    $configured = 'restic'
    if ($Config -and $Config.PSObject.Properties.Name -contains 'ResticPath' -and $Config.ResticPath) {
        $configured = [string]$Config.ResticPath
    }
    $r = Resolve-SyncMeResticExe -ConfiguredPath $configured -ScriptRoot $ScriptRoot
    if (-not $r.Ok) {
        throw 'restic not found. Use SyncMe → Install restic (saves into tools\restic.exe), or set a full ResticPath.'
    }
    return $r.Path
}

function Get-SyncMeSnapshots {
    <#
      Returns array of hashtables: Id, ShortId, Time, Tags, Paths, Hostname, Display
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$LogPath = ''
    )
    . (Join-Path $PSScriptRoot 'Notify.ps1')
    $scriptRoot = Split-Path -Parent $PSScriptRoot
    $resticExe = Get-SyncMeResticExePath -Config $Config -ScriptRoot $scriptRoot
    $cred = Get-BackupStoredCredential -TargetName $Config.ResticCredentialName
    $plain = $cred.GetNetworkCredential().Password

    $env:RESTIC_PASSWORD = $plain
    $env:RESTIC_REPOSITORY = $Config.ResticRepo
    try {
        $raw = & $resticExe snapshots --json 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            throw "restic snapshots failed (exit $code): $($raw | Out-String)"
        }
        $text = ($raw | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or $text -eq 'null' -or $text -eq '[]') {
            return @()
        }
        $items = $text | ConvertFrom-Json
        if ($null -eq $items) { return @() }
        if ($items -isnot [System.Array]) { $items = @($items) }

        $out = foreach ($s in $items) {
            $id = [string]$s.id
            $short = if ($id.Length -ge 8) { $id.Substring(0, 8) } else { $id }
            $time = [string]$s.time
            $tags = @()
            if ($s.tags) { $tags = @($s.tags) }
            $paths = @()
            if ($s.paths) { $paths = @($s.paths) }
            $host = [string]$s.hostname
            $display = "$short  $time  tags=[$($tags -join ',')]  $($paths -join ', ')"
            [pscustomobject]@{
                Id       = $id
                ShortId  = $short
                Time     = $time
                Tags     = $tags
                Paths    = $paths
                Hostname = $host
                Display  = $display
            }
        }
        # Newest first (restic often returns oldest first)
        return @($out | Sort-Object Time -Descending)
    } finally {
        Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
    }
}

function Test-SyncMeRestoreTargetSafe {
    param(
        [string]$TargetPath,
        [string]$ResticRepo
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return @{ Ok = $false; Message = 'Target folder is empty.' }
    }
    if ($ResticRepo -match '^rclone:') {
        # Cloud repo — only ensure target is a normal local/UNC path
        if ($TargetPath -match '^rclone:') {
            return @{ Ok = $false; Message = 'Restore target must be a local or UNC folder, not rclone:.' }
        }
        $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
        $nonEmpty = $false
        if (Test-Path -LiteralPath $targetFull) {
            $any = Get-ChildItem -LiteralPath $targetFull -Force -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($any) { $nonEmpty = $true }
        }
        return @{ Ok = $true; Message = ''; NonEmpty = $nonEmpty; FullPath = $targetFull }
    }
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    $repoFull = [System.IO.Path]::GetFullPath($ResticRepo)
    if ($targetFull.TrimEnd('\') -ieq $repoFull.TrimEnd('\')) {
        return @{ Ok = $false; Message = 'Refusing to restore into the live restic repository path.' }
    }
    if ($targetFull.StartsWith($repoFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return @{ Ok = $false; Message = 'Refusing to restore into a folder inside the restic repository.' }
    }
    $nonEmpty = $false
    if (Test-Path -LiteralPath $targetFull) {
        $any = Get-ChildItem -LiteralPath $targetFull -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($any) { $nonEmpty = $true }
    }
    return @{ Ok = $true; Message = ''; NonEmpty = $nonEmpty; FullPath = $targetFull }
}

function Invoke-SyncMeRestore {
    <#
      Restores a snapshot (id or 'latest') to TargetPath.
      Returns hashtable: Success, ExitCode, Message, TargetPath
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Snapshot,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$Include = '',
        [string]$LogPath = ''
    )
    . (Join-Path $PSScriptRoot 'Notify.ps1')

    $safe = Test-SyncMeRestoreTargetSafe -TargetPath $TargetPath -ResticRepo $Config.ResticRepo
    if (-not $safe.Ok) {
        return @{ Success = $false; ExitCode = 1; Message = $safe.Message; TargetPath = $TargetPath }
    }

    if (-not (Test-Path -LiteralPath $safe.FullPath)) {
        New-Item -ItemType Directory -Path $safe.FullPath -Force | Out-Null
    }

    $resticExe = Get-SyncMeResticExePath -Config $Config -ScriptRoot (Split-Path -Parent $PSScriptRoot)
    $cred = Get-BackupStoredCredential -TargetName $Config.ResticCredentialName
    $plain = $cred.GetNetworkCredential().Password

    $args = @('restore', $Snapshot, '--target', $safe.FullPath)
    if (-not [string]::IsNullOrWhiteSpace($Include)) {
        $args += @('--include', $Include.Trim())
    }

    $env:RESTIC_PASSWORD = $plain
    $env:RESTIC_REPOSITORY = $Config.ResticRepo
    try {
        $output = & $resticExe @args 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ok = ($code -eq 0)
        $msg = if ($ok) {
            "Restore completed to $($safe.FullPath)"
        } else {
            "Restore failed (exit $code). $output"
        }
        if ($LogPath) {
            Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue
        }
        return @{ Success = $ok; ExitCode = $code; Message = $msg; TargetPath = $safe.FullPath; Detail = $output }
    } finally {
        Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
    }
}

function Get-SyncMeDefaultRestoreTarget {
    param(
        $Config,
        [string]$ScriptRoot = ''
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $arch = $Config.ArchivePath
    $root = $null
    if ($arch -and $arch.Length -ge 2 -and $arch[1] -eq ':') {
        $root = $arch.Substring(0, 2) + '\'
    }
    if (-not $root) {
        $repo = [string]$Config.ResticRepo
        if ($repo -and $repo.Length -ge 2 -and $repo[1] -eq ':' -and $repo -notmatch '^rclone:') {
            $root = $repo.Substring(0, 2) + '\'
        }
    }
    if ($root) {
        return (Join-Path $root "SyncMe-Restore\$stamp")
    }
    $base = if ($ScriptRoot) { $ScriptRoot } else { $PSScriptRoot }
    if (-not $base) { $base = (Get-Location).Path }
    return (Join-Path $base "Restores\$stamp")
}
