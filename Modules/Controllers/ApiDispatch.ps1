#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe API dispatch (controllers). Invoked by the dumb Host listener via Router fallback.
#>

function Invoke-SyncMeApiDispatch {
    param(
        $Request,
        $Response,
        [string]$ScriptRoot,
        [int]$Port,
        [string]$CsrfToken,
        $Listener = $null
    )
    $req = $Request
    $res = $Response
    $path = $req.Url.AbsolutePath

            if ($path -eq '/api/status' -and $req.HttpMethod -eq 'GET') {
                $qSet = $req.QueryString['setId']
                $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
                $cfg = if ($qSet) { Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $qSet } else { Get-SyncMeConfigOrNull }
                $netMode = if ($cfg -and $cfg.NetworkMode) { [string]$cfg.NetworkMode } else { 'both' }
                if ($netMode -eq 'lan') {
                    $ts = @{ Ok = $true; Message = 'Skipped (LAN-only set)'; Detail = 'NetworkMode=lan' }
                } else {
                    $ts = Test-MonarchTailscale
                }
                $restic = Get-ResticOnPath
                $stamp = ''
                if ($cfg -and $cfg.LastSuccessStampFile) {
                    $stampPath = Join-Path $ScriptRoot $cfg.LastSuccessStampFile
                    if (Test-Path $stampPath) { $stamp = (Get-Content $stampPath -Raw).Trim() }
                }
                if (-not $stamp) {
                    $stampPath = Join-Path $ScriptRoot 'Logs\last-success-utc.txt'
                    if (Test-Path $stampPath) { $stamp = (Get-Content $stampPath -Raw).Trim() }
                }
                $lockAlive = $false
                $lockRel = if ($cfg -and $cfg.BackupLockFile) { $cfg.BackupLockFile } else { 'Logs\backup.lock' }
                $lockPath = Join-Path $ScriptRoot $lockRel
                if (Test-Path $lockPath) {
                    $raw = Get-Content $lockPath -ErrorAction SilentlyContinue
                    foreach ($line in $raw) {
                        if ($line -match '^PID=(\d+)$') {
                            $lockAlive = [bool](Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)
                        }
                    }
                }
                $defaultTarget = Join-Path $ScriptRoot ('Restores\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                if ($cfg) {
                    try { $defaultTarget = Get-SyncMeDefaultRestoreTarget -Config $cfg -ScriptRoot $ScriptRoot } catch { }
                }
                $setSummaries = @($sets | ForEach-Object {
                    @{
                        id                   = $_.Id
                        displayName          = $(if ($_.DisplayName) { $_.DisplayName } else { $_.Id })
                        runTime              = $(if ($_.RunTime) { $_.RunTime } else { '01:00' })
                        scheduleStartDate    = $(if ($_.ScheduleStartDate) { $_.ScheduleStartDate } else { '' })
                        scheduleRecurrence   = $(if ($_.ScheduleRecurrence) { $_.ScheduleRecurrence } else { 'Daily' })
                        scheduleEndDate      = $(if ($_.ScheduleEndDate) { $_.ScheduleEndDate } else { '' })
                        networkMode          = $(if ($_.NetworkMode) { $_.NetworkMode } else { 'both' })
                        destinationType      = $(if ($_.DestinationType) { $_.DestinationType } else { 'local' })
                    }
                })
                $disk1Info = if ($cfg) { Get-SyncMeDiskSpace -Path ([string]$cfg.ResticRepo) } else { $null }
                $disk2Info = if ($cfg) { Get-SyncMeDiskSpace -Path ([string]$cfg.ArchivePath) } else { $null }
                $rclone = Get-SyncMeRclone
                $lastRun = $null
                if ($cfg) {
                    $lastRun = Read-SyncMeLastRun -ScriptRoot $ScriptRoot -SetId $(if ($cfg.Id) { $cfg.Id } else { 'set1' })
                }
                $lowDisk = $false
                if ($disk1Info -and $null -ne $disk1Info.percentFree -and $disk1Info.percentFree -lt 15) { $lowDisk = $true }
                if ($disk2Info -and $null -ne $disk2Info.percentFree -and $disk2Info.percentFree -lt 15) { $lowDisk = $true }
                $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
                $showSkippedBanner = $false
                if ($cfg -and $lastRun) {
                    $showSkippedBanner = Test-SyncMeSkippedFilesBanner -ScriptRoot $ScriptRoot -SetId $(if ($cfg.Id) { $cfg.Id } else { 'set1' }) -LastRun $lastRun
                }
                Write-SyncMeJson @{
                    ok                   = $true
                    csrfToken            = $script:SyncMeCsrfToken
                    packageVersion       = (Get-SyncMePackageVersion)
                    updateFeedUrl        = [string]$opts.UpdateFeedUrl
                    monitorConfigured    = (-not [string]::IsNullOrWhiteSpace([string]$opts.MonitorUrl))
                    configured           = [bool](Test-SyncMeConfigured)
                    lastSuccess          = $stamp
                    lastRun              = $lastRun
                    skippedFilesBanner   = [bool]$showSkippedBanner
                    tailscaleOk          = [bool]$ts.Ok
                    tailscaleMessage     = $ts.Message
                    resticOk             = [bool]$restic.Ok
                    resticPath           = $restic.Path
                    rcloneOk             = [bool]$rclone.Ok
                    rclonePath           = $(if ($rclone.Ok) { $rclone.Path } else { '' })
                    backupRunning        = ($script:BackupJob.Running -or $lockAlive)
                    defaultRestoreTarget = $defaultTarget
                    archivePath          = $(if ($cfg) { $cfg.ArchivePath } else { '' })
                    resticRepo           = $(if ($cfg) { $cfg.ResticRepo } else { '' })
                    disk1FreeGb          = $(if ($disk1Info) { $disk1Info.freeGb } else { $null })
                    disk1TotalGb         = $(if ($disk1Info) { $disk1Info.totalGb } else { $null })
                    disk1PercentFree     = $(if ($disk1Info) { $disk1Info.percentFree } else { $null })
                    disk2FreeGb          = $(if ($disk2Info) { $disk2Info.freeGb } else { $null })
                    disk2TotalGb         = $(if ($disk2Info) { $disk2Info.totalGb } else { $null })
                    disk2PercentFree     = $(if ($disk2Info) { $disk2Info.percentFree } else { $null })
                    lowDisk              = $lowDisk
                    sets                 = $setSummaries
                    activeSetId          = $(if ($cfg -and $cfg.Id) { $cfg.Id } elseif ($setSummaries.Count) { $setSummaries[0].id } else { 'set1' })
                    runTime              = $(if ($cfg -and $cfg.RunTime) { $cfg.RunTime } else { '01:00' })
                    scheduleStartDate    = $(if ($cfg -and $cfg.ScheduleStartDate) { $cfg.ScheduleStartDate } else { '' })
                    scheduleRecurrence   = $(if ($cfg -and $cfg.ScheduleRecurrence) { $cfg.ScheduleRecurrence } else { 'Daily' })
                    scheduleEndDate      = $(if ($cfg -and $cfg.ScheduleEndDate) { $cfg.ScheduleEndDate } else { '' })
                    scheduleDaysOfWeek   = $(if ($cfg -and $cfg.ScheduleDaysOfWeek) { @($cfg.ScheduleDaysOfWeek) } else { @() })
                    networkMode          = $(if ($cfg -and $cfg.NetworkMode) { $cfg.NetworkMode } else { 'both' })
                } -Response $res
        return $true
            }

            if ($path -eq '/api/prereqs' -and $req.HttpMethod -eq 'GET') {
                $cfg = Get-SyncMeConfigOrNull
                $netMode = if ($cfg -and $cfg.NetworkMode) { [string]$cfg.NetworkMode } else { 'both' }
                if ($netMode -eq 'lan') {
                    $ts = @{ Ok = $true; Message = 'Skipped (LAN-only)'; Detail = 'NetworkMode=lan' }
                } else {
                    $ts = Test-MonarchTailscale
                }
                $restic = Get-ResticOnPath
                $rclone = Get-SyncMeRclone
                $winfsp = Test-SyncMeWinFsp
                Write-SyncMeJson @{
                    ok               = $true
                    tailscaleOk      = [bool]$ts.Ok
                    tailscaleMessage = $ts.Message
                    resticOk         = [bool]$restic.Ok
                    resticPath       = $(if ($restic.Ok) { $restic.Path } else { 'restic' })
                    rcloneOk         = [bool]$rclone.Ok
                    rclonePath       = $(if ($rclone.Ok) { $rclone.Path } else { '' })
                    winfspOk         = [bool]$winfsp.Ok
                    winfspMessage    = $winfsp.Message
                    winfspUrl        = $(if ($winfsp.Url) { $winfsp.Url } else { 'https://winfsp.dev/rel/' })
                } -Response $res
        return $true
            }

            if ($path -eq '/api/update/check' -and $req.HttpMethod -eq 'GET') {
                try {
                    $info = Get-SyncMeUpdateInfo -ScriptRoot $ScriptRoot -CurrentVersion (Get-SyncMePackageVersion)
                    Write-SyncMeJson @{
                        ok              = $true
                        updateAvailable = [bool]$info.UpdateAvailable
                        currentVersion  = $info.CurrentVersion
                        version         = $info.Version
                        file            = $info.File
                        url             = $info.Url
                        notes           = $info.Notes
                        feedUrl         = $info.FeedUrl
                        signed          = [bool]$info.Signed
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{
                        ok              = $false
                        updateAvailable = $false
                        message         = $_.Exception.Message
                        currentVersion  = (Get-SyncMePackageVersion)
                    } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/update/install' -and $req.HttpMethod -eq 'POST') {
                try {
                    $info = Get-SyncMeUpdateInfo -ScriptRoot $ScriptRoot -CurrentVersion (Get-SyncMePackageVersion)
                    if (-not $info.UpdateAvailable) {
                        Write-SyncMeJson @{
                            ok      = $false
                            message = "Already on latest version ($($info.CurrentVersion))."
                        } -StatusCode 400 -Response $res
        return $true
                    }
                    $result = Start-SyncMeUpdateApply -ScriptRoot $ScriptRoot -UpdateInfo $info
                    Write-SyncMeJson @{
                        ok      = $true
                        signed  = [bool]$result.Signed
                        message = $result.Message
                        version = $result.Version
                        backup  = $result.Backup
                        restart = $true
                    } -Response $res
                    $psExit = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    Start-Process -FilePath $psExit -ArgumentList @(
                        '-NoProfile',
                        '-Command', "Start-Sleep -Seconds 2; Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue"
                    ) -WindowStyle Hidden | Out-Null
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/options' -and $req.HttpMethod -eq 'GET') {
                $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
                Write-SyncMeJson @{
                    ok              = $true
                    updateFeedUrl   = [string]$opts.UpdateFeedUrl
                    monitorUrl      = [string]$opts.MonitorUrl
                    monitorSiteId   = [string]$opts.MonitorSiteId
                    monitorToken    = [string]$opts.MonitorToken
                    localOpsUrl     = [string]$opts.LocalOpsUrl
                    localOpsEnabled = [bool]$opts.LocalOpsEnabled
                } -Response $res
        return $true
            }

            if ($path -eq '/api/options' -and $req.HttpMethod -eq 'POST') {
                try {
                    $body = Read-SyncMeBody $req
                    if ($null -eq $body) {
                        throw 'Request body is required (JSON with monitor / LocalOps fields).'
                    }
                    $propNames = @($body.PSObject.Properties | ForEach-Object { $_.Name })
                    $saveArgs = @{ ScriptRoot = $ScriptRoot }
                    if ($propNames -contains 'updateFeedUrl') { $saveArgs.UpdateFeedUrl = [string]$body.updateFeedUrl }
                    if ($propNames -contains 'monitorUrl') { $saveArgs.MonitorUrl = [string]$body.monitorUrl }
                    if ($propNames -contains 'monitorSiteId') { $saveArgs.MonitorSiteId = [string]$body.monitorSiteId }
                    if ($propNames -contains 'monitorToken') { $saveArgs.MonitorToken = [string]$body.monitorToken }
                    if ($propNames -contains 'localOpsUrl') { $saveArgs.LocalOpsUrl = [string]$body.localOpsUrl }
                    if ($propNames -contains 'localOpsEnabled') { $saveArgs.LocalOpsEnabled = $body.localOpsEnabled }
                    if (
                        -not $saveArgs.ContainsKey('UpdateFeedUrl') -and
                        -not $saveArgs.ContainsKey('MonitorUrl') -and
                        -not $saveArgs.ContainsKey('MonitorSiteId') -and
                        -not $saveArgs.ContainsKey('MonitorToken') -and
                        -not $saveArgs.ContainsKey('LocalOpsUrl') -and
                        -not $saveArgs.ContainsKey('LocalOpsEnabled')
                    ) {
                        throw 'No options fields provided to save.'
                    }
                    $saved = Save-SyncMeOptions @saveArgs
                    $hb = $null
                    $loc = $null
                    # Dual-write test: MonitorUrl and/or LocalOps fleet (token + loopback LocalOps)
                    $wantHb = (-not [string]::IsNullOrWhiteSpace([string]$saved.MonitorUrl)) -or
                        (-not [string]::IsNullOrWhiteSpace([string]$saved.MonitorToken))
                    if ($wantHb) {
                        try {
                            $hb = Send-SyncMeMonitorTestHeartbeat -ScriptRoot $ScriptRoot
                        } catch {
                            $hb = @{ Ok = $false; Message = $_.Exception.Message }
                        }
                    }
                    if ([bool]$saved.LocalOpsEnabled) {
                        try {
                            $loc = Send-SyncMeLocalOpsTestRegister -ScriptRoot $ScriptRoot
                        } catch {
                            $loc = @{ Ok = $false; Message = $_.Exception.Message }
                        }
                    }
                    $msg = 'Options saved.'
                    $parts = @()
                    if ($hb) {
                        if ($hb.Ok) { $parts += 'Fleet heartbeat OK.' }
                        else { $parts += ('Fleet heartbeat failed: ' + [string]$hb.Message) }
                    }
                    if ($loc) {
                        if ($loc.Ok) { $parts += 'LocalOps register OK.' }
                        elseif ($loc.Skipped) { $parts += ('LocalOps skipped: ' + [string]$loc.Message) }
                        else { $parts += ('LocalOps register failed: ' + [string]$loc.Message) }
                    }
                    if ($parts.Count -gt 0) { $msg = 'Options saved. ' + ($parts -join ' ') }
                    Write-SyncMeJson @{
                        ok              = $true
                        message         = $msg
                        updateFeedUrl   = [string]$saved.UpdateFeedUrl
                        monitorUrl      = [string]$saved.MonitorUrl
                        monitorSiteId   = [string]$saved.MonitorSiteId
                        monitorToken    = [string]$saved.MonitorToken
                        localOpsUrl     = [string]$saved.LocalOpsUrl
                        localOpsEnabled = [bool]$saved.LocalOpsEnabled
                        heartbeatOk     = $(if ($hb) { [bool]$hb.Ok } else { $null })
                        heartbeatMsg    = $(if ($hb) { [string]$hb.Message } else { '' })
                        localOpsOk      = $(if ($loc) { [bool]$loc.Ok } else { $null })
                        localOpsMsg     = $(if ($loc) { [string]$loc.Message } else { '' })
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/options/ack-skipped-files' -and $req.HttpMethod -eq 'POST') {
                try {
                    $body = Read-SyncMeBody $req
                    $setId = if ($body -and $body.setId) { [string]$body.setId } else { 'set1' }
                    $updatedUtc = if ($body -and $body.updatedUtc) { [string]$body.updatedUtc } else { '' }
                    if ([string]::IsNullOrWhiteSpace($updatedUtc)) {
                        $lr = Read-SyncMeLastRun -ScriptRoot $ScriptRoot -SetId $setId
                        if ($lr -and $lr.updatedUtc) { $updatedUtc = [string]$lr.updatedUtc }
                    }
                    Set-SyncMeSkippedFilesAck -ScriptRoot $ScriptRoot -SetId $setId -UpdatedUtc $updatedUtc | Out-Null
                    Write-SyncMeJson @{ ok = $true; message = 'Skipped-files warning acknowledged.' } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/prereqs/install-restic' -and $req.HttpMethod -eq 'POST') {
                try {
                    $result = Install-SyncMeRestic
                    if ($result.Ok -and $result.Path) {
                        try {
                            $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
                            if ($sets.Count -gt 0) {
                                $updated = foreach ($s in $sets) {
                                    $s | Add-Member -NotePropertyName ResticPath -NotePropertyValue $result.Path -Force
                                    $s
                                }
                                Write-SyncMeSetsConfigFile -Sets @($updated)
                            }
                        } catch { }
                    }
                    Write-SyncMeJson @{
                        ok         = $true
                        resticOk   = [bool]$result.Ok
                        resticPath = $result.Path
                        message    = $result.Message
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{
                        ok         = $false
                        resticOk   = $false
                        resticPath = 'restic'
                        message    = $_.Exception.Message
                    } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/prereqs/install-rclone' -and $req.HttpMethod -eq 'POST') {
                try {
                    $result = Install-SyncMeRclone
                    Write-SyncMeJson @{
                        ok         = $true
                        rcloneOk   = [bool]$result.Ok
                        rclonePath = $result.Path
                        message    = $result.Message
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/prereqs/install-winfsp' -and $req.HttpMethod -eq 'POST') {
                try {
                    $result = Install-SyncMeWinFsp
                    Write-SyncMeJson @{
                        ok           = [bool]$result.Ok
                        winfspOk     = [bool]$result.Ok
                        winfspPath   = $result.Path
                        message      = $result.Message
                        winfspUrl    = 'https://winfsp.dev/rel/'
                    } -StatusCode $(if ($result.Ok) { 200 } else { 400 }) -Response $res
                } catch {
                    Write-SyncMeJson @{
                        ok       = $false
                        winfspOk = $false
                        message  = $_.Exception.Message
                        winfspUrl = 'https://winfsp.dev/rel/'
                    } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/test-source' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                $msgs = New-Object System.Collections.Generic.List[string]
                $hostName = ([string]$body.host).Trim()
                $paths = @([string]$body.paths -split '[\r\n,]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $hasUnc = [bool]($paths | Where-Object { $_ -match '^\\\\[^\\]+\\[^\\]+' })
                $allOk = $true
                if ($hasUnc -or $hostName) {
                    if ([string]::IsNullOrWhiteSpace($hostName)) {
                        $msgs.Add('Host name required when testing UNC paths.')
                        $allOk = $false
                    } else {
                        $ping = Test-Connection -ComputerName $hostName -Count 1 -Quiet -ErrorAction SilentlyContinue
                        $msgs.Add($(if ($ping) { "Host reachable: $hostName" } else { "Host NOT reachable: $hostName" }))
                        if (-not $ping) { $allOk = $false }
                    }
                } else {
                    $msgs.Add('Local source paths - skipping host ping.')
                }
                foreach ($pp in $paths) {
                    $ok = Test-Path -LiteralPath $pp
                    $msgs.Add($(if ($ok) { "Path OK: $pp" } else { "Path NOT reachable: $pp" }))
                    if (-not $ok) { $allOk = $false }
                }
                Write-SyncMeJson @{ ok = $true; allOk = $allOk; messages = @($msgs) } -Response $res
        return $true
            }

            if ($path -eq '/api/setup/apply' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $result = Invoke-SyncMeSetupApply -Body $body
                    Write-SyncMeJson @{
                        ok          = $true
                        message     = $result.message
                        setId       = $result.setId
                        displayName = $result.displayName
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/schedule' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Invoke-SyncMeScheduleUpdate -Body $body
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/backup' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                $mode = if ($body.mode) { [string]$body.mode } else { '' }
                $setId = if ($body.setId) { [string]$body.setId } else { 'set1' }
                try {
                    $msg = Start-SyncMeBackupJob -Mode $mode -SetId $setId
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/backup/status' -and $req.HttpMethod -eq 'GET') {
                $qSet = $req.QueryString['setId']
                Write-SyncMeJson (Get-SyncMeBackupStatusPayload -SetId $(if ($qSet) { [string]$qSet } else { '' })) -Response $res
        return $true
            }

            if ($path -eq '/api/snapshots' -and $req.HttpMethod -eq 'GET') {
                $qSet = $req.QueryString['setId']
                $cfg = if ($qSet) { Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $qSet } else { Get-SyncMeConfigOrNull }
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Not configured yet.' } -StatusCode 400 -Response $res
        return $true
                }
                try {
                    $tools = Join-Path $ScriptRoot 'tools'
                    if (Test-Path $tools) { $env:PATH = "$tools;$env:PATH" }
                    if ($cfg.RcloneConfigPath) { $env:RCLONE_CONFIG = [string]$cfg.RcloneConfigPath }
                    elseif (Test-Path (Get-SyncMeRcloneConfigPath)) { $env:RCLONE_CONFIG = Get-SyncMeRcloneConfigPath }
                    $snaps = @(Get-SyncMeSnapshots -Config $cfg)
                    Write-SyncMeJson @{ ok = $true; snapshots = $snaps; setId = $(if ($cfg.Id) { $cfg.Id } else { 'set1' }) } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                } finally {
                    Remove-Item Env:RCLONE_CONFIG -ErrorAction SilentlyContinue
                }
        return $true
            }

            if ($path -eq '/api/snapshot/ls' -and $req.HttpMethod -eq 'GET') {
                $qSet = $req.QueryString['setId']
                $qSnap = [string]$req.QueryString['snapshot']
                $qPathRaw = $req.QueryString['path']
                $qPath = if ($null -eq $qPathRaw) { '' } else { ([string]$qPathRaw).Trim() }
                $setId = if ($qSet) { [string]$qSet } else { 'set1' }
                $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $setId
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Not configured yet.' } -StatusCode 400 -Response $res
        return $true
                }
                if ([string]::IsNullOrWhiteSpace($qSnap)) {
                    Write-SyncMeJson @{ ok = $false; message = 'Query parameter snapshot is required.' } -StatusCode 400 -Response $res
        return $true
                }
                try {
                    Update-SyncMeBackupJob
                    Update-SyncMeRestoreJob
                    $bakStatus = Get-SyncMeBackupStatusPayload -SetId $setId
                    if ($bakStatus.running) {
                        Write-SyncMeJson @{
                            ok = $false
                            message = 'Cannot browse while a backup is running (restic repository lock). Wait for the backup to finish.'
                        } -StatusCode 409 -Response $res
        return $true
                    }
                    if ($script:RestoreJob.Running) {
                        Write-SyncMeJson @{
                            ok = $false
                            message = 'Cannot browse while a restore is running. Wait or cancel the restore first.'
                        } -StatusCode 409 -Response $res
        return $true
                    }

                    $tools = Join-Path $ScriptRoot 'tools'
                    if (Test-Path $tools) { $env:PATH = "$tools;$env:PATH" }
                    if ($cfg.RcloneConfigPath) { $env:RCLONE_CONFIG = [string]$cfg.RcloneConfigPath }
                    elseif (Test-Path (Get-SyncMeRcloneConfigPath)) { $env:RCLONE_CONFIG = Get-SyncMeRcloneConfigPath }

                    $listing = Get-SyncMeSnapshotListing `
                        -Config $cfg `
                        -Snapshot $qSnap `
                        -Path $qPath
                    if ($listing -is [System.Array]) {
                        $listing = @($listing) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Ok') } | Select-Object -Last 1
                    }
                    if (-not $listing) {
                        Write-SyncMeJson @{ ok = $false; message = 'Snapshot browse returned no result.' } -StatusCode 400 -Response $res
        return $true
                    }
                    if (-not $listing.Ok) {
                        Write-SyncMeJson @{
                            ok         = $false
                            message    = [string]$listing.Message
                            path       = [string]$listing.Path
                            entries    = @()
                            truncated  = $false
                            snapshotId = [string]$listing.SnapshotId
                        } -StatusCode 400 -Response $res
        return $true
                    }
                    Write-SyncMeJson @{
                        ok         = $true
                        message    = [string]$listing.Message
                        path       = [string]$listing.Path
                        entries    = @($listing.Entries)
                        truncated  = [bool]$listing.Truncated
                        snapshotId = [string]$listing.SnapshotId
                        setId      = $setId
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = ('Snapshot browse failed: ' + $_.Exception.Message) } -StatusCode 400 -Response $res
                } finally {
                    Remove-Item Env:RCLONE_CONFIG -ErrorAction SilentlyContinue
                }
        return $true
            }

            if ($path -eq '/api/restore' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                $setId = if ($body.setId) { [string]$body.setId } else { 'set1' }
                $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $setId
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Not configured yet.' } -StatusCode 400 -Response $res
        return $true
                }
                try {
                    $tools = Join-Path $ScriptRoot 'tools'
                    if (Test-Path $tools) { $env:PATH = "$tools;$env:PATH" }
                    if ($cfg.RcloneConfigPath) { $env:RCLONE_CONFIG = [string]$cfg.RcloneConfigPath }
                    elseif (Test-Path (Get-SyncMeRcloneConfigPath)) { $env:RCLONE_CONFIG = Get-SyncMeRcloneConfigPath }
                    $msg = Start-SyncMeRestoreJob `
                        -Config $cfg `
                        -Snapshot ([string]$body.snapshot) `
                        -TargetPath ([string]$body.target) `
                        -Include ([string]$body.include) `
                        -SetId $setId
                    Write-SyncMeJson @{ ok = $true; message = $msg; started = $true } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                } finally {
                    Remove-Item Env:RCLONE_CONFIG -ErrorAction SilentlyContinue
                }
        return $true
            }

            if ($path -eq '/api/restore/status' -and $req.HttpMethod -eq 'GET') {
                Write-SyncMeJson (Get-SyncMeRestoreStatusPayload) -Response $res
        return $true
            }

            if ($path -eq '/api/restore/cancel' -and $req.HttpMethod -eq 'POST') {
                try {
                    $msg = Stop-SyncMeRestoreJob
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/snapshot/delete' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                $setId = if ($body.setId) { [string]$body.setId } else { 'set1' }
                $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $setId
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Not configured yet.' } -StatusCode 400 -Response $res
        return $true
                }
                if ($cfg.AppendOnly) {
                    Write-SyncMeJson @{
                        ok      = $false
                        message = 'Append-Only Mode is enabled for this set. Snapshot deletion is blocked.'
                    } -StatusCode 400 -Response $res
        return $true
                }
                try {
                    Assert-SyncMeCanMutateRepository -ScriptRoot $ScriptRoot -Config $cfg -Operation 'snapshot delete'
                    $tools = Join-Path $ScriptRoot 'tools'
                    if (Test-Path $tools) { $env:PATH = "$tools;$env:PATH" }
                    if ($cfg.RcloneConfigPath) { $env:RCLONE_CONFIG = [string]$cfg.RcloneConfigPath }
                    elseif (Test-Path (Get-SyncMeRcloneConfigPath)) { $env:RCLONE_CONFIG = Get-SyncMeRcloneConfigPath }
                    $result = Remove-SyncMeSnapshot -Config $cfg -SnapshotId ([string]$body.snapshot)
                    Write-SyncMeJson @{ ok = $true; message = $result.Message } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                } finally {
                    Remove-Item Env:RCLONE_CONFIG -ErrorAction SilentlyContinue
                }
        return $true
            }

            if ($path -eq '/api/set' -and $req.HttpMethod -eq 'GET') {
                $qSet = $req.QueryString['setId']
                $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $(if ($qSet) { $qSet } else { '' })
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Set not found.' } -StatusCode 404 -Response $res
        return $true
                }
                $repo = [string]$cfg.ResticRepo
                $rcloneRemote = ''
                $rclonePath = ''
                if ($repo -match '^rclone:([^:]+):(.*)$') {
                    $rcloneRemote = $Matches[1]
                    $rclonePath = $Matches[2]
                }
                Write-SyncMeJson @{
                    ok                   = $true
                    id                   = $cfg.Id
                    displayName          = $cfg.DisplayName
                    networkMode          = $(if ($cfg.NetworkMode) { $cfg.NetworkMode } else { 'both' })
                    destinationType      = $(if ($cfg.DestinationType) { $cfg.DestinationType } else { 'local' })
                    sourceHost           = $cfg.SourceHost
                    sourcePaths          = @($cfg.SourcePaths)
                    resticRepo           = $cfg.ResticRepo
                    archivePath          = $cfg.ArchivePath
                    resticPath           = $cfg.ResticPath
                    runTime              = $(if ($cfg.RunTime) { $cfg.RunTime } else { '01:00' })
                    scheduleStartDate    = $(if ($cfg.ScheduleStartDate) { $cfg.ScheduleStartDate } else { '' })
                    scheduleRecurrence   = $(if ($cfg.ScheduleRecurrence) { $cfg.ScheduleRecurrence } else { 'Daily' })
                    scheduleEndDate      = $(if ($cfg.ScheduleEndDate) { $cfg.ScheduleEndDate } else { '' })
                    scheduleDaysOfWeek   = $(if ($cfg.ScheduleDaysOfWeek) { @($cfg.ScheduleDaysOfWeek) } else { @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday') })
                    enableEmail          = [bool]$cfg.EnableEmailNotifications
                    smtpServer           = $cfg.SmtpServer
                    smtpPort             = $cfg.SmtpPort
                    smtpSsl              = [bool]$cfg.SmtpUseSsl
                    mailFrom             = $cfg.MailFrom
                    mailTo               = @($cfg.MailTo) -join ', '
                    enableToast          = [bool]$cfg.EnableToastNotifications
                    useShadowCopy        = $(if ($null -ne $cfg.UseShadowCopySources) { [bool]$cfg.UseShadowCopySources } else { $true })
                    enableWakeOnLan      = [bool]$cfg.EnableWakeOnLan
                    wakeMac              = $(if ($cfg.WakeMacAddress) { $cfg.WakeMacAddress } else { '' })
                    storeShare           = -not [string]::IsNullOrWhiteSpace([string]$cfg.ShareCredentialName)
                    keepLast             = $(if ($null -ne $cfg.KeepLast) { [int]$cfg.KeepLast } else { 7 })
                    keepDaily            = $(if ($null -ne $cfg.KeepDaily) { [int]$cfg.KeepDaily } else { 14 })
                    keepWeekly           = $(if ($null -ne $cfg.KeepWeekly) { [int]$cfg.KeepWeekly } else { 8 })
                    keepMonthly          = $(if ($null -ne $cfg.KeepMonthly) { [int]$cfg.KeepMonthly } else { 6 })
                    enableRepoCheck      = $(if ($null -ne $cfg.EnableRepoCheck) { [bool]$cfg.EnableRepoCheck } else { $true })
                    weeklyDataCheckDay   = $(if ($cfg.WeeklyDataCheckDay) { $cfg.WeeklyDataCheckDay } else { 'Sunday' })
                    appendOnly           = $(if ($null -ne $cfg.AppendOnly) { [bool]$cfg.AppendOnly } else { $false })
                    failJobOnRestoreDrillFailure = $(if ($null -ne $cfg.FailJobOnRestoreDrillFailure) { [bool]$cfg.FailJobOnRestoreDrillFailure } else { $false })
                    preBackupScript      = $(if ($cfg.PreBackupScript) { [string]$cfg.PreBackupScript } else { '' })
                    postBackupScript     = $(if ($cfg.PostBackupScript) { [string]$cfg.PostBackupScript } else { '' })
                    resticLimitUploadKByte = $(if ($null -ne $cfg.ResticLimitUploadKByte) { [int]$cfg.ResticLimitUploadKByte } else { 0 })
                    rcloneRemote         = $rcloneRemote
                    rcloneSubPath        = $rclonePath
                    rcloneBwLimit        = $(if ($cfg.RcloneBwLimit) { $cfg.RcloneBwLimit } else { 'off' })
                    rcloneTransfers      = $(if ($null -ne $cfg.RcloneTransfers) { [int]$cfg.RcloneTransfers } else { 4 })
                    rcloneCheckers       = $(if ($null -ne $cfg.RcloneCheckers) { [int]$cfg.RcloneCheckers } else { 8 })
                    rcloneRetries        = $(if ($null -ne $cfg.RcloneRetries) { [int]$cfg.RcloneRetries } else { 3 })
                    rcloneLowLevelRetries = $(if ($null -ne $cfg.RcloneLowLevelRetries) { [int]$cfg.RcloneLowLevelRetries } else { 10 })
                    rcloneMultiThreadStreams = $(if ($null -ne $cfg.RcloneMultiThreadStreams) { [int]$cfg.RcloneMultiThreadStreams } else { 4 })
                } -Response $res
        return $true
            }

            if ($path -eq '/api/rclone/status' -and $req.HttpMethod -eq 'GET') {
                try {
                    $rc = Get-SyncMeRclone
                    $conf = Get-SyncMeRcloneConfigPath
                    $remotes = @()
                    $msg = ''
                    if ($rc.Ok) {
                        $list = Get-SyncMeRcloneRemotes
                        $remotes = $list.Remotes
                        $msg = $list.Message
                    } else {
                        $msg = 'rclone not installed'
                    }
                    Write-SyncMeJson @{
                        ok         = $true
                        rcloneOk   = [bool]$rc.Ok
                        rclonePath = $rc.Path
                        configPath = $conf
                        remotes    = $remotes
                        message    = $msg
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/rclone/authorize' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $type = if ($body.type) { [string]$body.type } else { 'onedrive' }
                    $name = if ($body.name) { [string]$body.name } else { '' }
                    $msg = Start-SyncMeRcloneAuthorize -Type $type -Name $name
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/rclone/authorize/cancel' -and $req.HttpMethod -eq 'POST') {
                try {
                    $msg = Stop-SyncMeRcloneAuthorize
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/rclone/authorize' -and $req.HttpMethod -eq 'GET') {
                try {
                    Write-SyncMeJson (Get-SyncMeRcloneAuthorizeStatus) -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/rclone/ls' -and $req.HttpMethod -eq 'GET') {
                try {
                    $rp = $req.QueryString['path']
                    $dirs = @(Get-SyncMeRcloneLs -RemotePath $rp)
                    Write-SyncMeJson @{ ok = $true; dirs = $dirs } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/rclone/test' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Test-SyncMeRcloneRemote -RemotePath ([string]$body.path)
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/set/rclone' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Update-SyncMeSetRclone -Body $body
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/set/policy' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Update-SyncMeSetPolicy -Body $body
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/set/rescue-kit' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                $setId = if ($body.setId) { [string]$body.setId } else { 'set1' }
                $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $setId
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Not configured yet.' } -StatusCode 400 -Response $res
        return $true
                }
                try {
                    $cfg = ConvertTo-SyncMeSetObject -Config $cfg -Id $(if ($cfg.Id) { [string]$cfg.Id } else { $setId })
                    $outPath = Export-SyncMeRescueKit -Config $cfg -ScriptRoot $ScriptRoot
                    Write-SyncMeJson @{
                        ok      = $true
                        path    = $outPath
                        message = "Rescue kit written to $outPath"
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/migrate/export' -and $req.HttpMethod -eq 'POST') {
                try {
                    $body = Read-SyncMeBody $req
                    $pw = if ($body.password) { [string]$body.password } else { '' }
                    $includeSecrets = $false
                    if ($null -ne $body.includeSecrets) { $includeSecrets = [bool]$body.includeSecrets }
                    $result = Export-SyncMeMigrationPackage -ScriptRoot $ScriptRoot -Password $pw -IncludeSecrets:$includeSecrets
                    Write-SyncMeJson @{
                        ok       = $true
                        path     = [string]$result.Path
                        setCount = [int]$result.SetCount
                        secrets  = [int]$result.Secrets
                        message  = [string]$result.Message
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/migrate/import' -and $req.HttpMethod -eq 'POST') {
                try {
                    $body = Read-SyncMeBody $req
                    $pw = if ($body.password) { [string]$body.password } else { '' }
                    $pkg = if ($body.path) { [string]$body.path } else { '' }
                    $restoreSecrets = $true
                    if ($null -ne $body.restoreSecrets) { $restoreSecrets = [bool]$body.restoreSecrets }
                    $winPass = if ($body.windowsPassword) { [string]$body.windowsPassword } else { '' }
                    $result = Import-SyncMeMigrationPackage -ScriptRoot $ScriptRoot -Password $pw -PackagePath $pkg -RestoreSecrets:$restoreSecrets
                    $scheduleNotes = @()
                    if (-not [string]::IsNullOrEmpty($winPass)) {
                        foreach ($s in @($result.Sets)) {
                            try {
                                $schedBody = [pscustomobject]@{
                                    setId              = $s.id
                                    runTime            = $(if ($s.runTime) { $s.runTime } else { '01:00' })
                                    windowsPassword    = $winPass
                                    logonType          = 'Password'
                                }
                                $full = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $s.id
                                if ($full) {
                                    $schedBody | Add-Member -NotePropertyName scheduleStartDate -NotePropertyValue $(if ($full.ScheduleStartDate) { $full.ScheduleStartDate } else { (Get-Date).ToString('yyyy-MM-dd') }) -Force
                                    $schedBody | Add-Member -NotePropertyName scheduleRecurrence -NotePropertyValue $(if ($full.ScheduleRecurrence) { $full.ScheduleRecurrence } else { 'Daily' }) -Force
                                    $schedBody | Add-Member -NotePropertyName scheduleEndDate -NotePropertyValue $(if ($full.ScheduleEndDate) { $full.ScheduleEndDate } else { '' }) -Force
                                    $schedBody | Add-Member -NotePropertyName scheduleDaysOfWeek -NotePropertyValue $(if ($full.ScheduleDaysOfWeek) { @($full.ScheduleDaysOfWeek) } else { @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday') }) -Force
                                }
                                $scheduleNotes += (Invoke-SyncMeScheduleUpdate -Body $schedBody)
                            } catch {
                                $scheduleNotes += ("Schedule $($s.id): " + $_.Exception.Message)
                            }
                        }
                    } else {
                        $scheduleNotes += 'Sets imported. Provide Windows password to re-register Task Scheduler jobs.'
                    }
                    Write-SyncMeJson @{
                        ok              = $true
                        setCount        = [int]$result.SetCount
                        secretsRestored = [int]$result.SecretsRestored
                        message         = [string]$result.Message
                        schedule        = $scheduleNotes
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/mount/status' -and $req.HttpMethod -eq 'GET') {
                $qSet = [string]$req.QueryString['setId']
                Write-SyncMeJson (Get-SyncMeMountStatus -SetId $qSet) -Response $res
        return $true
            }

            if ($path -eq '/api/mount/start' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $sid = if ($body.setId) { [string]$body.setId } else { 'set1' }
                    $cfgMount = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $sid
                    if (-not $cfgMount) { throw 'Not configured yet.' }
                    Assert-SyncMeCanMutateRepository -ScriptRoot $ScriptRoot -Config $cfgMount -Operation 'mount'
                    $mp = if ($body.mountPoint) { [string]$body.mountPoint } else { '' }
                    $msg = Start-SyncMeMount -SetId $sid -MountPoint $mp
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/mount/stop' -and $req.HttpMethod -eq 'POST') {
                try {
                    $msg = Stop-SyncMeMount
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/set/delete' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Remove-SyncMeBackupSet -SetId ([string]$body.setId)
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/set/restic-path' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $sid = if ($body.setId) { [string]$body.setId } else { 'set1' }
                    $msg = Update-SyncMeSetResticPath -SetId $sid -ResticPath ([string]$body.resticPath)
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/set/restic-password' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $sid = if ($body.setId) { [string]$body.setId } else { 'set1' }
                    $msg = Set-SyncMeResticPassword -SetId $sid -Password ([string]$body.password)
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/backup/cancel' -and $req.HttpMethod -eq 'POST') {
                try {
                    $msg = Stop-SyncMeBackupJob
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/wake' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $mac = [string]$body.mac
                    if (-not $mac) {
                        $sid = if ($body.setId) { [string]$body.setId } else { 'set1' }
                        $s = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $sid
                        $mac = if ($s) { [string]$s.WakeMacAddress } else { '' }
                    }
                    $msg = Send-SyncMeWakeOnLan -MacAddress $mac
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
        return $true
            }

            if ($path -eq '/api/open' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                $kind = [string]$body.kind
                $setId = if ($body.setId) { [string]$body.setId } else { '' }
                $cfg = if ($setId) { Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $setId } else { Get-SyncMeConfigOrNull }
                $target = $null
                switch ($kind) {
                    'reports' { $target = Join-Path $ScriptRoot 'Reports' }
                    'logs' { $target = Join-Path $ScriptRoot 'Logs' }
                    'archive' {
                        if (-not $cfg) { throw 'Not configured.' }
                        $target = [string]$cfg.ArchivePath
                        if ([string]::IsNullOrWhiteSpace($target)) {
                            throw 'Disk 2 (archive) path is not set for this backup set. Edit the set to add one, or leave Disk 2 empty for restic-only backups.'
                        }
                    }
                    'checklist' { $target = Join-Path $ScriptRoot 'RecoveryChecklist.txt' }
                    'officeagent' { $target = Join-Path $ScriptRoot 'OfficeAgent' }
                    'file' {
                        $target = [string]$body.path
                        if ([string]::IsNullOrWhiteSpace($target)) { throw 'path is required for kind=file.' }
                        if (-not (Test-Path -LiteralPath $target)) { throw "File not found: $target" }
                    }
                    'mount' {
                        throw 'Browse-as-folder Mount is not available on Windows. Use Restore selected (or Restore latest) instead.'
                    }
                    default { throw "Unknown open kind: $kind" }
                }
                if ($kind -eq 'checklist') {
                    if (Test-Path $target) { Start-Process notepad.exe -ArgumentList $target }
                } elseif ($kind -eq 'file') {
                    Start-Process -FilePath $target
                } else {
                    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                    Start-Process explorer.exe -ArgumentList $target
                }
                Write-SyncMeJson @{ ok = $true; message = "Opened $kind" } -Response $res
        return $true
            }

            if ($path -eq '/api/shutdown' -and $req.HttpMethod -eq 'POST') {
                Write-SyncMeJson @{ ok = $true; message = 'Stopping' } -Response $res
                if ($Listener) { try { $Listener.Stop() } catch { } }
                return 'shutdown'
            }

    return $false
}