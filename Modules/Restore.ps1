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
            $uncNote = if ($hasUnc) { '  [UNC — Windows restore unsupported]' } else { '' }
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
        $msg = "This snapshot was backed up using UNC paths ($($uncPaths -join ', ')). Windows restic cannot restore those snapshots (invalid child node name). Run a new backup — SyncMe now stores drive-letter paths — then restore the new snapshot."
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
    $resticExe = Get-SyncMeResticExePath -Config $Config -ScriptRoot (Split-Path -Parent $PSScriptRoot)
    $cred = Get-BackupStoredCredential -TargetName $Config.ResticCredentialName
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
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim() -replace '/', '\'
    while ($p.Contains('\\') -and $p -notmatch '^\\\\') {
        $p = $p.Replace('\\', '\')
    }
    return $p.TrimEnd('\')
}

function Get-SyncMeSnapshotPathParent {
    param([string]$Path)
    $p = Get-SyncMeNormalizedSnapshotPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $idx = $p.LastIndexOf('\')
    if ($idx -lt 0) { return '' }
    if ($idx -eq 2 -and $p.Length -ge 3 -and $p[1] -eq ':') {
        # Parent of C:\Foo is C:  — treat drive root specially
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
        # Use plain PS arrays — @($List[object]) throws "Argument types do not match" on Windows PowerShell 5.1.
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
            # Same proven invoke style as Get-SyncMeSnapshots (no ProcessStartInfo / ReadToEndAsync).
            $raw = & $resticExe ls $snapId $normPath --json 2>&1
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
                if ($msg -match '(?i)invalid child node name') {
                    $msg = 'Windows restic rejected UNC path nodes in this snapshot. Run a new backup, then browse that snapshot.'
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

function Test-SyncMeRestoreDrill {
    <#
      Advisory restore drill: dump up to 3 random files from the latest snapshot and verify bytes.
      Uses restic dump (not restore --include) to avoid Windows UNC-root restore failures.
      Returns Ok / Skipped / Message. Callers must not fail the overall backup job on Ok=$false.
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
                $msg = "Restore drill OK: snapshot=$snapId path=$pick size=$len (restic dump)"
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
                }
            } catch {
                $lastErr = "restic dump failed for path='$pick': $($_.Exception.Message)"
            }
        }

        throw "Restore drill failed after $attempts dump attempt(s). Last: $lastErr"
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
