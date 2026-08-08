#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe local host - serves HTML UI and JSON API on 127.0.0.1 (no PHP, no DB).
#>
[CmdletBinding()]
param(
    [int]$Port = 17845,
    [switch]$NoBrowser,
    [ValidateSet('auto', 'setup', 'console')]
    [string]$OpenView = 'auto'
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot
$UiRoot = Join-Path $ScriptRoot 'ui'
$utf8Bom = New-Object System.Text.UTF8Encoding $true

. (Join-Path $ScriptRoot 'Modules\Common.ps1')
. (Join-Path $ScriptRoot 'Modules\Notify.ps1')
. (Join-Path $ScriptRoot 'Modules\Restore.ps1')
. (Join-Path $ScriptRoot 'Modules\Sets.ps1')
. (Join-Path $ScriptRoot 'Modules\Report.ps1')
foreach ($mod in @('Update.ps1', 'MonitorClient.ps1', 'LocalOpsClient.ps1', 'Migrate.ps1')) {
    $modPath = Join-Path $ScriptRoot ('Modules\' + $mod)
    if (-not (Test-Path -LiteralPath $modPath)) {
        throw "Missing $modPath. Re-run SyncMe-Setup (or copy Modules\$mod into the install folder)."
    }
    . $modPath
}

$script:BackupJob = @{
    Running  = $false
    Finished = $false
    ExitCode = $null
    Message  = ''
    Detail   = ''
    Started  = $null
    Process  = $null
}

$script:RestoreJob = @{
    Running   = $false
    Finished  = $false
    ExitCode  = $null
    Message   = ''
    Detail    = ''
    Started   = $null
    Process   = $null
    SetId     = ''
    Snapshot  = ''
    Target    = ''
    StatusFile = ''
}

$script:RcloneAuth = @{
    Running   = $false
    Type      = ''
    Name      = ''
    Url       = ''
    Token     = ''
    Message   = ''
    Finished  = $false
    Ok        = $false
    Process   = $null
    OutFile   = ''
    ErrFile   = ''
    Started   = $null
    Config    = ''
    Path      = ''
}

$script:RcloneAuthTimeoutMinutes = 5


$script:MountJob = @{
    Running    = $false
    SetId      = ''
    MountPoint = ''
    Process    = $null
    Message    = ''
    Pid        = $null
}
$script:ResticMountProbe = $null

function Write-SyncMeJson {
    param($Object, [int]$StatusCode = 200, $Response)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Read-SyncMeBody {
    param($Request)
    if (-not $Request.HasEntityBody) { return $null }
    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        $raw = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } finally {
        $reader.Close()
    }
}

function Get-SyncMeConfigOrNull {
    return Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId ''
}

function Test-SyncMeConfigured {
    $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    if ($sets.Count -eq 0) {
        # Legacy marker without sets array
        $marker = Join-Path $ScriptRoot 'Logs\syncme-setup-complete.json'
        if (-not (Test-Path -LiteralPath $marker)) { return $false }
        $c = Get-SyncMeConfigOrNull
        if (-not $c) { return $false }
        if ([string]::IsNullOrWhiteSpace($c.ResticRepo)) { return $false }
        if (-not $c.SourcePaths -or @($c.SourcePaths).Count -eq 0) { return $false }
        return $true
    }

    foreach ($s in $sets) {
        $marker = Join-Path $ScriptRoot ("Logs\sets\{0}\setup-complete.json" -f $s.Id)
        $legacy = Join-Path $ScriptRoot 'Logs\syncme-setup-complete.json'
        $hasMarker = (Test-Path -LiteralPath $marker) -or (($s.Id -eq 'set1') -and (Test-Path -LiteralPath $legacy))
        if (-not $hasMarker) { continue }
        if ([string]::IsNullOrWhiteSpace($s.ResticRepo)) { continue }
        if (-not $s.SourcePaths -or @($s.SourcePaths).Count -eq 0) { continue }
        $credName = 'SyncMeRestic'
        if ($s.PSObject.Properties.Name -contains 'ResticCredentialName' -and $s.ResticCredentialName) {
            $credName = [string]$s.ResticCredentialName
        } elseif ($s.Id -and $s.Id -ne 'set1') {
            $credName = "SyncMeRestic-$($s.Id)"
        }
        try {
            $null = Get-BackupStoredCredential -TargetName $credName
            return $true
        } catch {
            continue
        }
    }
    return $false
}

function Get-ResticOnPath {
    $cfg = Get-SyncMeConfigOrNull
    $configured = 'restic'
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'ResticPath' -and $cfg.ResticPath) {
        $configured = [string]$cfg.ResticPath
    }
    return Resolve-SyncMeResticExe -ConfiguredPath $configured -ScriptRoot $ScriptRoot
}

function Install-SyncMeRestic {
    $existing = Get-ResticOnPath
    if ($existing.Ok) {
        return @{
            Ok      = $true
            Path    = $existing.Path
            Message = "restic already available at $($existing.Path)"
        }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $headers = @{ 'User-Agent' = 'SyncMe' }
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/restic/restic/releases/latest' -Headers $headers
    } catch {
        throw "Could not reach GitHub to download restic: $($_.Exception.Message)"
    }

    $asset = @($release.assets) | Where-Object { $_.name -match 'windows_amd64\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        throw 'Could not find a windows_amd64.zip asset in the latest restic release.'
    }

    $toolsDir = Join-Path $ScriptRoot 'tools'
    if (-not (Test-Path -LiteralPath $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }

    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('syncme-restic-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    try {
        $zipPath = Join-Path $tmpDir 'restic.zip'
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -UseBasicParsing
        } catch {
            throw "Download failed (check firewall/offline): $($_.Exception.Message)"
        }

        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmpDir -Force
        $exe = Get-ChildItem -Path $tmpDir -Filter 'restic*.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $exe) {
            throw 'Downloaded zip did not contain restic.exe.'
        }

        $dest = Join-Path $toolsDir 'restic.exe'
        Copy-Item -LiteralPath $exe.FullName -Destination $dest -Force

        $verOut = & $dest version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "restic installed but version check failed: $verOut"
        }

        $verLine = ($verOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        return @{
            Ok      = $true
            Path    = $dest
            Message = "Installed restic to $dest ($($verLine.Trim()))"
        }
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-CmdKeyGeneric {
    param([string]$Target, [string]$User, [string]$Password)
    $existing = cmdkey /list 2>&1 | Out-String
    if ($existing -match [regex]::Escape($Target)) {
        cmdkey /delete:$Target 2>$null | Out-Null
    }
    $result = cmdkey /generic:$Target /user:$User /pass:$Password 2>&1
    if ($LASTEXITCODE -ne 0) { throw "cmdkey failed for ${Target}: $result" }
}

function Escape-Sq {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace "'", "''")
}

function Format-Arr {
    param([string[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return '@()' }
    $inner = ($Items | ForEach-Object { "'{0}'" -f (Escape-Sq $_) }) -join "`r`n        "
    return "@(`r`n        $inner`r`n    )"
}

function Format-SyncMeSetLiteral {
    param($Set, $tf)
    $stamp = if ($Set.ArchiveStampFile) { $Set.ArchiveStampFile } else { "Logs\sets\$($Set.Id)\last-archive-utc.txt" }
    $lock = if ($Set.BackupLockFile) { $Set.BackupLockFile } else { "Logs\sets\$($Set.Id)\backup.lock" }
    $success = if ($Set.LastSuccessStampFile) { $Set.LastSuccessStampFile } else { "Logs\sets\$($Set.Id)\last-success-utc.txt" }
    $keepLast = if ($null -ne $Set.KeepLast) { [int]$Set.KeepLast } else { 7 }
    $keepDaily = if ($null -ne $Set.KeepDaily) { [int]$Set.KeepDaily } else { 14 }
    $keepWeekly = if ($null -ne $Set.KeepWeekly) { [int]$Set.KeepWeekly } else { 8 }
    $keepMonthly = if ($null -ne $Set.KeepMonthly) { [int]$Set.KeepMonthly } else { 6 }
    $enableCheck = if ($null -ne $Set.EnableRepoCheck) { [bool]$Set.EnableRepoCheck } else { $true }
    $checkDay = if ($Set.WeeklyDataCheckDay) { [string]$Set.WeeklyDataCheckDay } else { 'Sunday' }
    $limitUp = if ($null -ne $Set.ResticLimitUploadKByte) { [int]$Set.ResticLimitUploadKByte } else { 0 }
    $rclonePath = if ($Set.RclonePath) { [string]$Set.RclonePath } else { '' }
    $rcloneConf = if ($Set.RcloneConfigPath) { [string]$Set.RcloneConfigPath } else { '' }
    $bw = if ($Set.RcloneBwLimit) { [string]$Set.RcloneBwLimit } else { 'off' }
    $transfers = if ($null -ne $Set.RcloneTransfers) { [int]$Set.RcloneTransfers } else { 4 }
    $checkers = if ($null -ne $Set.RcloneCheckers) { [int]$Set.RcloneCheckers } else { 8 }
    $retries = if ($null -ne $Set.RcloneRetries) { [int]$Set.RcloneRetries } else { 3 }
    $llRetries = if ($null -ne $Set.RcloneLowLevelRetries) { [int]$Set.RcloneLowLevelRetries } else { 10 }
    $mtStreams = if ($null -ne $Set.RcloneMultiThreadStreams) { [int]$Set.RcloneMultiThreadStreams } else { 4 }
    $schedStart = if ($Set.ScheduleStartDate) { [string]$Set.ScheduleStartDate } else { (Get-Date).ToString('yyyy-MM-dd') }
    $schedRec = if ($Set.ScheduleRecurrence) { [string]$Set.ScheduleRecurrence } else { 'Daily' }
    $schedEnd = if ($Set.ScheduleEndDate) { [string]$Set.ScheduleEndDate } else { '' }
    $schedDays = if ($Set.ScheduleDaysOfWeek) { @($Set.ScheduleDaysOfWeek) } else { @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday') }
    $excludes = @(Merge-SyncMeExcludePatterns -Existing $(if ($Set.ExcludePatterns) { @($Set.ExcludePatterns) } else { @() }))
    @"
    [pscustomobject]@{
        Id = '$(Escape-Sq $Set.Id)'
        DisplayName = '$(Escape-Sq $Set.DisplayName)'
        NetworkMode = '$(Escape-Sq $Set.NetworkMode)'
        DestinationType = '$(Escape-Sq $Set.DestinationType)'
        RunTime = '$(Escape-Sq $Set.RunTime)'
        ScheduleStartDate = '$(Escape-Sq $schedStart)'
        ScheduleRecurrence = '$(Escape-Sq $schedRec)'
        ScheduleEndDate = '$(Escape-Sq $schedEnd)'
        ScheduleDaysOfWeek = $(Format-Arr $schedDays)
        SourcePaths = $(Format-Arr @($Set.SourcePaths))
        ShareCredentialName = '$(Escape-Sq $Set.ShareCredentialName)'
        ShareDriveLetter = ''
        ResticRepo = '$(Escape-Sq $Set.ResticRepo)'
        ArchivePath = '$(Escape-Sq $Set.ArchivePath)'
        ResticCredentialName = '$(Escape-Sq $Set.ResticCredentialName)'
        ResticPath = '$(Escape-Sq $Set.ResticPath)'
        KeepLast = $keepLast; KeepDaily = $keepDaily; KeepWeekly = $keepWeekly; KeepMonthly = $keepMonthly
        ArchiveEveryDays = 14
        ArchiveStampFile = '$(Escape-Sq $stamp)'
        ClearArchiveBeforeRestore = `$true
        ExcludePatterns = $(Format-Arr $excludes)
        SnapshotTags = @('syncme','$(Escape-Sq $Set.Id)')
        EnableToastNotifications = $(& $tf $Set.EnableToastNotifications)
        ToastAppId = 'SyncMe'
        EnableEmailNotifications = $(& $tf $Set.EnableEmailNotifications)
        SmtpServer = '$(Escape-Sq $Set.SmtpServer)'
        SmtpPort = $($Set.SmtpPort)
        SmtpUseSsl = $(& $tf $Set.SmtpUseSsl)
        MailFrom = '$(Escape-Sq $Set.MailFrom)'
        MailTo = $(Format-Arr @($Set.MailTo))
        SmtpCredentialName = 'SyncMeSmtp'
        EmailOnStart = `$true
        EmailOnComplete = `$true
        ReportsDir = 'Reports'
        LogsDir = 'Logs'
        SourceHost = '$(Escape-Sq $Set.SourceHost)'
        RequireSourceReachable = `$true
        UseShadowCopySources = $(& $tf $(if ($null -ne $Set.UseShadowCopySources) { $Set.UseShadowCopySources } else { $true }))
        ShadowPointerRelativePath = '.monarch-latest-shadow.txt'
        ShadowCopyRequired = `$false
        EnableWakeOnLan = $(& $tf $Set.EnableWakeOnLan)
        WakeMacAddress = '$(Escape-Sq $Set.WakeMacAddress)'
        EnableRepoCheck = $(& $tf $enableCheck)
        WeeklyDataCheckDay = '$(Escape-Sq $checkDay)'
        AppendOnly = $(& $tf $(if ($null -ne $Set.AppendOnly) { $Set.AppendOnly } else { $false }))
        FailJobOnRestoreDrillFailure = $(& $tf $(if ($null -ne $Set.FailJobOnRestoreDrillFailure) { $Set.FailJobOnRestoreDrillFailure } else { $false }))
        PreBackupScript = '$(Escape-Sq $(if ($Set.PreBackupScript) { $Set.PreBackupScript } else { '' }))'
        PostBackupScript = '$(Escape-Sq $(if ($Set.PostBackupScript) { $Set.PostBackupScript } else { '' }))'
        MinFreeRepoGb = 50
        MinFreeArchiveGb = 100
        WatchdogMaxAgeDays = 2
        LogRetentionDays = 90
        ResticLimitUploadKByte = $limitUp
        RclonePath = '$(Escape-Sq $rclonePath)'
        RcloneConfigPath = '$(Escape-Sq $rcloneConf)'
        RcloneBwLimit = '$(Escape-Sq $bw)'
        RcloneTransfers = $transfers
        RcloneCheckers = $checkers
        RcloneRetries = $retries
        RcloneLowLevelRetries = $llRetries
        RcloneMultiThreadStreams = $mtStreams
        LockStaleHours = 36
        LastSuccessStampFile = '$(Escape-Sq $success)'
        BackupLockFile = '$(Escape-Sq $lock)'
    }
"@
}

function Write-SyncMeSetsConfigFile {
    param([object[]]$Sets)
    $tf = { param($b) if ($b) { '$true' } else { '$false' } }
    $norm = foreach ($s in @($Sets)) {
        ConvertTo-SyncMeSetObject -Config $s -Id $s.Id -DisplayName $(if ($s.DisplayName) { $s.DisplayName } else { $s.Id })
    }
    $setLiterals = ($norm | ForEach-Object { Format-SyncMeSetLiteral -Set $_ -tf $tf }) -join ",`r`n"
    $configPath = Join-Path $ScriptRoot 'Config.ps1'
    if (Test-Path $configPath) {
        Copy-Item $configPath (Join-Path $ScriptRoot ("Config.ps1.bak-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
    }
    $content = @"
#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe configuration (multi-set). Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'). Do not store passwords here.
#>
`$script:BackupSets = @(
$setLiterals
)
`$script:BackupConfig = `$script:BackupSets[0]
function Get-BackupConfig { return `$script:BackupConfig }
function Get-BackupSets { return `$script:BackupSets }
"@
    [IO.File]::WriteAllText($configPath, $content, $utf8Bom)
}

function Get-SyncMeRcloneConfigPath {
    $dir = Join-Path $ScriptRoot 'Config'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'rclone.conf')
}

function Get-SyncMePackageVersion {
    $verFile = Join-Path $ScriptRoot 'VERSION.txt'
    if (-not (Test-Path -LiteralPath $verFile)) { return '' }
    try {
        return ((Get-Content -LiteralPath $verFile -TotalCount 1 -ErrorAction Stop).Trim())
    } catch {
        return ''
    }
}

function Get-SyncMeRclone {
    $local = Join-Path $ScriptRoot 'tools\rclone.exe'
    if (Test-Path -LiteralPath $local) { return @{ Ok = $true; Path = $local } }
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { return @{ Ok = $true; Path = $cmd.Source } }
    return @{ Ok = $false; Path = '' }
}

function Invoke-SyncMeRclone {
    param([string[]]$Arguments)
    $rc = Get-SyncMeRclone
    if (-not $rc.Ok) { throw 'rclone not found. Use Prerequisites -> Install rclone.' }
    $conf = Get-SyncMeRcloneConfigPath
    if (-not (Test-Path -LiteralPath $conf)) {
        '' | Set-Content -LiteralPath $conf -Encoding UTF8
    }
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ('syncme-rclone-out-' + [guid]::NewGuid().ToString('n') + '.txt')
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ('syncme-rclone-err-' + [guid]::NewGuid().ToString('n') + '.txt')
    try {
        $p = Start-Process -FilePath $rc.Path -ArgumentList (@('--config', $conf) + $Arguments) `
            -NoNewWindow -PassThru -Wait -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $stdout = if (Test-Path $outFile) { Get-Content $outFile -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw -ErrorAction SilentlyContinue } else { '' }
        return @{
            ExitCode = $p.ExitCode
            StdOut   = if ($stdout) { $stdout.Trim() } else { '' }
            StdErr   = if ($stderr) { $stderr.Trim() } else { '' }
            Path     = $rc.Path
            Config   = $conf
        }
    } finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-SyncMeRcloneRemotes {
    $r = Invoke-SyncMeRclone -Arguments @('listremotes')
    $remotes = @()
    if ($r.StdOut) {
        $remotes = @($r.StdOut -split "`r?`n" | ForEach-Object { $_.Trim().TrimEnd(':') } | Where-Object { $_ })
    }
    return @{
        Ok      = ($r.ExitCode -eq 0)
        Remotes = $remotes
        Path    = $r.Path
        Config  = $r.Config
        Message = if ($r.ExitCode -eq 0) { '' } else { $(if ($r.StdErr) { $r.StdErr } else { $r.StdOut }) }
    }
}

function Stop-SyncMeRcloneAuthorizeProcess {
    if ($script:RcloneAuth.Process -and -not $script:RcloneAuth.Process.HasExited) {
        try { Stop-Process -Id $script:RcloneAuth.Process.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-SyncMeOAuthProviderLabel {
    param([string]$Type)
    switch ($Type) {
        'drive' { return 'Google Drive' }
        'onedrive' { return 'OneDrive' }
        default { return $(if ($Type) { $Type } else { 'cloud' }) }
    }
}

function Start-SyncMeRcloneAuthorize {
    param(
        [ValidateSet('onedrive', 'drive')]
        [string]$Type,
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Remote name is required.' }
    if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Remote name may only contain letters, numbers, _ and -.' }
    $rc = Get-SyncMeRclone
    if (-not $rc.Ok) { throw 'rclone not found. Install rclone first.' }
    if ($script:RcloneAuth.Running -and $script:RcloneAuth.Process -and -not $script:RcloneAuth.Process.HasExited) {
        $label = Get-SyncMeOAuthProviderLabel -Type $script:RcloneAuth.Type
        $runningName = if ($script:RcloneAuth.Name) { $script:RcloneAuth.Name } else { 'remote' }
        throw "Authorize for $label ($runningName) is still running. Wait until it finishes or cancel it."
    }

    $existing = Get-SyncMeRcloneRemotes
    if ($existing.Remotes -contains $Name) {
        throw "Remote '$Name' already exists. Choose a different name."
    }

    $conf = Get-SyncMeRcloneConfigPath
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ('syncme-rclone-auth-out-' + [guid]::NewGuid().ToString('n') + '.txt')
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ('syncme-rclone-auth-err-' + [guid]::NewGuid().ToString('n') + '.txt')
    '' | Set-Content -LiteralPath $outFile -Encoding UTF8
    '' | Set-Content -LiteralPath $errFile -Encoding UTF8

    # authorize prints a URL; after browser login it prints a JSON token block
    $p = Start-Process -FilePath $rc.Path -ArgumentList @('authorize', $Type) `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $script:RcloneAuth = @{
        Running  = $true
        Type     = $Type
        Name     = $Name
        Url      = ''
        Token    = ''
        Message  = 'Waiting for browser authorization...'
        Finished = $false
        Ok       = $false
        Process  = $p
        OutFile  = $outFile
        ErrFile  = $errFile
        Config   = $conf
        Path     = $rc.Path
        Started  = Get-Date
    }
    return 'OAuth started. Open the authorize URL, sign in, then wait for SyncMe to finish creating the remote.'
}

function Stop-SyncMeRcloneAuthorize {
    if (-not $script:RcloneAuth.Running -and -not ($script:RcloneAuth.Process -and -not $script:RcloneAuth.Process.HasExited)) {
        return 'No OAuth authorize session is running.'
    }
    Stop-SyncMeRcloneAuthorizeProcess
    $script:RcloneAuth.Running = $false
    $script:RcloneAuth.Finished = $true
    $script:RcloneAuth.Ok = $false
    $script:RcloneAuth.Message = 'OAuth authorize cancelled.'
    return $script:RcloneAuth.Message
}

function Update-SyncMeRcloneAuthorize {
    if (-not $script:RcloneAuth.Running -and -not $script:RcloneAuth.Finished) { return }
    $out = ''
    $err = ''
    if ($script:RcloneAuth.OutFile -and (Test-Path $script:RcloneAuth.OutFile)) {
        $out = Get-Content -LiteralPath $script:RcloneAuth.OutFile -Raw -ErrorAction SilentlyContinue
    }
    if ($script:RcloneAuth.ErrFile -and (Test-Path $script:RcloneAuth.ErrFile)) {
        $err = Get-Content -LiteralPath $script:RcloneAuth.ErrFile -Raw -ErrorAction SilentlyContinue
    }
    $combined = "$out`n$err"
    if (-not $script:RcloneAuth.Url) {
        if ($combined -match '(https?://127\.0\.0\.1:\d+/\S+)') {
            $script:RcloneAuth.Url = $Matches[1].TrimEnd('.', ',', ')', ']')
        } elseif ($combined -match '(https?://localhost:\d+/\S+)') {
            $script:RcloneAuth.Url = $Matches[1].TrimEnd('.', ',', ')', ']')
        }
    }
    if ($combined -match '(?s)Paste the following into your remote machine --->\s*(\{.*?\})\s*<---End paste') {
        $script:RcloneAuth.Token = $Matches[1].Trim()
    } elseif ($combined -match '(?s)(\{"access_token".*?\})') {
        $script:RcloneAuth.Token = $Matches[1].Trim()
    }

    # Timeout: browser close / abandoned authorize cannot be detected; kill after N minutes
    if ($script:RcloneAuth.Running -and $script:RcloneAuth.Started) {
        $age = (Get-Date) - [datetime]$script:RcloneAuth.Started
        if ($age.TotalMinutes -ge $script:RcloneAuthTimeoutMinutes) {
            Stop-SyncMeRcloneAuthorizeProcess
            $script:RcloneAuth.Running = $false
            $script:RcloneAuth.Finished = $true
            $script:RcloneAuth.Ok = $false
            $script:RcloneAuth.Message = "OAuth authorize timed out after $($script:RcloneAuthTimeoutMinutes) minutes. Close any leftover browser tabs and try again."
            return
        }
    }

    $procDone = (-not $script:RcloneAuth.Process) -or $script:RcloneAuth.Process.HasExited
    if ($script:RcloneAuth.Token -and -not $script:RcloneAuth.Finished) {
        try {
            $token = $script:RcloneAuth.Token
            $name = $script:RcloneAuth.Name
            $type = $script:RcloneAuth.Type
            $conf = $script:RcloneAuth.Config
            $exe = $script:RcloneAuth.Path
            # Create remote with the token from authorize
            $createArgs = @(
                '--config', $conf,
                'config', 'create', $name, $type,
                'token', $token,
                '--non-interactive'
            )
            $p2 = Start-Process -FilePath $exe -ArgumentList $createArgs -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput (Join-Path ([IO.Path]::GetTempPath()) 'syncme-rclone-create-out.txt') `
                -RedirectStandardError (Join-Path ([IO.Path]::GetTempPath()) 'syncme-rclone-create-err.txt')
            if ($p2.ExitCode -ne 0) {
                $cerr = Get-Content (Join-Path ([IO.Path]::GetTempPath()) 'syncme-rclone-create-err.txt') -Raw -ErrorAction SilentlyContinue
                throw "rclone config create failed: $cerr"
            }
            $script:RcloneAuth.Ok = $true
            $script:RcloneAuth.Message = "Remote '$name' ($type) created in SyncMe rclone config."
            $script:RcloneAuth.Finished = $true
            $script:RcloneAuth.Running = $false
        } catch {
            $script:RcloneAuth.Ok = $false
            $script:RcloneAuth.Message = $_.Exception.Message
            $script:RcloneAuth.Finished = $true
            $script:RcloneAuth.Running = $false
        }
    } elseif ($procDone -and -not $script:RcloneAuth.Token -and $script:RcloneAuth.Running) {
        $script:RcloneAuth.Running = $false
        $script:RcloneAuth.Finished = $true
        $script:RcloneAuth.Ok = $false
        $script:RcloneAuth.Message = $(if ($err) { $err } elseif ($out) { $out } else { 'Authorize ended without a token.' })
    }
}

function Get-SyncMeRcloneAuthorizeStatus {
    Update-SyncMeRcloneAuthorize
    return @{
        ok       = $true
        running  = [bool]$script:RcloneAuth.Running
        finished = [bool]$script:RcloneAuth.Finished
        success  = [bool]$script:RcloneAuth.Ok
        type     = $script:RcloneAuth.Type
        name     = $script:RcloneAuth.Name
        url      = $script:RcloneAuth.Url
        message  = $script:RcloneAuth.Message
    }
}

function Get-SyncMeRcloneLs {
    param([string]$RemotePath)
    if ([string]::IsNullOrWhiteSpace($RemotePath)) { throw 'remote path required (e.g. mydrive: or mydrive:Backup).' }
    $path = $RemotePath.Trim()
    if ($path -notmatch ':') { $path = "$path :" -replace ' :', ':' }
    $r = Invoke-SyncMeRclone -Arguments @('lsf', $path, '--dirs-only', '--max-depth', '1')
    if ($r.ExitCode -ne 0) {
        throw $(if ($r.StdErr) { $r.StdErr } else { "rclone lsf failed for $path" })
    }
    $dirs = @()
    if ($r.StdOut) {
        $dirs = @($r.StdOut -split "`r?`n" | ForEach-Object { $_.Trim().TrimEnd('/') } | Where-Object { $_ })
    }
    return $dirs
}

function Test-SyncMeRcloneRemote {
    param([string]$RemotePath)
    $path = $RemotePath.Trim()
    if ($path -notmatch ':') { throw 'Use remote:path format.' }
    $r = Invoke-SyncMeRclone -Arguments @('about', $path)
    if ($r.ExitCode -ne 0) {
        # about not supported on all backends - fall back to lsf
        $r2 = Invoke-SyncMeRclone -Arguments @('lsf', $path, '--max-depth', '1')
        if ($r2.ExitCode -ne 0) {
            throw $(if ($r2.StdErr) { $r2.StdErr } else { "rclone probe failed for $path" })
        }
        return "Reachable: $path"
    }
    return "Reachable: $path`n$($r.StdOut)"
}

function Update-SyncMeSetRclone {
    param($Body)
    $setId = if ($Body.setId) { [string]$Body.setId } else { 'set1' }
    $remote = [string]$Body.remote
    $path = if ($Body.path) { [string]$Body.path } else { '' }
    if ([string]::IsNullOrWhiteSpace($remote)) { throw 'remote name required.' }
    $remote = $remote.TrimEnd(':')
    $sub = ($path -replace '^/+', '').Trim()
    $repo = if ($sub) { "rclone:${remote}:${sub}" } else { "rclone:${remote}:" }

    $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    if ($sets.Count -eq 0) { throw 'No backup sets configured.' }
    $found = $false
    $rclone = Get-SyncMeRclone
    $conf = Get-SyncMeRcloneConfigPath
    $updated = foreach ($s in $sets) {
        if ($s.Id -eq $setId) {
            $s | Add-Member -NotePropertyName DestinationType -NotePropertyValue 'rclone' -Force
            $s | Add-Member -NotePropertyName ResticRepo -NotePropertyValue $repo -Force
            $s | Add-Member -NotePropertyName RclonePath -NotePropertyValue $(if ($rclone.Ok) { $rclone.Path } else { '' }) -Force
            $s | Add-Member -NotePropertyName RcloneConfigPath -NotePropertyValue $conf -Force
            if ($null -ne $Body.rcloneBwLimit) { $s | Add-Member -NotePropertyName RcloneBwLimit -NotePropertyValue ([string]$Body.rcloneBwLimit) -Force }
            if ($null -ne $Body.rcloneTransfers) { $s | Add-Member -NotePropertyName RcloneTransfers -NotePropertyValue ([int]$Body.rcloneTransfers) -Force }
            if ($null -ne $Body.rcloneCheckers) { $s | Add-Member -NotePropertyName RcloneCheckers -NotePropertyValue ([int]$Body.rcloneCheckers) -Force }
            if ($null -ne $Body.rcloneRetries) { $s | Add-Member -NotePropertyName RcloneRetries -NotePropertyValue ([int]$Body.rcloneRetries) -Force }
            if ($null -ne $Body.rcloneLowLevelRetries) { $s | Add-Member -NotePropertyName RcloneLowLevelRetries -NotePropertyValue ([int]$Body.rcloneLowLevelRetries) -Force }
            if ($null -ne $Body.rcloneMultiThreadStreams) { $s | Add-Member -NotePropertyName RcloneMultiThreadStreams -NotePropertyValue ([int]$Body.rcloneMultiThreadStreams) -Force }
            if ($null -ne $Body.resticLimitUploadKByte) { $s | Add-Member -NotePropertyName ResticLimitUploadKByte -NotePropertyValue ([int]$Body.resticLimitUploadKByte) -Force }
            $found = $true
        }
        $s
    }
    if (-not $found) { throw "Set not found: $setId" }
    Write-SyncMeSetsConfigFile -Sets @($updated)
    return "Saved cloud destination for $setId -> $repo"
}

function Update-SyncMeSetPolicy {
    param($Body)
    $setId = if ($Body.setId) { [string]$Body.setId } else { 'set1' }
    $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    if ($sets.Count -eq 0) { throw 'No backup sets configured.' }
    $found = $false
    $updated = foreach ($s in $sets) {
        if ($s.Id -eq $setId) {
            if ($null -ne $Body.keepLast) { $s | Add-Member -NotePropertyName KeepLast -NotePropertyValue ([int]$Body.keepLast) -Force }
            if ($null -ne $Body.keepDaily) { $s | Add-Member -NotePropertyName KeepDaily -NotePropertyValue ([int]$Body.keepDaily) -Force }
            if ($null -ne $Body.keepWeekly) { $s | Add-Member -NotePropertyName KeepWeekly -NotePropertyValue ([int]$Body.keepWeekly) -Force }
            if ($null -ne $Body.keepMonthly) { $s | Add-Member -NotePropertyName KeepMonthly -NotePropertyValue ([int]$Body.keepMonthly) -Force }
            if ($null -ne $Body.enableRepoCheck) { $s | Add-Member -NotePropertyName EnableRepoCheck -NotePropertyValue ([bool]$Body.enableRepoCheck) -Force }
            if ($Body.weeklyDataCheckDay) { $s | Add-Member -NotePropertyName WeeklyDataCheckDay -NotePropertyValue ([string]$Body.weeklyDataCheckDay) -Force }
            if ($null -ne $Body.appendOnly) { $s | Add-Member -NotePropertyName AppendOnly -NotePropertyValue ([bool]$Body.appendOnly) -Force }
            if ($null -ne $Body.failJobOnRestoreDrillFailure) {
                $s | Add-Member -NotePropertyName FailJobOnRestoreDrillFailure -NotePropertyValue ([bool]$Body.failJobOnRestoreDrillFailure) -Force
            }
            if ($null -ne $Body.preBackupScript) { $s | Add-Member -NotePropertyName PreBackupScript -NotePropertyValue ([string]$Body.preBackupScript) -Force }
            if ($null -ne $Body.postBackupScript) { $s | Add-Member -NotePropertyName PostBackupScript -NotePropertyValue ([string]$Body.postBackupScript) -Force }
            $found = $true
        }
        $s
    }
    if (-not $found) { throw "Set not found: $setId" }
    Write-SyncMeSetsConfigFile -Sets @($updated)
    return "Retention and integrity policy saved for $setId."
}

function Test-SyncMeWinFsp {
    $paths = @(
        'C:\Program Files\WinFsp\bin\winfsp-x64.dll',
        'C:\Program Files (x86)\WinFsp\bin\winfsp-x64.dll',
        'C:\Program Files\WinFsp\bin\launchctl-x64.exe'
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            return @{ Ok = $true; Path = $p; Message = 'WinFsp detected.' }
        }
    }
    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc) { return @{ Ok = $true; Path = ''; Message = 'WinFsp.Launcher service present.' } }
    return @{
        Ok      = $false
        Path    = ''
        Message = 'Mount needs WinFsp (lets SyncMe show the backup as a folder).'
        Url     = 'https://winfsp.dev/rel/'
    }
}

function Test-SyncMeResticCredential {
    param([string]$SetId = '')
    $set = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $SetId
    if (-not $set) {
        return @{
            Ok      = $false
            Target  = ''
            Message = 'No backup set configured yet.'
        }
    }
    $credName = [string]$set.ResticCredentialName
    if ([string]::IsNullOrWhiteSpace($credName)) {
        $credName = if ($set.Id -and $set.Id -ne 'set1') { "SyncMeRestic-$($set.Id)" } else { 'SyncMeRestic' }
    }
    try {
        $null = Get-BackupStoredCredential -TargetName $credName
        return @{
            Ok      = $true
            Target  = $credName
            Message = 'Repository password is stored.'
        }
    } catch {
        return @{
            Ok      = $false
            Target  = $credName
            Message = 'Repository password is not stored for this set.'
        }
    }
}

function Set-SyncMeResticPassword {
    param(
        [string]$SetId,
        [Parameter(Mandatory)][string]$Password
    )
    if ([string]::IsNullOrEmpty($Password)) {
        throw 'Repository password cannot be empty.'
    }
    $set = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $SetId
    if (-not $set) { throw 'Set not found.' }
    $credName = [string]$set.ResticCredentialName
    if ([string]::IsNullOrWhiteSpace($credName)) {
        $credName = if ($set.Id -and $set.Id -ne 'set1') { "SyncMeRestic-$($set.Id)" } else { 'SyncMeRestic' }
    }
    Set-CmdKeyGeneric -Target $credName -User 'restic' -Password $Password
    return "Repository password stored for $($set.Id) ($credName)."
}

function Install-SyncMeWinFsp {
    $existing = Test-SyncMeWinFsp
    if ($existing.Ok) {
        return @{
            Ok      = $true
            Path    = $existing.Path
            Message = $existing.Message
        }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $headers = @{ 'User-Agent' = 'SyncMe' }
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/winfsp/winfsp/releases/latest' -Headers $headers
    } catch {
        throw "Could not reach GitHub to download WinFsp: $($_.Exception.Message). Download from https://winfsp.dev/rel/ then click Refresh."
    }

    $asset = @($release.assets) | Where-Object { $_.name -match '^winfsp-.*\.msi$' } | Select-Object -First 1
    if (-not $asset) {
        throw 'Could not find a WinFsp MSI in the latest GitHub release. Download from https://winfsp.dev/rel/ then click Refresh.'
    }

    $toolsDir = Join-Path $ScriptRoot 'tools'
    if (-not (Test-Path -LiteralPath $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }

    $msiPath = Join-Path $toolsDir $asset.name
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath -Headers $headers -UseBasicParsing
    } catch {
        throw "WinFsp download failed (check firewall/offline): $($_.Exception.Message). Download from https://winfsp.dev/rel/ then click Refresh."
    }

    try {
        $p = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList @('/i', "`"$msiPath`"") `
            -Verb RunAs -PassThru -Wait -ErrorAction Stop
        $code = $p.ExitCode
    } catch {
        throw "WinFsp installer did not start (UAC cancelled?). Install manually from https://winfsp.dev/rel/ then click Refresh. $($_.Exception.Message)"
    }

    # 0 = success, 3010 = success reboot required
    if ($code -ne 0 -and $code -ne 3010) {
        throw "WinFsp installer exited with code $code. Install manually from https://winfsp.dev/rel/ then click Refresh."
    }

    $after = Test-SyncMeWinFsp
    if (-not $after.Ok) {
        return @{
            Ok      = $false
            Path    = ''
            Message = 'WinFsp installer finished but WinFsp is not detected yet. Restart SyncMe or reboot if needed, then click Refresh.'
        }
    }
    return @{
        Ok      = $true
        Path    = $after.Path
        Message = "WinFsp installed successfully. $($after.Message)"
    }
}

function Test-SyncMeResticMountCommand {
    param([string]$ResticExe = '')
    # Official Windows restic builds omit "mount" (no FUSE). Detect before Start-Process.
    if ($script:ResticMountProbe -and $script:ResticMountProbe.Exe -eq $ResticExe) {
        return $script:ResticMountProbe
    }
    $exe = $ResticExe
    if ([string]::IsNullOrWhiteSpace($exe) -or $exe -eq 'restic' -or -not (Test-Path -LiteralPath $exe)) {
        $local = Join-Path $ScriptRoot 'tools\restic.exe'
        if (Test-Path -LiteralPath $local) { $exe = $local }
        else {
            $cmd = Get-Command restic -ErrorAction SilentlyContinue
            if ($cmd) { $exe = $cmd.Source } else {
                $r = @{ Ok = $false; Exe = ''; Message = 'restic not found.' }
                $script:ResticMountProbe = $r
                return $r
            }
        }
    }
    $help = ''
    try {
        $help = & $exe help 2>&1 | Out-String
    } catch {
        $r = @{ Ok = $false; Exe = $exe; Message = "Could not run restic help: $($_.Exception.Message)" }
        $script:ResticMountProbe = $r
        return $r
    }
    if ($help -match '(?m)^\s*mount\s+') {
        $r = @{ Ok = $true; Exe = $exe; Message = 'restic mount command is available.' }
    } else {
        $r = @{
            Ok      = $false
            Exe     = $exe
            Message = 'Mount is not available on Windows: official restic builds do not include the mount command. Select a snapshot and use Restore selected to copy files out.'
        }
    }
    $script:ResticMountProbe = $r
    return $r
}

function Start-SyncMeMount {
    param([string]$SetId, [string]$MountPoint = '')
    # Official Windows restic builds do not include "mount". Feature removed from the console.
    throw 'Browse-as-folder (Mount) is not available on Windows: official restic builds omit the mount command. Select a snapshot and use Restore selected (or Restore latest) to copy files out.'
}

function Stop-SyncMeMount {
    Update-SyncMeMountStatus
    if (-not $script:MountJob.Process -and -not $script:MountJob.Running) {
        return 'No active mount.'
    }
    try {
        if ($script:MountJob.Process -and -not $script:MountJob.Process.HasExited) {
            Stop-Process -Id $script:MountJob.Process.Id -Force -ErrorAction Stop
        } elseif ($script:MountJob.Pid) {
            Stop-Process -Id ([int]$script:MountJob.Pid) -Force -ErrorAction SilentlyContinue
        }
    } catch {
        throw "Could not stop mount: $($_.Exception.Message)"
    }
    $script:MountJob.Running = $false
    $script:MountJob.Message = 'Unmounted.'
    $script:MountJob.Process = $null
    Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
    return 'Mount stopped.'
}

function Update-SyncMeMountStatus {
    if ($script:MountJob.Process -and $script:MountJob.Process.HasExited) {
        $script:MountJob.Running = $false
        $script:MountJob.Message = 'Mount process ended.'
        $script:MountJob.Process = $null
    }
}

function Get-SyncMeMountStatus {
    param([string]$SetId = '')
    Update-SyncMeMountStatus
    $checkSetId = $SetId
    if ([string]::IsNullOrWhiteSpace($checkSetId) -and $script:MountJob.Running -and $script:MountJob.SetId) {
        $checkSetId = [string]$script:MountJob.SetId
    }
    $cred = Test-SyncMeResticCredential -SetId $checkSetId
    $winfsp = Test-SyncMeWinFsp
    $idleMessage = 'Use Restore selected to copy files from a snapshot (browse-as-folder Mount is not available on Windows).'
    return @{
        ok              = $true
        running         = [bool]$script:MountJob.Running
        setId           = $(if ($script:MountJob.Running) { $script:MountJob.SetId } else { $checkSetId })
        mountPoint      = $script:MountJob.MountPoint
        message         = $(if ($script:MountJob.Running) { $script:MountJob.Message } else { $idleMessage })
        winfspOk        = [bool]$winfsp.Ok
        winfspMessage   = $winfsp.Message
        winfspUrl       = $(if ($winfsp.Url) { $winfsp.Url } else { 'https://winfsp.dev/rel/' })
        resticMountOk   = $false
        resticMountMessage = 'Browse-as-folder Mount is not available on Windows with official restic. Use Restore selected.'
        resticCredOk    = [bool]$cred.Ok
        resticCredMessage = $cred.Message
        resticCredTarget  = $cred.Target
    }
}

function Install-SyncMeRclone {
    $existing = Get-SyncMeRclone
    if ($existing.Ok) {
        return @{ Ok = $true; Path = $existing.Path; Message = "rclone already available at $($existing.Path)" }
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $headers = @{ 'User-Agent' = 'SyncMe' }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/rclone/rclone/releases/latest' -Headers $headers
    $asset = @($release.assets) | Where-Object { $_.name -match 'windows-amd64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not find windows-amd64 rclone zip on GitHub.' }
    $toolsDir = Join-Path $ScriptRoot 'tools'
    if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('syncme-rclone-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    try {
        $zipPath = Join-Path $tmpDir 'rclone.zip'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmpDir -Force
        $exe = Get-ChildItem -Path $tmpDir -Filter 'rclone.exe' -Recurse | Select-Object -First 1
        if (-not $exe) { throw 'Downloaded zip did not contain rclone.exe.' }
        $dest = Join-Path $toolsDir 'rclone.exe'
        Copy-Item $exe.FullName $dest -Force
        $ver = & $dest version 2>&1 | Select-Object -First 1
        return @{ Ok = $true; Path = $dest; Message = "Installed rclone to $dest ($ver). Use Cloud (rclone) in the console to add OneDrive/Google Drive (OAuth)." }
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Send-SyncMeWakeOnLan {
    param([string]$MacAddress)
    $mac = ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($mac.Length -ne 12) { throw 'Wake-on-LAN MAC must be 12 hex digits (e.g. AA:BB:CC:DD:EE:FF).' }
    $macBytes = New-Object byte[] 6
    for ($i = 0; $i -lt 6; $i++) {
        $macBytes[$i] = [Convert]::ToByte($mac.Substring($i * 2, 2), 16)
    }
    $packet = New-Object byte[] (6 + 16 * 6)
    for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
    for ($i = 0; $i -lt 16; $i++) {
        [Array]::Copy($macBytes, 0, $packet, 6 + ($i * 6), 6)
    }
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        $udp.Send($packet, $packet.Length, (New-Object System.Net.IPEndPoint([Net.IPAddress]::Broadcast, 9))) | Out-Null
        $udp.Send($packet, $packet.Length, (New-Object System.Net.IPEndPoint([Net.IPAddress]::Broadcast, 7))) | Out-Null
    } finally {
        $udp.Close()
    }
    return "Wake-on-LAN packet sent for $MacAddress (ensure BIOS/NIC WoL is enabled on the source PC)."
}

function Stop-SyncMeBackupJob {
    Update-SyncMeBackupJob
    $killed = New-Object System.Collections.Generic.List[string]
    if ($script:BackupJob.Process -and -not $script:BackupJob.Process.HasExited) {
        $procId = $script:BackupJob.Process.Id
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            $killed.Add("host-job PID $procId")
        } catch {
            throw "Could not stop backup process $procId : $($_.Exception.Message)"
        }
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ParentProcessId -eq $procId } |
            ForEach-Object {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed.Add("child $($_.Name) $($_.ProcessId)") } catch { }
            }
    }
    # Lock-file based (scheduled / detached)
    $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    foreach ($s in $sets) {
        $lockRel = if ($s.BackupLockFile) { $s.BackupLockFile } else { "Logs\sets\$($s.Id)\backup.lock" }
        $lockPath = Join-Path $ScriptRoot $lockRel
        if (-not (Test-Path $lockPath)) { continue }
        $raw = Get-Content $lockPath -ErrorAction SilentlyContinue
        foreach ($line in $raw) {
            if ($line -match '^PID=(\d+)$') {
                $lp = [int]$Matches[1]
                if (Get-Process -Id $lp -ErrorAction SilentlyContinue) {
                    Stop-Process -Id $lp -Force -ErrorAction SilentlyContinue
                    $killed.Add("lock PID $lp")
                }
            }
        }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    $script:BackupJob.Running = $false
    $script:BackupJob.Finished = $true
    $script:BackupJob.Message = 'Backup cancelled from console.'
    Write-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $(if ($script:BackupJob.SetId) { $script:BackupJob.SetId } else { '' }) -Phase 'cancelled' -Message 'Cancelled from console.' -RunId '' -JsonLog ''
    if ($killed.Count -eq 0) { return 'No running backup process found (may already have finished).' }
    return ('Stopped: ' + ($killed -join '; '))
}

function Start-SyncMeRestoreJob {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Snapshot,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$Include = '',
        [string]$SetId = 'set1'
    )
    Update-SyncMeRestoreJob
    if ($script:RestoreJob.Running -and $script:RestoreJob.Process -and -not $script:RestoreJob.Process.HasExited) {
        throw 'A restore is already running. Cancel it first, or wait for it to finish.'
    }
    $bakStatus = Get-SyncMeBackupStatusPayload -SetId $SetId
    if ($bakStatus.running) {
        throw 'Cannot restore while a backup is running (restic repository lock). Wait for the backup to finish.'
    }

    $uncCheck = Test-SyncMeSnapshotHasUncPaths -Config $Config -Snapshot $Snapshot
    if ($uncCheck.HasUnc) { throw $uncCheck.Message }

    $safe = Test-SyncMeRestoreTargetSafe -TargetPath $TargetPath -ResticRepo $Config.ResticRepo
    if (-not $safe.Ok) { throw $safe.Message }

    $statusDir = Join-Path $ScriptRoot ("Logs\sets\$SetId")
    if (-not (Test-Path -LiteralPath $statusDir)) {
        New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
    }
    $statusFile = Join-Path $statusDir 'restore-status.json'
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', (Join-Path $ScriptRoot 'SyncMe-Restore.ps1'),
        '-SetId', $SetId,
        '-Snapshot', $Snapshot,
        '-Target', $safe.FullPath,
        '-StatusFile', $statusFile
    )
    if (-not [string]::IsNullOrWhiteSpace($Include)) {
        $args += @('-Include', $Include.Trim())
    }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
    $script:RestoreJob = @{
        Running    = $true
        Finished   = $false
        ExitCode   = $null
        Message    = "Restore started (snapshot $Snapshot)."
        Detail     = "PID $($p.Id)"
        Started    = Get-Date
        Process    = $p
        SetId      = $SetId
        Snapshot   = $Snapshot
        Target     = $safe.FullPath
        StatusFile = $statusFile
    }
    return $script:RestoreJob.Message
}

function Update-SyncMeRestoreJob {
    if (-not $script:RestoreJob.Process) { return }
    if ($script:RestoreJob.Process.HasExited) {
        $script:RestoreJob.Running = $false
        $script:RestoreJob.Finished = $true
        $script:RestoreJob.ExitCode = $script:RestoreJob.Process.ExitCode
        $fileMsg = ''
        if ($script:RestoreJob.StatusFile -and (Test-Path -LiteralPath $script:RestoreJob.StatusFile)) {
            try {
                $st = Get-Content -LiteralPath $script:RestoreJob.StatusFile -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($st.message) { $fileMsg = [string]$st.message }
                if ($null -ne $st.exitCode) { $script:RestoreJob.ExitCode = [int]$st.exitCode }
            } catch { }
        }
        if ($fileMsg) {
            $script:RestoreJob.Message = $fileMsg
        } else {
            $code = $script:RestoreJob.ExitCode
            $script:RestoreJob.Message = if ($code -eq 0) {
                "Restore finished to $($script:RestoreJob.Target)."
            } else {
                "Restore finished with exit $code."
            }
        }
        $script:RestoreJob.Detail = ''
    }
}

function Stop-SyncMeRestoreJob {
    Update-SyncMeRestoreJob
    $killed = New-Object System.Collections.Generic.List[string]
    if ($script:RestoreJob.Process -and -not $script:RestoreJob.Process.HasExited) {
        $procId = $script:RestoreJob.Process.Id
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            $killed.Add("restore PID $procId")
        } catch {
            throw "Could not stop restore process $procId : $($_.Exception.Message)"
        }
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ParentProcessId -eq $procId } |
            ForEach-Object {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed.Add("child $($_.Name) $($_.ProcessId)") } catch { }
            }
    }
    $script:RestoreJob.Running = $false
    $script:RestoreJob.Finished = $true
    $script:RestoreJob.Message = 'Restore cancelled from console.'
    if ($script:RestoreJob.StatusFile) {
        try {
            @{
                running  = $false
                finished = $true
                success  = $false
                message  = 'Restore cancelled from console.'
                target   = $script:RestoreJob.Target
                exitCode = -1
                setId    = $script:RestoreJob.SetId
                snapshot = $script:RestoreJob.Snapshot
                updated  = (Get-Date).ToUniversalTime().ToString('o')
            } | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:RestoreJob.StatusFile -Encoding UTF8
        } catch { }
    }
    if ($killed.Count -eq 0) { return 'No running restore process found (may already have finished).' }
    return ('Stopped: ' + ($killed -join '; '))
}

function Get-SyncMeRestoreStatusPayload {
    Update-SyncMeRestoreJob
    $msg = $script:RestoreJob.Message
    $success = $null
    if ($script:RestoreJob.StatusFile -and (Test-Path -LiteralPath $script:RestoreJob.StatusFile)) {
        try {
            $st = Get-Content -LiteralPath $script:RestoreJob.StatusFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($st.message) { $msg = [string]$st.message }
            if ($null -ne $st.success) { $success = [bool]$st.success }
        } catch { }
    }
    return @{
        ok        = $true
        running   = [bool]$script:RestoreJob.Running
        finished  = [bool]$script:RestoreJob.Finished
        exitCode  = $script:RestoreJob.ExitCode
        message   = $msg
        detail    = $script:RestoreJob.Detail
        target    = $script:RestoreJob.Target
        snapshot  = $script:RestoreJob.Snapshot
        setId     = $script:RestoreJob.SetId
        success   = $success
    }
}

function Remove-SyncMeBackupSet {
    param([string]$SetId)
    if ([string]::IsNullOrWhiteSpace($SetId)) { throw 'setId required.' }
    $sets = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)) {
        if ($s.Id -ne $SetId) { $sets.Add($s) | Out-Null }
    }
    if ($sets.Count -eq (@(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)).Count) {
        throw "Set not found: $SetId"
    }
    if ($sets.Count -eq 0) { throw 'Cannot delete the last backup set. Re-run setup instead.' }

    $taskName = if ($SetId -eq 'set1') { 'SyncMe-Backup' } else { "SyncMe-Backup-$SetId" }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Write-SyncMeSetsConfigFile -Sets @($sets)
    return "Deleted backup set $SetId and removed task $taskName (restic repo on disk was not deleted)."
}

function Update-SyncMeSetResticPath {
    param([string]$SetId, [string]$ResticPath)
    if ([string]::IsNullOrWhiteSpace($SetId)) { throw 'setId required.' }
    $rp = [string]$ResticPath
    if ([string]::IsNullOrWhiteSpace($rp)) { throw 'resticPath is required.' }
    if ($rp -ne 'restic' -and -not (Test-Path -LiteralPath $rp)) {
        throw "restic path not found: $rp"
    }
    $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    if ($sets.Count -eq 0) { throw 'No backup sets configured.' }
    $found = $false
    $updated = foreach ($s in $sets) {
        if ($s.Id -eq $SetId) {
            $s | Add-Member -NotePropertyName ResticPath -NotePropertyValue $rp -Force
            $found = $true
        }
        $s
    }
    if (-not $found) { throw "Set not found: $SetId" }
    Write-SyncMeSetsConfigFile -Sets @($updated)
    return "Updated ResticPath for $SetId to '$rp'."
}

function Invoke-SyncMeSetupApply {
    param($Body)

    $pathsRaw = [string]$Body.sourcePaths
    $sourcePaths = @($pathsRaw -split '[\r\n,]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($sourcePaths.Count -eq 0) { throw 'Add at least one source folder (local path or UNC).' }

    $resticRepo = ([string]$Body.resticRepo).Trim()
    $archivePath = ([string]$Body.archivePath).Trim()
    $resticPassword = [string]$Body.resticPassword

    $destType = 'local'
    if ($Body.destinationType) { $destType = [string]$Body.destinationType }
    $networkMode = 'both'
    if ($Body.networkMode) { $networkMode = [string]$Body.networkMode }

    if ($destType -ne 'rclone') {
        if ([string]::IsNullOrWhiteSpace($resticRepo)) {
            throw 'Enter restic repository destination (full path on this Backup PC, or a NAS UNC path).'
        }
        if ($resticRepo -notmatch '^[A-Za-z]:\\' -and $resticRepo -notmatch '^\\\\[^\\]+\\[^\\]+') {
            throw 'Repository must be a full path (e.g. D:\Backups\repo) or a UNC path (\\server\share\repo). Relative paths are not allowed.'
        }
        if ($archivePath -and $archivePath -notmatch '^[A-Za-z]:\\' -and $archivePath -notmatch '^\\\\[^\\]+\\[^\\]+') {
            throw 'Archive path must be a full path or UNC when set. Leave it blank to skip.'
        }
        if ($archivePath) {
            $archSafe = Test-SyncMeArchivePathSafe -ArchivePath $archivePath
            if (-not $archSafe.Ok) { throw $archSafe.Message }
        }
    }

    $hasUncSource = $false
    foreach ($sp in $sourcePaths) {
        if ($sp -match '^\\\\[^\\]+\\[^\\]+') {
            $hasUncSource = $true
        } elseif ($sp -notmatch '^[A-Za-z]:\\') {
            throw "Source path must be a local folder (e.g. D:\Data) or UNC share (e.g. \\pc-name\share). Got: $sp"
        }
    }
    $sourceHost = if ($Body.sourceHost) { ([string]$Body.sourceHost).Trim() } else { '' }
    if ($hasUncSource -and [string]::IsNullOrWhiteSpace($sourceHost)) {
        throw 'Enter the source computer name when using UNC paths (or use local paths only).'
    }

    $existing = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    $setId = if ($Body.setId) { [string]$Body.setId } else { '' }
    $isNew = ($Body.isNewSet -eq $true) -or [string]::IsNullOrWhiteSpace($setId)
    if ($isNew -or -not $setId) {
        $n = $existing.Count + 1
        $setId = 'set{0}' -f $n
        while ($existing | Where-Object { $_.Id -eq $setId }) {
            $n++
            $setId = 'set{0}' -f $n
        }
        $isNew = $true
    }

    if ($isNew -and [string]::IsNullOrEmpty($resticPassword)) {
        throw 'restic password required for a new backup set.'
    }

    $displayName = if ($Body.displayName) { [string]$Body.displayName } else { "Backup set $($setId.Replace('set',''))" }
    $runTime = if ($Body.runTime) { [string]$Body.runTime } else { '01:00' }
    $schedStart = if ($Body.scheduleStartDate) { [string]$Body.scheduleStartDate } else { (Get-Date).ToString('yyyy-MM-dd') }
    $schedRec = if ($Body.scheduleRecurrence) { [string]$Body.scheduleRecurrence } else { 'Daily' }
    if ($schedRec -notin @('Once', 'Daily', 'Weekly')) { $schedRec = 'Daily' }
    $schedEnd = if ($Body.scheduleEndDate) { [string]$Body.scheduleEndDate } else { '' }
    $schedDays = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
    if ($Body.scheduleDaysOfWeek) {
        if ($Body.scheduleDaysOfWeek -is [string]) {
            $schedDays = @($Body.scheduleDaysOfWeek.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } else {
            $schedDays = @($Body.scheduleDaysOfWeek | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
        if ($schedDays.Count -eq 0) {
            $schedDays = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
        }
    }

    $createFolders = $true
    if ($null -ne $Body.createFolders) { $createFolders = [bool]$Body.createFolders }
    if ($createFolders -and $destType -ne 'rclone') {
        foreach ($d in @($resticRepo, $archivePath)) {
            if ($d -and $d -notmatch '^rclone:' -and -not (Test-Path -LiteralPath $d)) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }
        }
    }
    foreach ($d in @('Logs', 'Reports', "Logs\sets\$setId")) {
        $p = Join-Path $ScriptRoot $d
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }

    $resticCred = if ($setId -eq 'set1') { 'SyncMeRestic' } else { "SyncMeRestic-$setId" }
    if (-not [string]::IsNullOrEmpty($resticPassword)) {
        Set-CmdKeyGeneric -Target $resticCred -User 'restic' -Password $resticPassword
    }

    $shareCred = ''
    if ($Body.storeShare -eq $true) {
        $shareCred = if ($setId -eq 'set1') { 'SyncMeShare' } else { "SyncMeShare-$setId" }
        Set-CmdKeyGeneric -Target $shareCred -User ([string]$Body.shareUser) -Password ([string]$Body.sharePassword)
    } else {
        $prev = $existing | Where-Object { $_.Id -eq $setId } | Select-Object -First 1
        if ($prev -and $prev.ShareCredentialName) { $shareCred = [string]$prev.ShareCredentialName }
    }

    $enableEmail = ($Body.enableEmail -eq $true)
    if ($enableEmail -and -not [string]::IsNullOrEmpty([string]$Body.smtpPassword)) {
        $smtpUser = if ($Body.smtpUser) { [string]$Body.smtpUser } else { [string]$Body.mailFrom }
        Set-CmdKeyGeneric -Target 'SyncMeSmtp' -User $smtpUser -Password ([string]$Body.smtpPassword)
    }

    if ($destType -eq 'rclone') {
        $rclone = Get-SyncMeRclone
        if (-not $rclone.Ok) { throw 'rclone not found. Use Prerequisites -> Install rclone, then add a cloud remote in the console.' }
        if ($resticRepo -notmatch '^rclone:') { throw 'Cloud destination must look like rclone:remote:path' }
    }

    $resticPathIn = if ($Body.resticPath) { [string]$Body.resticPath } else { 'restic' }
    $resticExe = $resticPathIn
    if ($resticExe -eq 'restic' -or -not (Test-Path -LiteralPath $resticExe)) {
        $resolved = Get-ResticOnPath
        if (-not $resolved.Ok) {
            throw 'restic not found. Use Prerequisites -> Install restic (downloads into SyncMe\tools).'
        }
        $resticExe = $resolved.Path
    }

    # Ensure rclone on PATH + SyncMe config for cloud init
    if ($destType -eq 'rclone' -or $resticRepo -match '^rclone:') {
        $tools = Join-Path $ScriptRoot 'tools'
        if (Test-Path $tools) { $env:PATH = "$tools;$env:PATH" }
        $env:RCLONE_CONFIG = Get-SyncMeRcloneConfigPath
    }

    $plainForInit = $resticPassword
    if ([string]::IsNullOrEmpty($plainForInit)) {
        try {
            $credObj = Get-BackupStoredCredential -TargetName $resticCred
            $plainForInit = $credObj.GetNetworkCredential().Password
        } catch {
            throw 'restic password required (or existing credential missing).'
        }
    }

    $env:RESTIC_PASSWORD = $plainForInit
    $env:RESTIC_REPOSITORY = $resticRepo
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $needInit = $true
        if ($destType -ne 'rclone' -and $resticRepo -notmatch '^rclone:') {
            $localConfig = Join-Path $resticRepo 'config'
            if (Test-Path -LiteralPath $localConfig) {
                $needInit = $false
            }
        } else {
            $null = & $resticExe snapshots 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) { $needInit = $false }
        }
        if ($needInit) {
            $initOut = & $resticExe init 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                $detail = ($initOut).Trim()
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'unknown error' }
                throw "restic init failed: $detail"
            }
        }
    } finally {
        $ErrorActionPreference = $prevEap
        Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
    }

    $configResticPath = 'restic'
    if ($resticPathIn -ne 'restic' -and (Test-Path -LiteralPath $resticPathIn)) {
        $configResticPath = $resticPathIn
    } elseif ($resticExe -and $resticExe -ne 'restic' -and (Test-Path -LiteralPath $resticExe)) {
        $configResticPath = $resticExe
    } else {
        $again = Get-ResticOnPath
        if ($again.Ok) { $configResticPath = $again.Path }
    }

    $mailTo = @()
    if ($Body.mailTo) {
        $mailTo = @($Body.mailTo.ToString().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ($mailTo.Count -eq 0 -and $Body.mailFrom) { $mailTo = @([string]$Body.mailFrom) }

    $smtpPort = 587
    if ($Body.smtpPort) { [void][int]::TryParse([string]$Body.smtpPort, [ref]$smtpPort) }

    $prevExcludes = @()
    $prevForEx = $existing | Where-Object { $_.Id -eq $setId } | Select-Object -First 1
    if ($prevForEx -and $prevForEx.ExcludePatterns) { $prevExcludes = @($prevForEx.ExcludePatterns) }
    $excludePatterns = @(Merge-SyncMeExcludePatterns -Existing $prevExcludes)

    $newSet = [pscustomobject]@{
        Id                       = $setId
        DisplayName              = $displayName
        NetworkMode              = $networkMode
        DestinationType          = $destType
        RunTime                  = $runTime
        ScheduleStartDate        = $schedStart
        ScheduleRecurrence       = $schedRec
        ScheduleEndDate          = $schedEnd
        ScheduleDaysOfWeek       = $schedDays
        SourcePaths              = $sourcePaths
        ShareCredentialName      = $shareCred
        ResticRepo               = $resticRepo
        ArchivePath              = $archivePath
        ResticCredentialName     = $resticCred
        ResticPath               = $configResticPath
        KeepLast                 = $(if ($null -ne $Body.keepLast) { [int]$Body.keepLast } else { 7 })
        KeepDaily                = $(if ($null -ne $Body.keepDaily) { [int]$Body.keepDaily } else { 14 })
        KeepWeekly               = $(if ($null -ne $Body.keepWeekly) { [int]$Body.keepWeekly } else { 8 })
        KeepMonthly              = $(if ($null -ne $Body.keepMonthly) { [int]$Body.keepMonthly } else { 6 })
        EnableRepoCheck          = ($Body.enableRepoCheck -ne $false)
        WeeklyDataCheckDay       = $(if ($Body.weeklyDataCheckDay) { [string]$Body.weeklyDataCheckDay } else { 'Sunday' })
        ResticLimitUploadKByte   = $(if ($null -ne $Body.resticLimitUploadKByte) { [int]$Body.resticLimitUploadKByte } else { 0 })
        RclonePath               = $(if ($destType -eq 'rclone') { (Get-SyncMeRclone).Path } else { '' })
        RcloneConfigPath         = $(if ($destType -eq 'rclone') { Get-SyncMeRcloneConfigPath } else { '' })
        RcloneBwLimit            = $(if ($Body.rcloneBwLimit) { [string]$Body.rcloneBwLimit } else { 'off' })
        RcloneTransfers          = $(if ($null -ne $Body.rcloneTransfers) { [int]$Body.rcloneTransfers } else { 4 })
        RcloneCheckers           = $(if ($null -ne $Body.rcloneCheckers) { [int]$Body.rcloneCheckers } else { 8 })
        RcloneRetries            = $(if ($null -ne $Body.rcloneRetries) { [int]$Body.rcloneRetries } else { 3 })
        RcloneLowLevelRetries    = $(if ($null -ne $Body.rcloneLowLevelRetries) { [int]$Body.rcloneLowLevelRetries } else { 10 })
        RcloneMultiThreadStreams = $(if ($null -ne $Body.rcloneMultiThreadStreams) { [int]$Body.rcloneMultiThreadStreams } else { 4 })
        EnableToastNotifications = ($Body.enableToast -eq $true)
        EnableEmailNotifications = $enableEmail
        SmtpServer               = [string]$Body.smtpServer
        SmtpPort                 = $smtpPort
        SmtpUseSsl               = ($Body.smtpSsl -ne $false)
        MailFrom                 = [string]$Body.mailFrom
        MailTo                   = $mailTo
        SourceHost               = $sourceHost
        UseShadowCopySources     = ($Body.useShadowCopy -ne $false)
        EnableWakeOnLan          = ($Body.enableWakeOnLan -eq $true)
        WakeMacAddress           = $(if ($Body.wakeMac) { [string]$Body.wakeMac } else { '' })
        ArchiveStampFile         = "Logs\sets\$setId\last-archive-utc.txt"
        LastSuccessStampFile     = "Logs\sets\$setId\last-success-utc.txt"
        BackupLockFile           = "Logs\sets\$setId\backup.lock"
        ExcludePatterns          = $excludePatterns
    }

    $merged = [System.Collections.Generic.List[object]]::new()
    $replaced = $false
    foreach ($s in $existing) {
        if ($s.Id -eq $setId) {
            $merged.Add($newSet) | Out-Null
            $replaced = $true
        } else {
            $merged.Add($s) | Out-Null
        }
    }
    if (-not $replaced) { $merged.Add($newSet) | Out-Null }

    Write-SyncMeSetsConfigFile -Sets @($merged)

    $taskName = if ($setId -eq 'set1') { 'SyncMe-Backup' } else { "SyncMe-Backup-$setId" }
    $logonType = 'Password'
    if ($Body.logonType -eq 'Interactive') { $logonType = 'Interactive' }
    $taskPassword = if ($Body.windowsPassword) { [string]$Body.windowsPassword } else { '' }
    if ($logonType -eq 'Password' -and [string]::IsNullOrEmpty($taskPassword)) {
        throw 'Windows account password is required to register an unattended task (run whether logged on or not). Required for Windows Server.'
    }
    $regArgs = @{
        TaskName   = $taskName
        Time       = $runTime
        SetId      = $setId
        LogonType  = $logonType
        UserId     = $env:USERNAME
        Recurrence = $schedRec
        StartDate  = $schedStart
        EndDate    = $schedEnd
        DaysOfWeek = $schedDays
    }
    if ($logonType -eq 'Password') {
        $regArgs['TaskPassword'] = $taskPassword
    }
    if ($setId -eq 'set1') {
        $regArgs['RegisterWatchdog'] = $true
        $regArgs['WatchdogTime'] = '09:00'
    }
    & (Join-Path $ScriptRoot 'Register-BackupTask.ps1') @regArgs

    $operator = 'friend'
    if ($Body.operatorName) { $operator = [string]$Body.operatorName }
    $markerObj = @{
        completedUtc = (Get-Date).ToUniversalTime().ToString('o')
        operatorName = $operator
        computerName = $env:COMPUTERNAME
        product      = 'SyncMe'
        setId        = $setId
        displayName  = $displayName
    }
    $markerDir = Join-Path $ScriptRoot "Logs\sets\$setId"
    if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
    ($markerObj | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $markerDir 'setup-complete.json') -Encoding UTF8
    if ($setId -eq 'set1') {
        ($markerObj | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $ScriptRoot 'Logs\syncme-setup-complete.json') -Encoding UTF8
    }

    return @{
        message     = "Configured '$displayName' ($setId). $schedRec task $taskName at $runTime ($logonType logon)."
        setId       = $setId
        displayName = $displayName
    }
}

function Invoke-SyncMeScheduleUpdate {
    param($Body)
    $setId = if ($Body.setId) { [string]$Body.setId } else { 'set1' }
    $runTime = [string]$Body.runTime
    if ($runTime -notmatch '^\d{1,2}:\d{2}$') { throw 'Use time format HH:mm.' }
    $schedStart = if ($Body.scheduleStartDate) { [string]$Body.scheduleStartDate } else { (Get-Date).ToString('yyyy-MM-dd') }
    $schedRec = if ($Body.scheduleRecurrence) { [string]$Body.scheduleRecurrence } else { 'Daily' }
    if ($schedRec -notin @('Once', 'Daily', 'Weekly')) { throw 'Recurrence must be Once, Daily, or Weekly.' }
    $schedEnd = if ($Body.scheduleEndDate) { [string]$Body.scheduleEndDate } else { '' }
    $schedDays = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
    if ($Body.scheduleDaysOfWeek) {
        if ($Body.scheduleDaysOfWeek -is [string]) {
            $schedDays = @($Body.scheduleDaysOfWeek.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } else {
            $schedDays = @($Body.scheduleDaysOfWeek | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
    }

    $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    if ($sets.Count -eq 0) { throw 'No backup sets configured.' }
    $found = $false
    $updated = foreach ($s in $sets) {
        if ($s.Id -eq $setId) {
            $s | Add-Member -NotePropertyName RunTime -NotePropertyValue $runTime -Force
            $s | Add-Member -NotePropertyName ScheduleStartDate -NotePropertyValue $schedStart -Force
            $s | Add-Member -NotePropertyName ScheduleRecurrence -NotePropertyValue $schedRec -Force
            $s | Add-Member -NotePropertyName ScheduleEndDate -NotePropertyValue $schedEnd -Force
            $s | Add-Member -NotePropertyName ScheduleDaysOfWeek -NotePropertyValue $schedDays -Force
            $found = $true
        }
        $s
    }
    if (-not $found) { throw "Unknown set: $setId" }

    Write-SyncMeSetsConfigFile -Sets @($updated)

    $taskName = if ($setId -eq 'set1') { 'SyncMe-Backup' } else { "SyncMe-Backup-$setId" }
    $logonType = 'Password'
    if ($Body.logonType -eq 'Interactive') { $logonType = 'Interactive' }
    $taskPassword = if ($Body.windowsPassword) { [string]$Body.windowsPassword } else { '' }
    if ($logonType -eq 'Password' -and [string]::IsNullOrEmpty($taskPassword)) {
        throw 'Windows account password is required to update an unattended scheduled task.'
    }
    $regArgs = @{
        TaskName   = $taskName
        Time       = $runTime
        SetId      = $setId
        LogonType  = $logonType
        UserId     = $env:USERNAME
        Recurrence = $schedRec
        StartDate  = $schedStart
        EndDate    = $schedEnd
        DaysOfWeek = $schedDays
    }
    if ($logonType -eq 'Password') {
        $regArgs['TaskPassword'] = $taskPassword
    }
    & (Join-Path $ScriptRoot 'Register-BackupTask.ps1') @regArgs

    return "Schedule for $setId updated to $schedRec at $runTime (task $taskName, logon $logonType)."
}

function Start-SyncMeBackupJob {
    param([string]$Mode, [string]$SetId = 'set1')
    if ($script:BackupJob.Running -and $script:BackupJob.Process -and -not $script:BackupJob.Process.HasExited) {
        throw 'A backup is already running.'
    }
    $set = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $SetId
    if ($set -and $set.EnableWakeOnLan -and $set.WakeMacAddress) {
        try { Send-SyncMeWakeOnLan -MacAddress ([string]$set.WakeMacAddress) | Out-Null } catch { }
        Start-Sleep -Seconds 8
    }
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', (Join-Path $ScriptRoot 'SyncMe-Backup.ps1'),
        '-SetId', $SetId
    )
    switch ($Mode) {
        'whatIf' { $args += '-WhatIf' }
        'forceArchive' { $args += '-ForceArchive' }
        'checkOnly' { $args += @('-SkipArchive', '-SkipPrune', '-CheckOnly') }
        'dataCheck' { $args += @('-SkipArchive', '-SkipPrune', '-CheckOnly', '-RunDataCheck') }
        'pruneOnly' { $args += @('-SkipArchive', '-PruneOnly', '-SkipCheck') }
    }
    Write-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $SetId -Phase 'starting' -Message 'Starting backup job...' -RunId '' -JsonLog ''
    # Detached process: survives SyncMe console close; progress still via live-progress.json / lock
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
    $script:BackupJob = @{
        Running  = $true
        Finished = $false
        ExitCode = $null
        Message  = 'Backup started (runs even if you close SyncMe).'
        Detail   = "PID $($p.Id)"
        Started  = Get-Date
        Process  = $p
        SetId    = $SetId
    }
    return $script:BackupJob.Message
}

function Update-SyncMeBackupJob {
    if (-not $script:BackupJob.Process) { return }
    if ($script:BackupJob.Process.HasExited) {
        $script:BackupJob.Running = $false
        $script:BackupJob.Finished = $true
        $script:BackupJob.ExitCode = $script:BackupJob.Process.ExitCode
        $script:BackupJob.Message = "Backup finished (exit $($script:BackupJob.ExitCode))."
        $script:BackupJob.Detail = ''
    }
}

function Get-SyncMeBackupStatusPayload {
    param([string]$SetId = '')
    Update-SyncMeBackupJob
    $preferSet = $SetId
    if ([string]::IsNullOrWhiteSpace($preferSet) -and $script:BackupJob.SetId) {
        $preferSet = [string]$script:BackupJob.SetId
    }
    $live = Read-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $preferSet
    $phase = if ($live) { [string]$live.phase } else { '' }
    $msg = if ($live) { [string]$live.message } else { $script:BackupJob.Message }

    $running = [bool]$script:BackupJob.Running
    if (-not $running) {
        $setsToCheck = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
        if (-not [string]::IsNullOrWhiteSpace($preferSet)) {
            $setsToCheck = @($setsToCheck | Where-Object { $_.Id -eq $preferSet })
            if ($setsToCheck.Count -eq 0) {
                $setsToCheck = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
            }
        }
        foreach ($s in $setsToCheck) {
            $lockRel = if ($s.BackupLockFile) { $s.BackupLockFile } else { "Logs\sets\$($s.Id)\backup.lock" }
            $lockPath = Join-Path $ScriptRoot $lockRel
            if (-not (Test-Path $lockPath)) { continue }
            $raw = Get-Content $lockPath -ErrorAction SilentlyContinue
            foreach ($line in $raw) {
                if ($line -match '^PID=(\d+)$' -and (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)) {
                    $running = $true
                    if (-not $msg) { $msg = "Backup running (PID $($Matches[1]))" }
                    if (-not $live) {
                        $live = Read-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $s.Id
                        if ($live) {
                            $phase = [string]$live.phase
                            $msg = [string]$live.message
                        }
                    }
                }
            }
        }
    }

    $percent = $null
    $bytesDone = $null
    $totalBytes = $null
    $filesDone = $null
    $totalFiles = $null
    $detail = $script:BackupJob.Detail
    $progressMode = ''
    $updatedUtc = ''
    if ($live) {
        if ($null -ne $live.percent) {
            try { $percent = [double]$live.percent } catch { $percent = $null }
        }
        if ($null -ne $live.bytesDone) {
            try { $bytesDone = [long]$live.bytesDone } catch { }
        }
        if ($null -ne $live.totalBytes) {
            try { $totalBytes = [long]$live.totalBytes } catch { }
        }
        if ($null -ne $live.filesDone) {
            try { $filesDone = [long]$live.filesDone } catch { }
        }
        if ($null -ne $live.totalFiles) {
            try { $totalFiles = [long]$live.totalFiles } catch { }
        }
        if ($live.detail) { $detail = [string]$live.detail }
        if ($live.progressMode) { $progressMode = [string]$live.progressMode }
        if ($live.updatedUtc) { $updatedUtc = [string]$live.updatedUtc }
    }

    return @{
        ok           = $true
        running      = $running
        finished     = [bool]$script:BackupJob.Finished
        exitCode     = $script:BackupJob.ExitCode
        message      = $msg
        detail       = $detail
        setId        = $(if ($script:BackupJob.SetId) { $script:BackupJob.SetId } elseif ($live) { $live.setId } else { $preferSet })
        phase        = $phase
        percent      = $percent
        bytesDone    = $bytesDone
        totalBytes   = $totalBytes
        filesDone    = $filesDone
        totalFiles   = $totalFiles
        progressMode = $progressMode
        updatedUtc   = $updatedUtc
    }
}

function Get-MimeType {
    param([string]$Path)
    switch -Regex ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '\.html?' { return 'text/html; charset=utf-8' }
        '\.css'   { return 'text/css; charset=utf-8' }
        '\.js'    { return 'application/javascript; charset=utf-8' }
        '\.json'  { return 'application/json; charset=utf-8' }
        '\.svg'   { return 'image/svg+xml' }
        '\.png'   { return 'image/png' }
        default   { return 'application/octet-stream' }
    }
}

function Send-StaticFile {
    param([string]$RelPath, $Response)
    $safe = $RelPath -replace '/', '\'
    if ($safe.StartsWith('\')) { $safe = $safe.Substring(1) }
    $full = [IO.Path]::GetFullPath((Join-Path $UiRoot $safe))
    $rootFull = [IO.Path]::GetFullPath($UiRoot)
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        $Response.StatusCode = 403
        $Response.Close()
        return
    }
    if (-not (Test-Path -LiteralPath $full)) {
        $Response.StatusCode = 404
        $Response.Close()
        return
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    $Response.StatusCode = 200
    $Response.ContentType = Get-MimeType $full
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

# --- listener ---
$url = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)
try {
    $listener.Start()
} catch {
    Write-Host "Could not bind $url - is SyncMe already running?" -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 1
}

Write-Host ""
Write-Host "  SyncMe is running" -ForegroundColor Cyan
Write-Host "  Open: $url" -ForegroundColor Green
Write-Host "  Copyright (c) 2026 Bradford Lotriet (brad@web-zilla.co.za)" -ForegroundColor DarkCyan
Write-Host "  Free to use - keep this credit. See LICENSE.txt" -ForegroundColor DarkCyan
Write-Host "  Close this window to stop SyncMe." -ForegroundColor Yellow
Write-Host ""

$openUrl = $url
if ($OpenView -eq 'setup') { $openUrl = "${url}?view=setup" }
elseif ($OpenView -eq 'console') { $openUrl = "${url}?view=console" }

if (-not $NoBrowser) {
    Start-Process $openUrl
}

try {
    $null = Send-SyncMeLocalOpsRegister -ScriptRoot $ScriptRoot
} catch { }

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        try {
            $path = $req.Url.AbsolutePath
            Update-SyncMeBackupJob

            if ($path -eq '/' -or $path -eq '/index.html') {
                Send-StaticFile -RelPath 'index.html' -Response $res
                continue
            }
            if ($path.StartsWith('/ui/')) {
                Send-StaticFile -RelPath $path.Substring(4) -Response $res
                continue
            }

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
                continue
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
                continue
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
                    } -Response $res
                } catch {
                    Write-SyncMeJson @{
                        ok              = $false
                        updateAvailable = $false
                        message         = $_.Exception.Message
                        currentVersion  = (Get-SyncMePackageVersion)
                    } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/update/install' -and $req.HttpMethod -eq 'POST') {
                try {
                    $info = Get-SyncMeUpdateInfo -ScriptRoot $ScriptRoot -CurrentVersion (Get-SyncMePackageVersion)
                    if (-not $info.UpdateAvailable) {
                        Write-SyncMeJson @{
                            ok      = $false
                            message = "Already on latest version ($($info.CurrentVersion))."
                        } -StatusCode 400 -Response $res
                        continue
                    }
                    $result = Start-SyncMeUpdateApply -ScriptRoot $ScriptRoot -UpdateInfo $info
                    Write-SyncMeJson @{
                        ok      = $true
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
                continue
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
                continue
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
                    if (-not [string]::IsNullOrWhiteSpace([string]$saved.MonitorUrl)) {
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
                        if ($hb.Ok) { $parts += 'Monitor test heartbeat OK.' }
                        else { $parts += ('Monitor test failed: ' + [string]$hb.Message) }
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
                continue
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
                continue
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
                continue
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
                continue
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
                continue
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
                continue
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
                continue
            }

            if ($path -eq '/api/schedule' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Invoke-SyncMeScheduleUpdate -Body $body
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
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
                continue
            }

            if ($path -eq '/api/backup/status' -and $req.HttpMethod -eq 'GET') {
                $qSet = $req.QueryString['setId']
                Write-SyncMeJson (Get-SyncMeBackupStatusPayload -SetId $(if ($qSet) { [string]$qSet } else { '' })) -Response $res
                continue
            }

            if ($path -eq '/api/snapshots' -and $req.HttpMethod -eq 'GET') {
                $qSet = $req.QueryString['setId']
                $cfg = if ($qSet) { Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $qSet } else { Get-SyncMeConfigOrNull }
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Not configured yet.' } -StatusCode 400 -Response $res
                    continue
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
                continue
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
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($qSnap)) {
                    Write-SyncMeJson @{ ok = $false; message = 'Query parameter snapshot is required.' } -StatusCode 400 -Response $res
                    continue
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
                        continue
                    }
                    if ($script:RestoreJob.Running) {
                        Write-SyncMeJson @{
                            ok = $false
                            message = 'Cannot browse while a restore is running. Wait or cancel the restore first.'
                        } -StatusCode 409 -Response $res
                        continue
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
                        continue
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
                        continue
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
                continue
            }

            if ($path -eq '/api/restore' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                $setId = if ($body.setId) { [string]$body.setId } else { 'set1' }
                $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $setId
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Not configured yet.' } -StatusCode 400 -Response $res
                    continue
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
                continue
            }

            if ($path -eq '/api/restore/status' -and $req.HttpMethod -eq 'GET') {
                Write-SyncMeJson (Get-SyncMeRestoreStatusPayload) -Response $res
                continue
            }

            if ($path -eq '/api/restore/cancel' -and $req.HttpMethod -eq 'POST') {
                try {
                    $msg = Stop-SyncMeRestoreJob
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/snapshot/delete' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                $setId = if ($body.setId) { [string]$body.setId } else { 'set1' }
                $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $setId
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Not configured yet.' } -StatusCode 400 -Response $res
                    continue
                }
                if ($cfg.AppendOnly) {
                    Write-SyncMeJson @{
                        ok      = $false
                        message = 'Append-Only Mode is enabled for this set. Snapshot deletion is blocked.'
                    } -StatusCode 400 -Response $res
                    continue
                }
                try {
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
                continue
            }

            if ($path -eq '/api/set' -and $req.HttpMethod -eq 'GET') {
                $qSet = $req.QueryString['setId']
                $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $(if ($qSet) { $qSet } else { '' })
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Set not found.' } -StatusCode 404 -Response $res
                    continue
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
                continue
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
                continue
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
                continue
            }

            if ($path -eq '/api/rclone/authorize/cancel' -and $req.HttpMethod -eq 'POST') {
                try {
                    $msg = Stop-SyncMeRcloneAuthorize
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/rclone/authorize' -and $req.HttpMethod -eq 'GET') {
                try {
                    Write-SyncMeJson (Get-SyncMeRcloneAuthorizeStatus) -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/rclone/ls' -and $req.HttpMethod -eq 'GET') {
                try {
                    $rp = $req.QueryString['path']
                    $dirs = @(Get-SyncMeRcloneLs -RemotePath $rp)
                    Write-SyncMeJson @{ ok = $true; dirs = $dirs } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/rclone/test' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Test-SyncMeRcloneRemote -RemotePath ([string]$body.path)
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/set/rclone' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Update-SyncMeSetRclone -Body $body
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/set/policy' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Update-SyncMeSetPolicy -Body $body
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/set/rescue-kit' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                $setId = if ($body.setId) { [string]$body.setId } else { 'set1' }
                $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $setId
                if (-not $cfg) {
                    Write-SyncMeJson @{ ok = $false; message = 'Not configured yet.' } -StatusCode 400 -Response $res
                    continue
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
                continue
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
                continue
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
                continue
            }

            if ($path -eq '/api/mount/status' -and $req.HttpMethod -eq 'GET') {
                $qSet = [string]$req.QueryString['setId']
                Write-SyncMeJson (Get-SyncMeMountStatus -SetId $qSet) -Response $res
                continue
            }

            if ($path -eq '/api/mount/start' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $sid = if ($body.setId) { [string]$body.setId } else { 'set1' }
                    $mp = if ($body.mountPoint) { [string]$body.mountPoint } else { '' }
                    $msg = Start-SyncMeMount -SetId $sid -MountPoint $mp
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/mount/stop' -and $req.HttpMethod -eq 'POST') {
                try {
                    $msg = Stop-SyncMeMount
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
            }

            if ($path -eq '/api/set/delete' -and $req.HttpMethod -eq 'POST') {
                $body = Read-SyncMeBody $req
                try {
                    $msg = Remove-SyncMeBackupSet -SetId ([string]$body.setId)
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
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
                continue
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
                continue
            }

            if ($path -eq '/api/backup/cancel' -and $req.HttpMethod -eq 'POST') {
                try {
                    $msg = Stop-SyncMeBackupJob
                    Write-SyncMeJson @{ ok = $true; message = $msg } -Response $res
                } catch {
                    Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 400 -Response $res
                }
                continue
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
                continue
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
                continue
            }

            if ($path -eq '/api/shutdown' -and $req.HttpMethod -eq 'POST') {
                Write-SyncMeJson @{ ok = $true; message = 'Stopping' } -Response $res
                $listener.Stop()
                break
            }

            $res.StatusCode = 404
            Write-SyncMeJson @{ ok = $false; message = 'Not found' } -StatusCode 404 -Response $res
        } catch {
            try {
                Write-SyncMeJson @{ ok = $false; message = $_.Exception.Message } -StatusCode 500 -Response $res
            } catch { }
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
