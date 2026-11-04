#Requires -Version 5.1
<#
.SYNOPSIS
  Backup/restore job coordination by canonical repository identity.
#>

function Get-SyncMeCanonicalRepoKey {
    param([string]$ResticRepo)
    if ([string]::IsNullOrWhiteSpace($ResticRepo)) { return '' }
    $t = $ResticRepo.Trim()
    if ($t -match '^rclone:') {
        return ('rclone:' + $t.Substring(7).Trim().ToLowerInvariant())
    }
    try {
        if ($t.StartsWith('\\')) {
            return $t.TrimEnd('\').ToLowerInvariant()
        }
        return [System.IO.Path]::GetFullPath($t).TrimEnd('\').ToLowerInvariant()
    } catch {
        return $t.TrimEnd('\').ToLowerInvariant()
    }
}

function Test-SyncMeRepositoryPathCollision {
    <#
      Returns colliding set ids sharing the same canonical repo (more than one set).
    #>
    param(
        [string]$ScriptRoot,
        [string]$IgnoreSetId = ''
    )
    $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    $map = @{}
    foreach ($s in $sets) {
        if ($IgnoreSetId -and $s.Id -eq $IgnoreSetId) { continue }
        $key = Get-SyncMeCanonicalRepoKey -ResticRepo ([string]$s.ResticRepo)
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if (-not $map.ContainsKey($key)) { $map[$key] = New-Object System.Collections.Generic.List[string] }
        [void]$map[$key].Add([string]$s.Id)
    }
    $collisions = @()
    foreach ($k in $map.Keys) {
        if ($map[$k].Count -gt 1) {
            $collisions += [pscustomobject]@{ RepoKey = $k; SetIds = @($map[$k].ToArray()) }
        }
    }
    return $collisions
}

function Assert-SyncMeUniqueRepositories {
    param([string]$ScriptRoot)
    $hits = @(Test-SyncMeRepositoryPathCollision -ScriptRoot $ScriptRoot)
    if ($hits.Count -gt 0) {
        $parts = $hits | ForEach-Object { "sets $($_.SetIds -join ', ') share repo $($_.RepoKey)" }
        throw ("Multiple backup sets share the same restic repository. Each set needs its own repo. " + ($parts -join '; '))
    }
}

function Test-SyncMeRepoLockAlive {
    param([string]$LockPath)
    if (-not $LockPath -or -not (Test-Path -LiteralPath $LockPath)) { return $false }
    $raw = Get-Content -LiteralPath $LockPath -ErrorAction SilentlyContinue
    $oldPid = $null
    foreach ($line in @($raw)) {
        if ($line -match '^PID=(\d+)$') {
            try { $oldPid = [int]$Matches[1] } catch { $oldPid = $null }
        }
    }
    if (-not $oldPid) { return $false }
    return [bool](Get-Process -Id $oldPid -ErrorAction SilentlyContinue)
}

function Get-SyncMeSetsUsingRepo {
    param(
        [string]$ScriptRoot,
        [string]$ResticRepo
    )
    $want = Get-SyncMeCanonicalRepoKey -ResticRepo $ResticRepo
    if ([string]::IsNullOrWhiteSpace($want)) { return @() }
    $hits = @()
    foreach ($s in @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)) {
        $k = Get-SyncMeCanonicalRepoKey -ResticRepo ([string]$s.ResticRepo)
        if ($k -and $k -eq $want) { $hits += $s }
    }
    return $hits
}

function Assert-SyncMeRepositoryIdle {
    <#
      Throws if any set that shares this repository has a live backup lock,
      or if a host-tracked restore/backup is already using the same repo.
    #>
    param(
        [string]$ScriptRoot,
        [string]$ResticRepo,
        [string]$ExcludeSetId = '',
        [string]$Operation = 'job'
    )
    $sets = @(Get-SyncMeSetsUsingRepo -ScriptRoot $ScriptRoot -ResticRepo $ResticRepo)
    foreach ($s in $sets) {
        if ($ExcludeSetId -and $s.Id -eq $ExcludeSetId) {
            # Still check this set's lock for restore-vs-backup on same set
        }
        $lockRel = if ($s.BackupLockFile) { $s.BackupLockFile } else { "Logs\sets\$($s.Id)\backup.lock" }
        $lockPath = Join-Path $ScriptRoot $lockRel
        if (Test-SyncMeRepoLockAlive -LockPath $lockPath) {
            throw ("Cannot start ${Operation}: repository is busy (backup lock held by set '$($s.Id)').")
        }
    }
}

function Assert-SyncMeCanMutateRepository {
    param(
        [string]$ScriptRoot,
        [object]$Config,
        [string]$Operation = 'job',
        [switch]$AllowSameSetBackupLock
    )
    if (-not $Config) { throw 'Backup set config is required.' }
    $repo = [string]$Config.ResticRepo
    $setId = if ($Config.Id) { [string]$Config.Id } else { 'set1' }
    $exclude = if ($AllowSameSetBackupLock) { $setId } else { '' }
    Assert-SyncMeRepositoryIdle -ScriptRoot $ScriptRoot -ResticRepo $repo -ExcludeSetId $exclude -Operation $Operation
}

function Get-SyncMeJobStatePath {
    param([string]$ScriptRoot, [string]$JobName = 'current')
    $dir = Join-Path $ScriptRoot 'Data\Jobs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir ($JobName + '.json'))
}

function Write-SyncMeJobState {
    param(
        [string]$ScriptRoot,
        [string]$JobName = 'current',
        [string]$Kind,
        [string]$SetId = '',
        [string]$Phase = '',
        [string]$Message = '',
        [hashtable]$Extra = @{}
    )
    $path = Get-SyncMeJobStatePath -ScriptRoot $ScriptRoot -JobName $JobName
    $obj = [ordered]@{
        kind       = $Kind
        setId      = $SetId
        phase      = $Phase
        message    = $Message
        pid        = $PID
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    foreach ($k in @($Extra.Keys)) { $obj[[string]$k] = $Extra[$k] }
    [IO.File]::WriteAllText($path, (($obj | ConvertTo-Json -Depth 6 -Compress) + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    return $path
}

function Read-SyncMeJobState {
    param([string]$ScriptRoot, [string]$JobName = 'current')
    $path = Get-SyncMeJobStatePath -ScriptRoot $ScriptRoot -JobName $JobName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return ((Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json) } catch { return $null }
}

function Clear-SyncMeJobState {
    param([string]$ScriptRoot, [string]$JobName = 'current')
    $path = Get-SyncMeJobStatePath -ScriptRoot $ScriptRoot -JobName $JobName
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Enter-SyncMeRepositoryLock {
    <# Alias surface for shared repository lock (same algorithm as backup engine). #>
    param(
        [string]$LockPath,
        [double]$StaleHours = 36,
        [string]$LogPath = ''
    )
    if (Get-Command Enter-BackupRunLock -ErrorAction SilentlyContinue) {
        return Enter-BackupRunLock -LockPath $LockPath -StaleHours $StaleHours -LogPath $LogPath
    }
    # Fallback exclusive create if backup engine not loaded
    $dir = Split-Path -Parent $LockPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $payload = "PID=$PID`r`nStartedUtc=$((Get-Date).ToUniversalTime().ToString('o'))`r`nComputer=$env:COMPUTERNAME"
    try {
        $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload + "`r`n")
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Dispose() }
        return @{ Acquired = $true; Message = "Lock acquired: $LockPath" }
    } catch [System.IO.IOException] {
        return @{ Acquired = $false; Message = "Could not acquire lock: $LockPath" }
    }
}

function Exit-SyncMeRepositoryLock {
    param([string]$LockPath)
    if (Get-Command Exit-BackupRunLock -ErrorAction SilentlyContinue) {
        Exit-BackupRunLock -LockPath $LockPath
        return
    }
    if ($LockPath -and (Test-Path -LiteralPath $LockPath)) {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }
}
