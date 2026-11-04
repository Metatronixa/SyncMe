#Requires -Version 5.1
<#
.SYNOPSIS
  Snapshot list and restore helpers for SyncMe (restic).
#>

if (-not (Get-Command Assert-SyncMeSafePath -ErrorAction SilentlyContinue)) {
    $sec = Join-Path $PSScriptRoot 'Security.ps1'
    if (Test-Path -LiteralPath $sec) { . $sec }
}

function Resolve-SyncMeResticExe {
    <#
      Finds restic.exe for SyncMe.
      Order: configured full path -> SyncMe\tools\restic.exe -> PATH -> common install locations.
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
        throw 'restic not found. Use SyncMe -> Install restic (saves into tools\restic.exe), or set a full ResticPath.'
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
            $timeLocal = $time
            try {
                $dt = [datetime]::Parse($time, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                $timeLocal = $dt.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            } catch {
                try {
                    $dt2 = Get-Date $time
                    $timeLocal = $dt2.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                } catch { }
            }
            $tags = @()
            if ($s.tags) { $tags = @($s.tags) }
            $paths = @()
            if ($s.paths) { $paths = @($s.paths) }
            $hasUnc = [bool](@($paths) | Where-Object { $_ -match '^\\\\' })
            $snapHostname = [string]$s.hostname
            $uncNote = if ($hasUnc) { '  [UNC - Windows restore unsupported]' } else { '' }
            $display = "$short  backup $timeLocal$uncNote  tags=[$($tags -join ',')]  $($paths -join ', ')"
            [pscustomobject]@{
                Id          = $id
                ShortId     = $short
                Time        = $time
                TimeLocal   = $timeLocal
                Tags        = $tags
                Paths       = $paths
                Hostname    = $snapHostname
                HasUncPaths = $hasUnc
                Display     = $display
            }
        }
        # Newest first (restic often returns oldest first)
        return @($out | Sort-Object Time -Descending)
    } finally {
        Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
    }
}

function Test-SyncMeIsDriveRoot {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $true }
    $p = $FullPath.TrimEnd('\')
    # C: or C:\
    if ($p -match '^[A-Za-z]:$') { return $true }
    if ($p -match '^[A-Za-z]:\\?$') { return $true }
    return $false
}

function Test-SyncMePathUnderOrEqual {
    param([string]$Candidate, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $c = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\')
        $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    } catch { return $false }
    if ($c -ieq $r) { return $true }
    return $c.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-SyncMeRestoreTargetSafe {
    param(
        [string]$TargetPath,
        [string]$ResticRepo,
        [string[]]$SourcePaths = @(),
        [string]$ScriptRoot = '',
        [string]$ArchivePath = '',
        [switch]$AllowNonEmpty
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return @{ Ok = $false; Message = 'Target folder is empty.'; NonEmpty = $false }
    }
    if ($TargetPath -match '^rclone:') {
        return @{ Ok = $false; Message = 'Restore target must be a local or UNC folder, not rclone:.'; NonEmpty = $false }
    }
    try {
        $targetFull = Assert-SyncMeSafePath -Path $TargetPath -AllowUnc
    } catch {
        return @{ Ok = $false; Message = $_.Exception.Message; NonEmpty = $false }
    }
    if (Test-SyncMeIsDriveRoot -FullPath $targetFull) {
        return @{ Ok = $false; Message = 'Refusing to restore into a drive root. Use an empty subfolder.'; NonEmpty = $false; FullPath = $targetFull }
    }
    if (Get-Command Test-SyncMeDangerousWindowsRoot -ErrorAction SilentlyContinue) {
        if (Test-SyncMeDangerousWindowsRoot -FullPath $targetFull) {
            return @{ Ok = $false; Message = 'Refusing to restore into Windows, Program Files, or ProgramData.'; NonEmpty = $false; FullPath = $targetFull }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
        try {
            $install = [System.IO.Path]::GetFullPath($ScriptRoot).TrimEnd('\')
            $restoresAllowed = Join-Path $install 'Restores'
            $underInstall = Test-SyncMePathUnderOrEqual -Candidate $targetFull -Root $install
            $underRestores = Test-SyncMePathUnderOrEqual -Candidate $targetFull -Root $restoresAllowed
            # Only Restores\<stamp> under the install is an allowed scratch target; never modules/config/logs.
            if ($underInstall -and -not $underRestores) {
                return @{ Ok = $false; Message = 'Refusing to restore into the SyncMe install folder (use Restores\ or an empty folder outside SyncMe).'; NonEmpty = $false; FullPath = $targetFull }
            }
            if ($underRestores -and (Test-SyncMeIsDriveRoot -FullPath $targetFull) -eq $false) {
                # Restores root itself is not a restore target; require a subfolder.
                $rf = [System.IO.Path]::GetFullPath($restoresAllowed).TrimEnd('\')
                if ($targetFull.TrimEnd('\') -ieq $rf) {
                    return @{ Ok = $false; Message = 'Choose a new empty subfolder under Restores\, not Restores itself.'; NonEmpty = $false; FullPath = $targetFull }
                }
            }
        } catch { }
    }
    foreach ($src in @($SourcePaths)) {
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        try {
            if (Test-SyncMePathUnderOrEqual -Candidate $targetFull -Root $src) {
                return @{ Ok = $false; Message = "Refusing to restore into a configured source path ($src)."; NonEmpty = $false; FullPath = $targetFull }
            }
        } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($ArchivePath) -and $ArchivePath -notmatch '^rclone:') {
        try {
            if (Test-SyncMePathUnderOrEqual -Candidate $targetFull -Root $ArchivePath) {
                return @{ Ok = $false; Message = 'Refusing to restore into the archive destination path.'; NonEmpty = $false; FullPath = $targetFull }
            }
        } catch { }
    }
    if ($ResticRepo -and $ResticRepo -notmatch '^rclone:') {
        try {
            $repoFull = [System.IO.Path]::GetFullPath($ResticRepo)
            if (Test-SyncMePathUnderOrEqual -Candidate $targetFull -Root $repoFull) {
                return @{ Ok = $false; Message = 'Refusing to restore into the live restic repository path.'; NonEmpty = $false; FullPath = $targetFull }
            }
        } catch {
            return @{ Ok = $false; Message = 'Repository path is invalid.'; NonEmpty = $false }
        }
    }
    $nonEmpty = $false
    if (Test-Path -LiteralPath $targetFull) {
        $any = Get-ChildItem -LiteralPath $targetFull -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($any) { $nonEmpty = $true }
    }
    if ($nonEmpty -and -not $AllowNonEmpty) {
        return @{
            Ok       = $false
            Message  = 'Restore target must be an empty folder (contains existing files). Choose a new empty directory.'
            NonEmpty = $true
            FullPath = $targetFull
        }
    }
    return @{ Ok = $true; Message = ''; NonEmpty = $nonEmpty; FullPath = $targetFull }
}

function Test-SyncMeSnapshotHasUncPaths {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Snapshot
    )
    $snaps = @(Get-SyncMeSnapshots -Config $Config)
    if (-not $snaps.Count) {
        return @{ HasUnc = $false; Message = ''; Snapshot = $null }
    }
    $s = $null
    if ($Snapshot -eq 'latest') {
        $s = $snaps[0]
    } else {
        $want = $Snapshot.Trim()
        $s = $snaps | Where-Object {
            $_.Id -eq $want -or $_.ShortId -eq $want -or
            ($_.Id -and $_.Id.StartsWith($want, [StringComparison]::OrdinalIgnoreCase))
        } | Select-Object -First 1
    }
    if (-not $s) {
        return @{ HasUnc = $false; Message = ''; Snapshot = $null }
    }
    if ($s.HasUncPaths) {
        $uncPaths = @($s.Paths | Where-Object { $_ -match '^\\\\' })
        $msg = "This snapshot was backed up using UNC paths ($($uncPaths -join ', ')). Windows restic cannot restore those snapshots (invalid child node name). Run a new backup - SyncMe now stores drive-letter paths - then restore the new snapshot."
        return @{ HasUnc = $true; Message = $msg; Snapshot = $s }
    }
    return @{ HasUnc = $false; Message = ''; Snapshot = $s }
}

function Remove-SyncMeSnapshot {
    <#
      Forgets a single snapshot by id (does not prune pack data).
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SnapshotId,
        [string]$LogPath = ''
    )
    . (Join-Path $PSScriptRoot 'Notify.ps1')
    if ([string]::IsNullOrWhiteSpace($SnapshotId) -or $SnapshotId -eq 'latest') {
        throw 'A specific snapshot id is required to delete (not latest).'
    }
    $scriptRoot = Split-Path -Parent $PSScriptRoot
    $resticExe = Get-SyncMeResticExePath -Config $Config -ScriptRoot $scriptRoot
    $credTarget = [string]$Config.ResticCredentialName
    if (Get-Command Get-SyncMeResticDestructiveCredentialTarget -ErrorAction SilentlyContinue) {
        $meta = Get-SyncMeResticDestructiveCredentialTarget -Config $Config -ScriptRoot $scriptRoot -AllowFallback
        if ($meta.TargetName) { $credTarget = [string]$meta.TargetName }
    }
    $cred = Get-BackupStoredCredential -TargetName $credTarget
    $plain = $cred.GetNetworkCredential().Password
    $env:RESTIC_PASSWORD = $plain
    $env:RESTIC_REPOSITORY = $Config.ResticRepo
    try {
        $output = & $resticExe forget $SnapshotId 2>&1 | Out-String
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            throw "restic forget failed (exit $code): $output"
        }
        $msg = "Deleted snapshot $SnapshotId from the repository (data packs not pruned)."
        if ($LogPath) {
            Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue
        }
        return @{ Success = $true; Message = $msg; Detail = $output }
    } finally {
        Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
    }
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

    $uncCheck = Test-SyncMeSnapshotHasUncPaths -Config $Config -Snapshot $Snapshot
    if ($uncCheck.HasUnc) {
        return @{ Success = $false; ExitCode = 1; Message = $uncCheck.Message; TargetPath = $TargetPath }
    }

    $srcPaths = @()
    if ($Config.PSObject.Properties['SourcePaths'] -and $Config.SourcePaths) {
        $srcPaths = @($Config.SourcePaths)
    } elseif ($Config.PSObject.Properties['SourcePath'] -and $Config.SourcePath) {
        $srcPaths = @([string]$Config.SourcePath)
    }
    $arch = if ($Config.PSObject.Properties['ArchivePath']) { [string]$Config.ArchivePath } else { '' }
    $installRoot = Split-Path -Parent $PSScriptRoot
    $safe = Test-SyncMeRestoreTargetSafe -TargetPath $TargetPath -ResticRepo $Config.ResticRepo `
        -SourcePaths $srcPaths -ScriptRoot $installRoot -ArchivePath $arch
    if (-not $safe.Ok) {
        return @{ Success = $false; ExitCode = 1; Message = $safe.Message; TargetPath = $TargetPath }
    }

    # Re-check emptiness immediately before restic (TOCTOU).
    $recheck = Test-SyncMeRestoreTargetSafe -TargetPath $safe.FullPath -ResticRepo $Config.ResticRepo `
        -SourcePaths $srcPaths -ScriptRoot $installRoot -ArchivePath $arch
    if (-not $recheck.Ok) {
        return @{ Success = $false; ExitCode = 1; Message = $recheck.Message; TargetPath = $TargetPath }
    }

    if (-not (Test-Path -LiteralPath $safe.FullPath)) {
        New-Item -ItemType Directory -Path $safe.FullPath -Force | Out-Null
        $final = Test-SyncMeRestoreTargetSafe -TargetPath $safe.FullPath -ResticRepo $Config.ResticRepo `
            -SourcePaths $srcPaths -ScriptRoot $installRoot -ArchivePath $arch
        if (-not $final.Ok) {
            return @{ Success = $false; ExitCode = 1; Message = $final.Message; TargetPath = $TargetPath }
        }
    }

    $resticExe = Get-SyncMeResticExePath -Config $Config -ScriptRoot (Split-Path -Parent $PSScriptRoot)
    $cred = Get-BackupStoredCredential -TargetName $Config.ResticCredentialName
    $plain = $cred.GetNetworkCredential().Password

    $args = @('restore', $Snapshot, '--target', $safe.FullPath)
    if (-not [string]::IsNullOrWhiteSpace($Include)) {
        try {
            $incSafe = Assert-SyncMeRestoreInclude -Include $Include
        } catch {
            return @{ Success = $false; ExitCode = 1; Message = $_.Exception.Message; TargetPath = $TargetPath }
        }
        $includeRestic = ConvertTo-SyncMeResticAbsPath -Path $incSafe
        if ([string]::IsNullOrWhiteSpace($includeRestic)) { $includeRestic = $incSafe }
        $args += @('--include', $includeRestic)
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
            $detail = $output
            if ($detail -match '(?i)invalid child node name') {
                $detail = "Windows restic rejected UNC path nodes in this snapshot. Run a new backup (drive-letter sources), then restore that snapshot. Raw: $detail"
            }
            "Restore failed (exit $code). $detail"
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

function Get-SyncMeNormalizedSnapshotPath {
    <#
      Canonical Windows-style path for UI / parent matching.
      Maps restic abs forms (/C/Foo or \C\Foo) to C:\Foo. Leaves UNC as \\server\share\...
    #>
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    # UNC (\\server\share or //server/share)
    if ($p -match '^(\\\\|//)[^\\/]') {
        $p = $p -replace '/', '\'
        return $p.TrimEnd('\')
    }
    $p = $p -replace '/', '\'
    while ($p.Contains('\\') -and $p -notmatch '^\\\\') {
        $p = $p.Replace('\\', '\')
    }
    $p = $p.TrimEnd('\')
    # restic-style \C\Foo -> C:\Foo
    if ($p -match '^\\([A-Za-z])\\(.+)$') {
        return ($Matches[1].ToUpperInvariant() + ':\' + $Matches[2])
    }
    if ($p -match '^\\([A-Za-z])$') {
        return ($Matches[1].ToUpperInvariant() + ':')
    }
    if ($p -match '^([A-Za-z]):\\?$') {
        return ($Matches[1].ToUpperInvariant() + ':')
    }
    if ($p -match '^([A-Za-z]):\\(.+)$') {
        return ($Matches[1].ToUpperInvariant() + ':\' + $Matches[2])
    }
    return $p
}

function ConvertTo-SyncMeResticAbsPath {
    <#
      Convert UI/Windows path to restic directory filter form (must start with /).
      C:\Foo\Bar -> /C/Foo/Bar ; /C/Foo stays /C/Foo.
    #>
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $raw = $Path.Trim()
    if ($raw.StartsWith('/')) {
        $parts = @($raw.Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries))
        if ($parts.Count -lt 1) { return '/' }
        return '/' + ($parts -join '/')
    }
    $win = Get-SyncMeNormalizedSnapshotPath -Path $raw
    if ([string]::IsNullOrWhiteSpace($win)) { return '' }
    if ($win -match '^[A-Za-z]:') {
        $letter = $win.Substring(0, 1).ToUpperInvariant()
        $rest = ''
        if ($win.Length -gt 2) {
            $rest = $win.Substring(2).TrimStart('\').Replace('\', '/')
        }
        if ([string]::IsNullOrWhiteSpace($rest)) { return "/$letter" }
        return "/$letter/$rest"
    }
    # Non-drive path: force leading /
    $fwd = $win.TrimStart('\').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($fwd)) { return '/' }
    return "/$fwd"
}

function Get-SyncMeSnapshotPathParent {
    param([string]$Path)
    $p = Get-SyncMeNormalizedSnapshotPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $idx = $p.LastIndexOf('\')
    if ($idx -lt 0) { return '' }
    if ($idx -eq 2 -and $p.Length -ge 3 -and $p[1] -eq ':') {
        # Parent of C:\Foo is C:  - treat drive root specially
        return $p.Substring(0, 2)
    }
    return $p.Substring(0, $idx)
}

function Get-SyncMeSnapshotPathName {
    param([string]$Path)
    $p = Get-SyncMeNormalizedSnapshotPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $idx = $p.LastIndexOf('\')
    if ($idx -lt 0) { return $p }
    if ($idx -eq $p.Length - 1) { return $p.TrimEnd('\') }
    return $p.Substring($idx + 1)
}

function Get-SyncMeSnapshotListing {
    <#
      Lazy directory listing for a snapshot (immediate children only).
      Empty Path returns snapshot root Paths as folders.
      Returns hashtable: Ok, Message, Path, Entries[{name,path,type,size}], Truncated, SnapshotId
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Snapshot,
        [string]$Path = '',
        [int]$MaxEntries = 1000,
        [int]$TimeoutSeconds = 90
    )
    # TimeoutSeconds kept for API compatibility; listing uses sync & restic (same as snapshots).
    $null = $TimeoutSeconds

    try {
        . (Join-Path $PSScriptRoot 'Notify.ps1')

        if ($MaxEntries -lt 1) { $MaxEntries = 1000 }

        $uncCheck = Test-SyncMeSnapshotHasUncPaths -Config $Config -Snapshot $Snapshot
        if ($uncCheck.HasUnc) {
            return ,@{
                Ok         = $false
                Message    = [string]$uncCheck.Message
                Path       = [string]$Path
                Entries    = @()
                Truncated  = $false
                SnapshotId = $(if ($uncCheck.Snapshot) { [string]$uncCheck.Snapshot.Id } else { [string]$Snapshot })
            }
        }

        $snapObj = $uncCheck.Snapshot
        if (-not $snapObj) {
            $snaps = @(Get-SyncMeSnapshots -Config $Config)
            if ($Snapshot -eq 'latest') {
                $snapObj = $snaps | Select-Object -First 1
            } else {
                $want = $Snapshot.Trim()
                $snapObj = $snaps | Where-Object {
                    $_.Id -eq $want -or $_.ShortId -eq $want -or
                    ($_.Id -and $_.Id.StartsWith($want, [StringComparison]::OrdinalIgnoreCase))
                } | Select-Object -First 1
            }
        }
        if (-not $snapObj) {
            return ,@{
                Ok         = $false
                Message    = "Snapshot not found: $Snapshot"
                Path       = [string]$Path
                Entries    = @()
                Truncated  = $false
                SnapshotId = [string]$Snapshot
            }
        }

        $snapId = [string]$snapObj.Id
        $normPath = Get-SyncMeNormalizedSnapshotPath -Path $Path

        # Root listing: snapshot source paths only (no full-tree ls).
        # Use plain PS arrays - @($List[object]) throws "Argument types do not match" on Windows PowerShell 5.1.
        if ([string]::IsNullOrWhiteSpace($normPath)) {
            $roots = @(foreach ($rp in @($snapObj.Paths)) {
                if ([string]::IsNullOrWhiteSpace([string]$rp)) { continue }
                $full = Get-SyncMeNormalizedSnapshotPath -Path ([string]$rp)
                [pscustomobject]@{
                    name = Get-SyncMeSnapshotPathName -Path $full
                    path = $full
                    type = 'dir'
                    size = $null
                }
            })
            return ,@{
                Ok         = $true
                Message    = ''
                Path       = ''
                Entries    = $roots
                Truncated  = $false
                SnapshotId = $snapId
            }
        }

        $scriptRoot = Split-Path -Parent $PSScriptRoot
        $resticExe = Get-SyncMeResticExePath -Config $Config -ScriptRoot $scriptRoot
        $cred = Get-BackupStoredCredential -TargetName $Config.ResticCredentialName
        $plain = $cred.GetNetworkCredential().Password

        $env:RESTIC_PASSWORD = $plain
        $env:RESTIC_REPOSITORY = $Config.ResticRepo
        $entries = @()
        $truncated = $false
        $parentNorm = $normPath

        try {
            # restic requires directory filters absolute with leading '/' (e.g. /C/Users/...).
            $resticPath = ConvertTo-SyncMeResticAbsPath -Path $normPath
            $raw = & $resticExe ls $snapId $resticPath --json 2>&1
            $lec = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
            $code = if ($null -ne $lec -and $null -ne $lec.Value) { [int]$lec.Value } else { 1 }

            $lineTexts = New-Object System.Collections.Generic.List[string]
            $errBits = New-Object System.Collections.Generic.List[string]
            foreach ($item in @($raw)) {
                $text = if ($item -is [System.Management.Automation.ErrorRecord]) {
                    if ($item.Exception -and $item.Exception.Message) { [string]$item.Exception.Message }
                    else { $item.ToString() }
                } else {
                    [string]$item
                }
                if ([string]::IsNullOrWhiteSpace($text)) { continue }
                if ($text -match '^\s*\{') {
                    [void]$lineTexts.Add($text.Trim())
                } else {
                    [void]$errBits.Add($text)
                }
            }

            if ($code -ne 0) {
                $msg = if ($errBits.Count -gt 0) { ($errBits -join ' ').Trim() } else { "restic ls failed (exit $code)." }
                foreach ($line in $lineTexts) {
                    try {
                        $eo = $line | ConvertFrom-Json
                        if ($eo -and ($eo.PSObject.Properties.Name -contains 'message_type') -and [string]$eo.message_type -eq 'exit_error' -and $eo.message) {
                            $msg = [string]$eo.message
                            break
                        }
                    } catch { }
                }
                if ($msg -match '(?i)invalid child node name') {
                    $msg = 'Windows restic rejected UNC path nodes in this snapshot. Run a new backup, then browse that snapshot.'
                } elseif ($msg -match '(?i)path filters must be absolute|starting with a forward slash') {
                    $msg = "Folder path must use restic absolute form (e.g. $resticPath). SyncMe should convert automatically - update to the latest SyncMe build if this persists."
                }
                return ,@{
                    Ok         = $false
                    Message    = "Snapshot browse failed: $msg"
                    Path       = $normPath
                    Entries    = @()
                    Truncated  = $false
                    SnapshotId = $snapId
                }
            }

            foreach ($line in $lineTexts) {
                $obj = $null
                try { $obj = $line | ConvertFrom-Json } catch { continue }
                if (-not $obj) { continue }

                $entryPath = ''
                if ($obj.PSObject.Properties.Name -contains 'path' -and $obj.path) {
                    $entryPath = Get-SyncMeNormalizedSnapshotPath -Path ([string]$obj.path)
                } elseif ($obj.PSObject.Properties.Name -contains 'name' -and $obj.name) {
                    $entryPath = Get-SyncMeNormalizedSnapshotPath -Path (Join-Path $parentNorm ([string]$obj.name))
                }
                if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }
                if ($entryPath -ieq $parentNorm) { continue }

                $entryParent = Get-SyncMeSnapshotPathParent -Path $entryPath
                if ($entryParent -ine $parentNorm) { continue }

                $type = 'file'
                if ($obj.PSObject.Properties.Name -contains 'type' -and $obj.type) {
                    $t = [string]$obj.type
                    if ($t -eq 'dir' -or $t -eq 'directory') { $type = 'dir' }
                } elseif ($obj.PSObject.Properties.Name -contains 'mode') {
                    try {
                        $mode = [long]$obj.mode
                        if (($mode -band 0x4000) -ne 0) { $type = 'dir' }
                    } catch { }
                }

                $size = $null
                if ($obj.PSObject.Properties.Name -contains 'size' -and $null -ne $obj.size) {
                    try { $size = [long]$obj.size } catch { $size = $null }
                }

                $name = Get-SyncMeSnapshotPathName -Path $entryPath
                if ($obj.PSObject.Properties.Name -contains 'name' -and $obj.name) {
                    $name = [string]$obj.name
                }

                if ($entries.Count -ge $MaxEntries) {
                    $truncated = $true
                    break
                }
                $entries += [pscustomobject]@{
                    name = $name
                    path = $entryPath
                    type = $type
                    size = $size
                }
            }

            $sorted = @($entries | Sort-Object @{ Expression = { if ($_.type -eq 'dir') { 0 } else { 1 } } }, @{ Expression = { $_.name } })

            return ,@{
                Ok         = $true
                Message    = $(if ($truncated) { "Showing first $MaxEntries entries in this folder." } else { '' })
                Path       = $normPath
                Entries    = $sorted
                Truncated  = $truncated
                SnapshotId = $snapId
            }
        } finally {
            Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
            Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
        }
    } catch {
        $exType = $_.Exception.GetType().FullName
        $exMsg = [string]$_.Exception.Message
        if ($exMsg -match '(?i)path filters must be absolute|starting with a forward slash') {
            $hintPath = ''
            try { $hintPath = ConvertTo-SyncMeResticAbsPath -Path $Path } catch { }
            $exMsg = "Folder path must be restic-absolute (starting with '/')" + $(if ($hintPath) { ", e.g. $hintPath" } else { '' }) + '. Update SyncMe if browse still fails after this version.'
            $exType = 'path-format'
        }
        return ,@{
            Ok         = $false
            Message    = "Snapshot browse failed ($exType): $exMsg"
            Path       = $(if ($Path) { Get-SyncMeNormalizedSnapshotPath -Path $Path } else { [string]$Path })
            Entries    = @()
            Truncated  = $false
            SnapshotId = [string]$Snapshot
        }
    }
}

function Write-SyncMeRestoreVerifyEvidence {
    param(
        [string]$ScriptRoot,
        [string]$SetId,
        [hashtable]$Evidence
    )
    $dir = Join-Path $ScriptRoot ("Logs\sets\$SetId")
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'restore-verify-evidence.json'
    $obj = [ordered]@{}
    foreach ($k in @($Evidence.Keys)) { $obj[[string]$k] = $Evidence[$k] }
    if (-not $obj.Contains('verifiedUtc')) {
        $obj['verifiedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    }
    [IO.File]::WriteAllText($path, (($obj | ConvertTo-Json -Depth 6) + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    return $path
}

function Get-SyncMeRestoreVerifyEvidence {
    param([string]$ScriptRoot, [string]$SetId = 'set1')
    $path = Join-Path $ScriptRoot ("Logs\sets\$SetId\restore-verify-evidence.json")
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return ((Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json) } catch { return $null }
}

function Test-SyncMeRestoreDrill {
    <#
      Restore verification: dump sample file(s) from the latest snapshot, hash + read-test,
      write evidence under Logs\sets\<id>\restore-verify-evidence.json, delete temp restore.
      Uses restic dump (not restore --include) to avoid Windows UNC-root restore failures.
      Returns Ok / Skipped / Message / Evidence. Advisory unless FailJobOnRestoreDrillFailure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$SetId = '',
        [string]$LogPath = ''
    )

    . (Join-Path $PSScriptRoot 'Notify.ps1')
    $scriptRoot = Split-Path -Parent $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($SetId)) {
        $SetId = if ($Config.Id) { [string]$Config.Id } else { 'set1' }
    }

    $resticExe = Get-SyncMeResticExePath -Config $Config -ScriptRoot $scriptRoot
    $cred = Get-BackupStoredCredential -TargetName $Config.ResticCredentialName
    $plain = $cred.GetNetworkCredential().Password

    $sandbox = Join-Path $env:TEMP ("SyncMe-Drill\" + $SetId)
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

    $env:RESTIC_PASSWORD = $plain
    $env:RESTIC_REPOSITORY = $Config.ResticRepo
    if ($Config.RcloneConfigPath) { $env:RCLONE_CONFIG = [string]$Config.RcloneConfigPath }

    try {
        $rawSnaps = & $resticExe snapshots --json 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            throw "restic snapshots failed (exit $code): $($rawSnaps | Out-String)"
        }
        $snapText = ($rawSnaps | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($snapText) -or $snapText -eq 'null' -or $snapText -eq '[]') {
            $msg = 'Skipped: no snapshots available for restore drill.'
            if ($LogPath) {
                try { Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue } catch { }
            }
            return ,@{
                Ok         = $true
                Skipped    = $true
                Message    = $msg
                Path       = ''
                Size       = [long]0
                SnapshotId = ''
            }
        }
        $items = $snapText | ConvertFrom-Json
        if ($null -eq $items) {
            $msg = 'Skipped: no snapshots available for restore drill.'
            if ($LogPath) {
                try { Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue } catch { }
            }
            return ,@{
                Ok         = $true
                Skipped    = $true
                Message    = $msg
                Path       = ''
                Size       = [long]0
                SnapshotId = ''
            }
        }
        if ($items -isnot [System.Array]) { $items = @($items) }
        if ($items.Count -lt 1) {
            $msg = 'Skipped: no snapshots available for restore drill.'
            if ($LogPath) {
                try { Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue } catch { }
            }
            return ,@{
                Ok         = $true
                Skipped    = $true
                Message    = $msg
                Path       = ''
                Size       = [long]0
                SnapshotId = ''
            }
        }

        $latest = $items | Sort-Object { try { [datetime]$_.time } catch { [datetime]::MinValue } } -Descending | Select-Object -First 1
        $snapId = [string]$latest.id
        if ([string]::IsNullOrWhiteSpace($snapId)) { throw 'Latest snapshot has no id.' }

        $rawLs = & $resticExe ls $snapId --json 2>&1
        $lsCode = $LASTEXITCODE
        if ($lsCode -ne 0) {
            throw "restic ls failed (exit $lsCode): $($rawLs | Out-String)"
        }

        $filePaths = @()
        foreach ($item in @($rawLs)) {
            $text = if ($item -is [System.Management.Automation.ErrorRecord]) {
                if ($item.Exception -and $item.Exception.Message) { [string]$item.Exception.Message } else { $item.ToString() }
            } else { [string]$item }
            if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch '^\s*\{') { continue }
            $obj = $null
            try { $obj = $text.Trim() | ConvertFrom-Json } catch { continue }
            if (-not $obj) { continue }
            $type = ''
            if ($obj.PSObject.Properties.Name -contains 'type' -and $obj.type) { $type = [string]$obj.type }
            if ($type -ne 'file') { continue }
            if (-not ($obj.PSObject.Properties.Name -contains 'path') -or [string]::IsNullOrWhiteSpace([string]$obj.path)) { continue }
            # Exact snapshot path for restic dump (no path rewriting)
            $filePaths += [string]$obj.path
        }
        if ($filePaths.Count -lt 1) {
            $msg = 'Skipped: no file entries found in latest snapshot for restore drill.'
            if ($LogPath) {
                try { Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue } catch { }
            }
            return ,@{
                Ok         = $true
                Skipped    = $true
                Message    = $msg
                Path       = ''
                Size       = [long]0
                SnapshotId = $snapId
            }
        }

        $attempts = [Math]::Min(3, $filePaths.Count)
        $pool = @($filePaths | Get-Random -Count $attempts)
        $lastErr = ''
        foreach ($pick in $pool) {
            $safeName = ($pick -replace '[\\/:*?"<>|]', '_')
            if ($safeName.Length -gt 80) { $safeName = $safeName.Substring($safeName.Length - 80) }
            $outFile = Join-Path $sandbox ("dump-" + [guid]::NewGuid().ToString('n').Substring(0, 8) + "-" + $safeName)
            try {
                # cmd redirection keeps binary dump off the PowerShell pipeline
                $argLine = '"' + $resticExe + '" dump "' + $snapId + '" "' + $pick + '" > "' + $outFile + '" 2>nul'
                $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $argLine) -Wait -PassThru -WindowStyle Hidden
                $dumpCode = [int]$p.ExitCode
                if ($dumpCode -ne 0) {
                    $lastErr = "restic dump exit $dumpCode for path='$pick'"
                    continue
                }
                if (-not (Test-Path -LiteralPath $outFile)) {
                    $lastErr = "restic dump produced no file for path='$pick'"
                    continue
                }
                $len = [long](Get-Item -LiteralPath $outFile).Length
                if ($len -lt 1) {
                    $lastErr = "restic dump produced empty file for path='$pick'"
                    continue
                }
                $sha = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash.ToLowerInvariant()
                $readOk = $false
                $readBytes = 0
                try {
                    $fs = [IO.File]::OpenRead($outFile)
                    try {
                        $buf = New-Object byte[] ([Math]::Min(4096, [int][Math]::Min($len, 4096)))
                        $readBytes = $fs.Read($buf, 0, $buf.Length)
                        $readOk = ($readBytes -gt 0)
                    } finally { $fs.Dispose() }
                } catch {
                    $lastErr = "read test failed for path='$pick': $($_.Exception.Message)"
                    continue
                }
                if (-not $readOk) {
                    $lastErr = "read test returned 0 bytes for path='$pick'"
                    continue
                }

                $evidence = @{
                    ok          = $true
                    setId       = $SetId
                    snapshotId  = $snapId
                    path        = $pick
                    size        = $len
                    sha256      = $sha
                    readBytes   = $readBytes
                    readOk      = $true
                    method      = 'restic-dump'
                    verifiedUtc = (Get-Date).ToUniversalTime().ToString('o')
                }
                try {
                    $evPath = Write-SyncMeRestoreVerifyEvidence -ScriptRoot $scriptRoot -SetId $SetId -Evidence $evidence
                    $evidence['evidencePath'] = $evPath
                } catch { }

                if (Get-Command Write-SyncMeStructuredLog -ErrorAction SilentlyContinue) {
                    try {
                        Write-SyncMeStructuredLog -ScriptRoot $scriptRoot -Level AUDIT -Message 'Restore verification evidence recorded' -Fields @{
                            setId = $SetId; snapshotId = $snapId; size = $len; sha256 = $sha
                        }
                    } catch { }
                }

                $msg = "Restore verification OK: snapshot=$snapId path=$pick size=$len sha256=$sha readBytes=$readBytes"
                if ($LogPath) {
                    try { Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue } catch { }
                }
                return ,@{
                    Ok         = $true
                    Skipped    = $false
                    Message    = $msg
                    Path       = $pick
                    Size       = $len
                    SnapshotId = $snapId
                    Sha256     = $sha
                    ReadOk     = $true
                    Evidence   = $evidence
                }
            } catch {
                $lastErr = "restic dump failed for path='$pick': $($_.Exception.Message)"
            }
        }

        throw "Restore verification failed after $attempts dump attempt(s). Last: $lastErr"
    } catch {
        $err = [string]$_.Exception.Message
        if ($LogPath) {
            try { Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) Restore drill FAILED (advisory): $err" -ErrorAction SilentlyContinue } catch { }
        }
        return ,@{
            Ok         = $false
            Skipped    = $false
            Message    = $err
            Path       = ''
            Size       = [long]0
            SnapshotId = ''
        }
    } finally {
        Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
        Remove-Item Env:RCLONE_CONFIG -ErrorAction SilentlyContinue
        try {
            if (Test-Path -LiteralPath $sandbox) {
                Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}
