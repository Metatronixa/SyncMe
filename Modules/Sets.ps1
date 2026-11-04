#Requires -Version 5.1
<#
.SYNOPSIS
  Multi backup-set helpers for SyncMe.
  Preferred store: Config\sets.json (no passwords). Legacy: Config.ps1 (read-only fallback).
#>

function Get-SyncMeSetsJsonPath {
    param([string]$ScriptRoot)
    return (Join-Path $ScriptRoot 'Config\sets.json')
}

function Test-SyncMeSecretPropertyName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $n = $Name.ToLowerInvariant()
    if ($n -match 'password|secret|credentialblob|accesstoken|refreshtoken|apikey|clientsecret|plainpass') {
        # Credential *names* (e.g. ResticCredentialName) are OK — values that look like secrets are not.
        if ($n -match 'credentialname|credentialtarget') { return $false }
        return $true
    }
    return $false
}

function ConvertTo-SyncMeSetJsonObject {
    param($Set)
    $norm = ConvertTo-SyncMeSetObject -Config $Set -Id $(if ($Set.Id) { $Set.Id } else { 'set1' }) `
        -DisplayName $(if ($Set.DisplayName) { $Set.DisplayName } else { 'Backup set 1' })
    $out = [ordered]@{}
    foreach ($p in $norm.PSObject.Properties) {
        if (Test-SyncMeSecretPropertyName -Name $p.Name) { continue }
        $out[$p.Name] = $p.Value
    }
    return [pscustomobject]$out
}

function Get-SyncMeSetsFromJsonFile {
    param([string]$ScriptRoot)
    $path = Get-SyncMeSetsJsonPath -ScriptRoot $ScriptRoot
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
        $list = @()
        if ($doc.PSObject.Properties.Name -contains 'sets') {
            $list = @($doc.sets)
        } elseif ($doc -is [System.Array]) {
            $list = @($doc)
        }
        $out = foreach ($s in $list) {
            if (-not $s) { continue }
            ConvertTo-SyncMeSetObject -Config $s -Id $(if ($s.Id) { $s.Id } else { 'set1' }) `
                -DisplayName $(if ($s.DisplayName) { $s.DisplayName } else { 'Backup set 1' })
        }
        return @($out)
    } catch {
        throw "Failed to read Config\sets.json: $($_.Exception.Message)"
    }
}

function Get-SyncMeSetsFromLegacyConfigPs1 {
    param([string]$ScriptRoot)
    $cfgPath = Join-Path $ScriptRoot 'Config.ps1'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return @() }

    . $cfgPath

    if (Get-Variable -Name BackupSets -Scope Script -ErrorAction SilentlyContinue) {
        if ($script:BackupSets -and @($script:BackupSets).Count -gt 0) {
            return @($script:BackupSets)
        }
    }

    if (Get-Command Get-BackupConfig -ErrorAction SilentlyContinue) {
        $c = Get-BackupConfig
        if ($c) {
            return @(ConvertTo-SyncMeSetObject -Config $c -Id 'set1' -DisplayName 'Backup set 1')
        }
    }
    return @()
}

function Get-SyncMeSetsFromConfigFile {
    param([string]$ScriptRoot)

    $jsonSets = @(Get-SyncMeSetsFromJsonFile -ScriptRoot $ScriptRoot)
    if ($jsonSets.Count -gt 0) { return $jsonSets }

    return @(Get-SyncMeSetsFromLegacyConfigPs1 -ScriptRoot $ScriptRoot)
}

function Save-SyncMeSetsConfig {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sets
    )
    $dir = Join-Path $ScriptRoot 'Config'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $path = Get-SyncMeSetsJsonPath -ScriptRoot $ScriptRoot
    if (Test-Path -LiteralPath $path) {
        $bak = Join-Path $dir ("sets.json.bak-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $path -Destination $bak -Force
    }

    $clean = @(foreach ($s in @($Sets)) { ConvertTo-SyncMeSetJsonObject -Set $s })
    $doc = [ordered]@{
        schemaVersion = 3
        updatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        sets          = @($clean)
    }
    $json = ($doc | ConvertTo-Json -Depth 8)
    [IO.File]::WriteAllText($path, ($json + "`r`n"), (New-Object System.Text.UTF8Encoding $false))

    # Keep a tiny legacy Config.ps1 pointer so old docs / rescue still find something.
    $legacy = Join-Path $ScriptRoot 'Config.ps1'
    $pointer = @"
#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe legacy pointer. Backup sets live in Config\sets.json (no passwords).
  Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'). Do not store passwords here.
#>
# Sets are loaded from Config\sets.json via Modules\Sets.ps1 (Get-SyncMeSetsFromConfigFile).
`$script:BackupSets = @()
`$script:BackupConfig = `$null
function Get-BackupConfig { return `$null }
function Get-BackupSets { return @() }
"@
    if (Test-Path -LiteralPath $legacy) {
        $legacyBak = Join-Path $ScriptRoot ("Config.ps1.bak-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        # Only backup if it still looks like a real multi-set file (not already a pointer)
        $head = ''
        try { $head = Get-Content -LiteralPath $legacy -TotalCount 8 -ErrorAction SilentlyContinue | Out-String } catch { }
        if ($head -notmatch 'sets\.json') {
            Copy-Item -LiteralPath $legacy -Destination $legacyBak -Force -ErrorAction SilentlyContinue
        }
    }
    [IO.File]::WriteAllText($legacy, $pointer, (New-Object System.Text.UTF8Encoding $true))
}

function ConvertTo-SyncMeSetObject {
    param($Config, [string]$Id = 'set1', [string]$DisplayName = 'Backup set 1')

    $obj = [ordered]@{}
    foreach ($p in $Config.PSObject.Properties) {
        $obj[$p.Name] = $p.Value
    }
    if (-not $obj.Contains('Id')) { $obj['Id'] = $Id }
    if (-not $obj.Contains('DisplayName')) { $obj['DisplayName'] = $DisplayName }
    if (-not $obj.Contains('NetworkMode')) { $obj['NetworkMode'] = 'both' }
    if (-not $obj.Contains('DestinationType')) { $obj['DestinationType'] = 'local' }
    if (-not $obj.Contains('RunTime')) { $obj['RunTime'] = '01:00' }
    if (-not $obj.Contains('ScheduleStartDate')) { $obj['ScheduleStartDate'] = (Get-Date).ToString('yyyy-MM-dd') }
    if (-not $obj.Contains('ScheduleRecurrence')) { $obj['ScheduleRecurrence'] = 'Daily' }
    if (-not $obj.Contains('ScheduleEndDate')) { $obj['ScheduleEndDate'] = '' }
    if (-not $obj.Contains('ScheduleDaysOfWeek')) { $obj['ScheduleDaysOfWeek'] = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday') }
    if (-not $obj.Contains('EnableToastNotifications')) { $obj['EnableToastNotifications'] = $false }
    if (-not $obj.Contains('EnableEmailNotifications')) { $obj['EnableEmailNotifications'] = $false }
    if (-not $obj.Contains('SmtpServer')) { $obj['SmtpServer'] = '' }
    if (-not $obj.Contains('SmtpPort')) { $obj['SmtpPort'] = 587 }
    if (-not $obj.Contains('SmtpUseSsl')) { $obj['SmtpUseSsl'] = $true }
    if (-not $obj.Contains('MailFrom')) { $obj['MailFrom'] = '' }
    if (-not $obj.Contains('MailTo')) { $obj['MailTo'] = @() }
    if (-not $obj.Contains('ShareCredentialName')) { $obj['ShareCredentialName'] = '' }
    if (-not $obj.Contains('ResticCredentialName')) { $obj['ResticCredentialName'] = 'SyncMeRestic' }
    if (-not $obj.Contains('ResticAdminCredentialName')) { $obj['ResticAdminCredentialName'] = '' }
    if (-not $obj.Contains('ResticPath')) { $obj['ResticPath'] = 'restic' }
    if (-not $obj.Contains('SourceHost')) { $obj['SourceHost'] = '' }
    if (-not $obj.Contains('ResticRepo')) { $obj['ResticRepo'] = '' }
    if (-not $obj.Contains('ArchivePath')) { $obj['ArchivePath'] = '' }
    if (-not $obj.Contains('EnableWakeOnLan')) { $obj['EnableWakeOnLan'] = $false }
    if (-not $obj.Contains('WakeMacAddress')) { $obj['WakeMacAddress'] = '' }
    if (-not $obj.Contains('UseShadowCopySources')) { $obj['UseShadowCopySources'] = $true }
    if (-not $obj.Contains('KeepLast')) { $obj['KeepLast'] = 7 }
    if (-not $obj.Contains('KeepDaily')) { $obj['KeepDaily'] = 14 }
    if (-not $obj.Contains('KeepWeekly')) { $obj['KeepWeekly'] = 8 }
    if (-not $obj.Contains('KeepMonthly')) { $obj['KeepMonthly'] = 6 }
    if (-not $obj.Contains('EnableRepoCheck')) { $obj['EnableRepoCheck'] = $true }
    if (-not $obj.Contains('WeeklyDataCheckDay')) { $obj['WeeklyDataCheckDay'] = 'Sunday' }
    if (-not $obj.Contains('ResticLimitUploadKByte')) { $obj['ResticLimitUploadKByte'] = 0 }
    if (-not $obj.Contains('RclonePath')) { $obj['RclonePath'] = '' }
    if (-not $obj.Contains('RcloneConfigPath')) { $obj['RcloneConfigPath'] = '' }
    if (-not $obj.Contains('RcloneBwLimit')) { $obj['RcloneBwLimit'] = 'off' }
    if (-not $obj.Contains('RcloneTransfers')) { $obj['RcloneTransfers'] = 4 }
    if (-not $obj.Contains('RcloneCheckers')) { $obj['RcloneCheckers'] = 8 }
    if (-not $obj.Contains('RcloneRetries')) { $obj['RcloneRetries'] = 3 }
    if (-not $obj.Contains('RcloneLowLevelRetries')) { $obj['RcloneLowLevelRetries'] = 10 }
    if (-not $obj.Contains('RcloneMultiThreadStreams')) { $obj['RcloneMultiThreadStreams'] = 4 }
    if (-not $obj.Contains('AppendOnly')) { $obj['AppendOnly'] = $false }
    if (-not $obj.Contains('FailJobOnRestoreDrillFailure')) { $obj['FailJobOnRestoreDrillFailure'] = $false }
    if (-not $obj.Contains('PreBackupScript')) { $obj['PreBackupScript'] = '' }
    if (-not $obj.Contains('PostBackupScript')) { $obj['PostBackupScript'] = '' }
    $sid = if ($obj.Contains('Id') -and $obj['Id']) { [string]$obj['Id'] } else { $Id }
    if (-not $obj.Contains('ReportsDir')) { $obj['ReportsDir'] = 'Reports' }
    if (-not $obj.Contains('LogsDir')) { $obj['LogsDir'] = ("Logs\sets\{0}" -f $sid) }
    if (-not $obj.Contains('ArchiveStampFile')) { $obj['ArchiveStampFile'] = ("Logs\sets\{0}\last-archive-utc.txt" -f $sid) }
    if (-not $obj.Contains('LastSuccessStampFile')) { $obj['LastSuccessStampFile'] = ("Logs\sets\{0}\last-success-utc.txt" -f $sid) }
    if (-not $obj.Contains('BackupLockFile')) { $obj['BackupLockFile'] = ("Logs\sets\{0}\backup.lock" -f $sid) }
    if (-not $obj.Contains('SnapshotTags')) { $obj['SnapshotTags'] = @('syncme', $sid) }
    if (-not $obj.Contains('ShareDriveLetter')) { $obj['ShareDriveLetter'] = '' }
    if (-not $obj.Contains('RequireSourceReachable')) { $obj['RequireSourceReachable'] = $true }
    if (-not $obj.Contains('ToastAppId')) { $obj['ToastAppId'] = 'SyncMe' }
    if (-not $obj.Contains('ArchiveEveryDays')) { $obj['ArchiveEveryDays'] = 14 }
    if (-not $obj.Contains('ClearArchiveBeforeRestore')) { $obj['ClearArchiveBeforeRestore'] = $true }
    if (-not $obj.Contains('MinFreeRepoGb')) { $obj['MinFreeRepoGb'] = 5 }
    if (-not $obj.Contains('MinFreeArchiveGb')) { $obj['MinFreeArchiveGb'] = 10 }
    if (-not $obj.Contains('SourcePaths')) { $obj['SourcePaths'] = @() }
    $obj['ExcludePatterns'] = @(Merge-SyncMeExcludePatterns -Existing $(if ($obj.Contains('ExcludePatterns')) { @($obj['ExcludePatterns']) } else { @() }))
    return [pscustomobject]$obj
}

function Get-SyncMeDefaultExcludePatterns {
    <#
      Office junk + Windows system paths that deny access on drive-root / $ share backups.
    #>
    return @(
        '~$*'
        '*.tmp'
        '*.temp'
        'Thumbs.db'
        'desktop.ini'
        '~*'
        '*.partial'
        '.DS_Store'
        'System Volume Information'
        '$Recycle.Bin'
        'Recovery'
        'pagefile.sys'
        'hiberfil.sys'
        'swapfile.sys'
    )
}

function Merge-SyncMeExcludePatterns {
    param([string[]]$Existing)
    $merged = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($p in @($Existing) + @(Get-SyncMeDefaultExcludePatterns)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $key = $p.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $merged.Add($p) | Out-Null
    }
    return @($merged)
}

function Get-SyncMeSetById {
    param([string]$ScriptRoot, [string]$SetId)

    $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    if ($sets.Count -eq 0) { return $null }
    if ([string]::IsNullOrWhiteSpace($SetId)) { return $sets[0] }
    $hit = $sets | Where-Object { $_.Id -eq $SetId } | Select-Object -First 1
    if ($hit) { return $hit }
    return $sets[0]
}

function Get-SyncMeDiskSpace {
    param([string]$Path)
    <#
      Returns @{ freeGb; totalGb; percentFree } or $null for cloud/unavailable paths.
      Get-SyncMeFreeGb remains as a thin wrapper for callers that only need free GB.
    #>
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($Path -match '^rclone:') { return $null }
    try {
        $target = $Path
        if ($Path -match '^\\\\') {
            $parts = $Path.TrimStart('\').Split('\')
            if ($parts.Count -ge 2) {
                $target = '\\{0}\{1}' -f $parts[0], $parts[1]
            }
        } else {
            $root = [IO.Path]::GetPathRoot($Path)
            if ($root) { $target = $root }
        }
        $free = $null
        $total = $null
        $drive = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $target.StartsWith($_.Root, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
        if ($drive -and $null -ne $drive.Free) {
            $free = [double]$drive.Free
            if ($null -ne $drive.Used) { $total = [double]$drive.Free + [double]$drive.Used }
        }
        if ($null -eq $free) {
            $item = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
            if ($item) {
                $d = Get-PSDrive -Name $item.PSDrive.Name -ErrorAction SilentlyContinue
                if ($d -and $null -ne $d.Free) {
                    $free = [double]$d.Free
                    if ($null -ne $d.Used) { $total = [double]$d.Free + [double]$d.Used }
                }
            }
        }
        if ($null -eq $free) { return $null }
        $freeGb = [math]::Round($free / 1GB, 1)
        $totalGb = if ($null -ne $total -and $total -gt 0) { [math]::Round($total / 1GB, 1) } else { $null }
        $pct = if ($null -ne $total -and $total -gt 0) { [math]::Round(($free / $total) * 100, 1) } else { $null }
        return @{
            freeGb      = $freeGb
            totalGb     = $totalGb
            percentFree = $pct
        }
    } catch { }
    return $null
}

function Get-SyncMeFreeGb {
    param([string]$Path)
    $info = Get-SyncMeDiskSpace -Path $Path
    if ($null -eq $info) { return $null }
    return $info.freeGb
}

function Write-SyncMeLastRun {
    param(
        [string]$ScriptRoot,
        [string]$SetId,
        [hashtable]$RunInfo
    )
    $logs = Join-Path $ScriptRoot 'Logs'
    if (-not (Test-Path -LiteralPath $logs)) {
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
    }
    $setDir = Join-Path $logs ("sets\" + $(if ($SetId) { $SetId } else { 'set1' }))
    if (-not (Test-Path -LiteralPath $setDir)) {
        New-Item -ItemType Directory -Path $setDir -Force | Out-Null
    }
    $payload = @{
        setId               = $SetId
        success             = [bool]$RunInfo.Success
        summary             = [string]$RunInfo.Summary
        startTime           = [string]$RunInfo.StartTime
        endTime             = [string]$RunInfo.EndTime
        snapshotId          = [string]$RunInfo.SnapshotId
        filesNew            = [string]$RunInfo.FilesNew
        filesChanged        = [string]$RunInfo.FilesChanged
        filesUnmodified     = [string]$RunInfo.FilesUnmodified
        dataAdded           = [string]$RunInfo.DataAdded
        totalBytesProcessed = [string]$RunInfo.TotalBytesProcessed
        backupExitCode      = [string]$RunInfo.BackupExitCode
        archiveStatus       = [string]$RunInfo.ArchiveStatus
        sourceMode          = [string]$RunInfo.SourceMode
        openFileRisk        = [string]$RunInfo.OpenFileRisk
        warnings            = @(Get-SyncMeRealErrors -Errors $RunInfo.Errors)
        logPath             = [string]$RunInfo.LogPath
        lastRestoreDrillSuccess = $(if ($RunInfo.ContainsKey('LastRestoreDrillSuccess')) { [bool]$RunInfo.LastRestoreDrillSuccess } else { $null })
        lastRestoreDrillDate    = [string]$RunInfo.LastRestoreDrillDate
        lastRestoreDrillDetail  = [string]$RunInfo.LastRestoreDrillDetail
        updatedUtc          = (Get-Date).ToUniversalTime().ToString('o')
    }
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    Set-Content -LiteralPath (Join-Path $setDir 'last-run.json') -Value $json -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $logs 'last-run.json') -Value $json -Encoding UTF8
}

function Read-SyncMeLastRun {
    param(
        [string]$ScriptRoot,
        [string]$SetId
    )
    $candidates = @()
    if ($SetId) {
        $candidates += (Join-Path $ScriptRoot ("Logs\sets\$SetId\last-run.json"))
    }
    $candidates += (Join-Path $ScriptRoot 'Logs\last-run.json')
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            try {
                return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
            } catch { }
        }
    }
    return $null
}

function Write-SyncMeLiveProgress {
    param(
        [string]$ScriptRoot,
        [string]$SetId,
        [string]$Phase,
        [string]$Message,
        [string]$RunId,
        [string]$JsonLog,
        $Percent = $null,
        $BytesDone = $null,
        $TotalBytes = $null,
        $FilesDone = $null,
        $TotalFiles = $null,
        [string]$Detail = '',
        [string]$ProgressMode = ''
    )
    $logs = Join-Path $ScriptRoot 'Logs'
    if (-not (Test-Path -LiteralPath $logs)) {
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
    }
    $obj = @{
        setId        = $SetId
        phase        = $Phase
        message      = $Message
        runId        = $RunId
        jsonLog      = $JsonLog
        updatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        percent      = $Percent
        bytesDone    = $BytesDone
        totalBytes   = $TotalBytes
        filesDone    = $FilesDone
        totalFiles   = $TotalFiles
        detail       = $Detail
        progressMode = $ProgressMode
    }
    $paths = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($SetId)) {
        $setDir = Join-Path $logs ("sets\" + $SetId)
        if (-not (Test-Path -LiteralPath $setDir)) {
            New-Item -ItemType Directory -Path $setDir -Force | Out-Null
        }
        [void]$paths.Add((Join-Path $setDir 'live-progress.json'))
    }
    [void]$paths.Add((Join-Path $logs 'live-progress.json'))
    $json = ($obj | ConvertTo-Json -Compress)
    foreach ($path in $paths) {
        try {
            Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -ErrorAction Stop
        } catch { }
    }
}

function Read-SyncMeLiveProgress {
    param(
        [string]$ScriptRoot,
        [string]$SetId = ''
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($SetId)) {
        [void]$candidates.Add((Join-Path $ScriptRoot ("Logs\sets\$SetId\live-progress.json")))
    }
    [void]$candidates.Add((Join-Path $ScriptRoot 'Logs\live-progress.json'))
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch { }
    }
    return $null
}

function Format-SyncMeBytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Get-SyncMeResticDestructiveCredentialTarget {
    <#
      Returns CM target for forget/prune/delete. Empty admin → fall back to backup write target (migration).
      Does not load the password. Backup path must never use the admin target.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$ScriptRoot = '',
        [switch]$AllowFallback
    )
    $writeName = if ($Config.ResticCredentialName) { [string]$Config.ResticCredentialName } else { 'SyncMeRestic' }
    $adminName = ''
    if ($Config.PSObject.Properties['ResticAdminCredentialName'] -and $Config.ResticAdminCredentialName) {
        $adminName = [string]$Config.ResticAdminCredentialName
    }
    $fallback = $false
    $sameAsWrite = $false
    if ([string]::IsNullOrWhiteSpace($adminName)) {
        if (-not $AllowFallback) {
            return [pscustomobject]@{
                TargetName   = ''
                Fallback     = $true
                SameAsWrite  = $true
                WriteTarget  = $writeName
                Warning      = 'ResticAdminCredentialName not set — configure a separate destructive CM target.'
            }
        }
        $adminName = $writeName
        $fallback = $true
        $sameAsWrite = $true
        if ($ScriptRoot) {
            try {
                Write-SyncMeStructuredLog -ScriptRoot $ScriptRoot -Level SECURITY -Message 'Destructive restic op falling back to backup credential (admin CM missing)' -Fields @{ writeTarget = $writeName }
            } catch { }
        }
    } elseif ($adminName -eq $writeName) {
        $sameAsWrite = $true
        if ($ScriptRoot) {
            try {
                Write-SyncMeStructuredLog -ScriptRoot $ScriptRoot -Level SECURITY -Message 'ResticAdminCredentialName equals ResticCredentialName (split keys recommended)' -Fields @{ target = $adminName }
            } catch { }
        }
    }
    return [pscustomobject]@{
        TargetName  = $adminName
        Fallback    = $fallback
        SameAsWrite = $sameAsWrite
        WriteTarget = $writeName
        Warning     = $(if ($sameAsWrite) { 'Admin credential matches backup write credential.' } else { '' })
    }
}

function Test-SyncMePathIsDriveRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '^rclone:') { return $false }
    $full = $Path.Trim().TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    $rootTrim = $root.TrimEnd('\', '/')
    return ($full.Equals($rootTrim, [StringComparison]::OrdinalIgnoreCase) -or $full -match '^[A-Za-z]:$')
}

function Test-SyncMeResticRepoPathSafe {
    <#
      Refuse restic repository at a drive root (e.g. D:\) — use a dedicated subfolder.
    #>
    param([string]$ResticRepo)
    if ([string]::IsNullOrWhiteSpace($ResticRepo)) {
        return @{ Ok = $false; Message = 'Restic repository path is required.' }
    }
    if ($ResticRepo -match '^rclone:') {
        return @{ Ok = $true; Message = '' }
    }
    if (Test-SyncMePathIsDriveRoot -Path $ResticRepo) {
        return @{
            Ok = $false
            Message = "Restic repository cannot be a drive root ($ResticRepo). Choose a dedicated subfolder (e.g. D:\Backups\SyncMe)."
        }
    }
    return @{ Ok = $true; Message = '' }
}

function Test-SyncMeArchivePathSafe {
    <#
      Refuse ArchivePath that is a drive root (e.g. E:\) - ClearArchiveBeforeRestore would wipe the volume.
    #>
    param([string]$ArchivePath)
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
        return @{ Ok = $true; Message = '' }
    }
    if (Test-SyncMePathIsDriveRoot -Path $ArchivePath) {
        return @{
            Ok = $false
            Message = "ArchivePath cannot be a drive root ($ArchivePath). Use a dedicated subfolder (e.g. E:\SyncMeArchive\UserA) - SyncMe deletes the folder contents before each plain archive."
        }
    }
    return @{ Ok = $true; Message = '' }
}
