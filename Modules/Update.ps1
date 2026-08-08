#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe options (update feed + Monitor + LocalOps) and in-app update helpers.
#>

function Get-SyncMeDefaultUpdateFeedUrl {
    return 'https://www.syncme.co.za/updates/latest.json'
}

function Get-SyncMeOptionsPath {
    param([string]$ScriptRoot)
    return (Join-Path $ScriptRoot 'Config\SyncMeOptions.json')
}

function ConvertTo-SyncMeOptionBool {
    param($Value, [bool]$Default = $true)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -in @('1', 'true', 'yes', 'on')) { return $true }
    if ($s -in @('0', 'false', 'no', 'off')) { return $false }
    return $Default
}

function Get-SyncMeOptions {
    param([string]$ScriptRoot)

    $defaults = [ordered]@{
        UpdateFeedUrl    = (Get-SyncMeDefaultUpdateFeedUrl)
        MonitorUrl       = ''
        MonitorSiteId    = ''
        MonitorToken     = ''
        LocalOpsUrl      = ''
        LocalOpsEnabled  = $true
        SkippedFilesAck  = [ordered]@{}
    }

    $path = Get-SyncMeOptionsPath -ScriptRoot $ScriptRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]$defaults
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json
        foreach ($k in @('UpdateFeedUrl', 'MonitorUrl', 'MonitorSiteId', 'MonitorToken', 'LocalOpsUrl')) {
            if ($null -ne $obj.PSObject.Properties[$k]) {
                $defaults[$k] = [string]$obj.$k
            }
        }
        if ($null -ne $obj.PSObject.Properties['LocalOpsEnabled']) {
            $defaults['LocalOpsEnabled'] = (ConvertTo-SyncMeOptionBool -Value $obj.LocalOpsEnabled -Default $true)
        }
        if ($null -ne $obj.PSObject.Properties['SkippedFilesAck'] -and $obj.SkippedFilesAck) {
            $ack = [ordered]@{}
            foreach ($p in $obj.SkippedFilesAck.PSObject.Properties) {
                $ack[[string]$p.Name] = [string]$p.Value
            }
            $defaults['SkippedFilesAck'] = $ack
        }
    } catch { }

    return [pscustomobject]$defaults
}

function Save-SyncMeOptions {
    param(
        [string]$ScriptRoot,
        [string]$UpdateFeedUrl,
        [string]$MonitorUrl,
        [string]$MonitorSiteId,
        [string]$MonitorToken,
        [string]$LocalOpsUrl,
        [object]$LocalOpsEnabled,
        $SkippedFilesAck
    )

    $dir = Join-Path $ScriptRoot 'Config'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $current = Get-SyncMeOptions -ScriptRoot $ScriptRoot
    $feed = [string]$current.UpdateFeedUrl
    if ($PSBoundParameters.ContainsKey('UpdateFeedUrl')) {
        $feed = if (-not [string]::IsNullOrWhiteSpace($UpdateFeedUrl)) { $UpdateFeedUrl.Trim() } else { Get-SyncMeDefaultUpdateFeedUrl }
    }
    if ([string]::IsNullOrWhiteSpace($feed)) { $feed = Get-SyncMeDefaultUpdateFeedUrl }

    $locEnabled = [bool]$current.LocalOpsEnabled
    if ($PSBoundParameters.ContainsKey('LocalOpsEnabled')) {
        $locEnabled = (ConvertTo-SyncMeOptionBool -Value $LocalOpsEnabled -Default $true)
    }

    $locUrl = $(if ($PSBoundParameters.ContainsKey('LocalOpsUrl')) { [string]$LocalOpsUrl.Trim() } else { [string]$current.LocalOpsUrl })
    if (-not [string]::IsNullOrWhiteSpace($locUrl)) {
        if (-not (Get-Command Test-SyncMeLocalOpsLoopbackUrl -ErrorAction SilentlyContinue)) {
            $locClient = Join-Path $ScriptRoot 'Modules\LocalOpsClient.ps1'
            if (Test-Path -LiteralPath $locClient) { . $locClient }
        }
        if ((Get-Command Test-SyncMeLocalOpsLoopbackUrl -ErrorAction SilentlyContinue) -and
            -not (Test-SyncMeLocalOpsLoopbackUrl -Url $locUrl)) {
            throw 'LocalOpsUrl must be a loopback URL (127.0.0.1, localhost, or ::1).'
        }
    }

    $ackMap = [ordered]@{}
    $srcAck = if ($PSBoundParameters.ContainsKey('SkippedFilesAck')) { $SkippedFilesAck } else { $current.SkippedFilesAck }
    if ($srcAck) {
        if ($srcAck -is [hashtable] -or $srcAck -is [System.Collections.IDictionary]) {
            foreach ($k in $srcAck.Keys) { $ackMap[[string]$k] = [string]$srcAck[$k] }
        } else {
            foreach ($p in $srcAck.PSObject.Properties) { $ackMap[[string]$p.Name] = [string]$p.Value }
        }
    }

    $payload = [ordered]@{
        UpdateFeedUrl   = $feed
        MonitorUrl      = $(if ($PSBoundParameters.ContainsKey('MonitorUrl')) { [string]$MonitorUrl.Trim() } else { [string]$current.MonitorUrl })
        MonitorSiteId   = $(if ($PSBoundParameters.ContainsKey('MonitorSiteId')) { [string]$MonitorSiteId.Trim() } else { [string]$current.MonitorSiteId })
        MonitorToken    = $(if ($PSBoundParameters.ContainsKey('MonitorToken')) { [string]$MonitorToken.Trim() } else { [string]$current.MonitorToken })
        LocalOpsUrl     = $locUrl
        LocalOpsEnabled = $locEnabled
        SkippedFilesAck = $ackMap
    }

    $path = Get-SyncMeOptionsPath -ScriptRoot $ScriptRoot
    $json = ($payload | ConvertTo-Json -Depth 6)
    [IO.File]::WriteAllText($path, $json + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    return [pscustomobject]$payload
}

function Set-SyncMeSkippedFilesAck {
    param(
        [string]$ScriptRoot,
        [string]$SetId,
        [string]$UpdatedUtc
    )
    if ([string]::IsNullOrWhiteSpace($SetId)) { $SetId = 'set1' }
    $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
    $ack = [ordered]@{}
    if ($opts.SkippedFilesAck) {
        if ($opts.SkippedFilesAck -is [hashtable] -or $opts.SkippedFilesAck -is [System.Collections.IDictionary]) {
            foreach ($k in $opts.SkippedFilesAck.Keys) { $ack[[string]$k] = [string]$opts.SkippedFilesAck[$k] }
        } else {
            foreach ($p in $opts.SkippedFilesAck.PSObject.Properties) { $ack[[string]$p.Name] = [string]$p.Value }
        }
    }
    $ack[$SetId] = if ($UpdatedUtc) { [string]$UpdatedUtc } else { (Get-Date).ToUniversalTime().ToString('o') }
    return (Save-SyncMeOptions -ScriptRoot $ScriptRoot -SkippedFilesAck $ack)
}

function Test-SyncMeSkippedFilesBanner {
    param(
        [string]$ScriptRoot,
        [string]$SetId,
        $LastRun
    )
    if (-not $LastRun) { return $false }
    $exit = [string]$LastRun.backupExitCode
    if ($exit -ne '3') { return $false }
    $sid = if ($SetId) { $SetId } else { 'set1' }
    $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
    $ackUtc = ''
    if ($opts.SkippedFilesAck) {
        if ($opts.SkippedFilesAck -is [hashtable] -or $opts.SkippedFilesAck -is [System.Collections.IDictionary]) {
            if ($opts.SkippedFilesAck.Contains($sid)) { $ackUtc = [string]$opts.SkippedFilesAck[$sid] }
        } elseif ($opts.SkippedFilesAck.PSObject.Properties[$sid]) {
            $ackUtc = [string]$opts.SkippedFilesAck.$sid
        }
    }
    $runUtc = [string]$LastRun.updatedUtc
    if ([string]::IsNullOrWhiteSpace($runUtc)) { return $true }
    return ($ackUtc -ne $runUtc)
}

function ConvertTo-SyncMeVersionParts {
    param([string]$Version)
    $v = ($Version -replace '[^0-9.].*', '').Trim('.')
    if ([string]::IsNullOrWhiteSpace($v)) { return @(0, 0, 0) }
    $parts = @($v.Split('.') | ForEach-Object {
        $n = 0
        [void][int]::TryParse($_, [ref]$n)
        $n
    })
    while ($parts.Count -lt 3) { $parts += 0 }
    return @($parts[0], $parts[1], $parts[2])
}

function Compare-SyncMeVersion {
    param(
        [string]$Left,
        [string]$Right
    )
    $a = ConvertTo-SyncMeVersionParts $Left
    $b = ConvertTo-SyncMeVersionParts $Right
    for ($i = 0; $i -lt 3; $i++) {
        if ($a[$i] -lt $b[$i]) { return -1 }
        if ($a[$i] -gt $b[$i]) { return 1 }
    }
    return 0
}

function Get-SyncMeUpdateInfo {
    param(
        [string]$ScriptRoot,
        [string]$CurrentVersion = ''
    )

    if ([string]::IsNullOrWhiteSpace($CurrentVersion)) {
        $verFile = Join-Path $ScriptRoot 'VERSION.txt'
        if (Test-Path -LiteralPath $verFile) {
            try { $CurrentVersion = ((Get-Content -LiteralPath $verFile -TotalCount 1 -ErrorAction Stop).Trim()) } catch { }
        }
    }
    if ([string]::IsNullOrWhiteSpace($CurrentVersion)) { $CurrentVersion = '0.0.0' }

    $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
    $feedUrl = [string]$opts.UpdateFeedUrl
    if ([string]::IsNullOrWhiteSpace($feedUrl)) { $feedUrl = Get-SyncMeDefaultUpdateFeedUrl }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $headers = @{ 'User-Agent' = 'SyncMe' }
    $manifest = $null
    try {
        $manifest = Invoke-RestMethod -Uri $feedUrl -Headers $headers -TimeoutSec 30
    } catch {
        throw "Could not reach update feed ($feedUrl): $($_.Exception.Message)"
    }

    $remoteVer = [string]$manifest.version
    if ([string]::IsNullOrWhiteSpace($remoteVer)) {
        throw 'Update feed is missing version.'
    }

    $fileName = [string]$manifest.file
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = "SyncMe-Setup-$remoteVer.zip"
    }

    $sha = ([string]$manifest.sha256).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($sha)) {
        throw 'Update feed is missing sha256.'
    }

    $downloadUrl = [string]$manifest.url
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        $base = $feedUrl
        if ($base -match '/[^/]+\.json(\?.*)?$') {
            $base = $base -replace '/[^/]+\.json(\?.*)?$', '/'
        } elseif (-not $base.EndsWith('/')) {
            $base = $base.Substring(0, $base.LastIndexOf('/') + 1)
        }
        $downloadUrl = $base.TrimEnd('/') + '/' + $fileName.TrimStart('/')
    }

    $cmp = Compare-SyncMeVersion -Left $CurrentVersion -Right $remoteVer
    return @{
        Ok              = $true
        UpdateAvailable = ($cmp -lt 0)
        CurrentVersion  = $CurrentVersion
        Version         = $remoteVer
        File            = $fileName
        Url             = $downloadUrl
        Sha256          = $sha
        Notes           = $(if ($manifest.notes) { [string]$manifest.notes } else { '' })
        FeedUrl         = $feedUrl
    }
}

function Get-FileSha256Hex {
    param([string]$Path)
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $hash.Hash.ToLowerInvariant()
}

function Start-SyncMeUpdateApply {
    param(
        [string]$ScriptRoot,
        [hashtable]$UpdateInfo
    )

    if (-not $UpdateInfo -or -not $UpdateInfo.UpdateAvailable) {
        throw 'No update available to install.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$UpdateInfo.Url)) {
        throw 'Update URL is missing.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$UpdateInfo.Sha256)) {
        throw 'Update SHA-256 is missing.'
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('SyncMe-Update-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zipPath = Join-Path $work 'package.zip'
    $headers = @{ 'User-Agent' = 'SyncMe' }

    try {
        Invoke-WebRequest -Uri $UpdateInfo.Url -OutFile $zipPath -Headers $headers -UseBasicParsing -TimeoutSec 600
    } catch {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        throw "Download failed: $($_.Exception.Message)"
    }

    $actual = Get-FileSha256Hex -Path $zipPath
    $expected = ([string]$UpdateInfo.Sha256).Trim().ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch (expected $expected, got $actual). Update aborted."
    }

    $logsDir = Join-Path $ScriptRoot 'Logs'
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    $applyPath = Join-Path $logsDir 'pending-update-apply.ps1'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $installEsc = $ScriptRoot.Replace("'", "''")
    $zipEsc = $zipPath.Replace("'", "''")
    $workEsc = $work.Replace("'", "''")

    $applyScript = @"
#Requires -Version 5.1
`$ErrorActionPreference = 'Stop'
`$install = '$installEsc'
`$zipPath = '$zipEsc'
`$workRoot = '$workEsc'
`$stamp = '$stamp'
`$log = Join-Path `$install 'Logs\update-apply.log'

function Write-UpdateLog([string]`$msg) {
    `$line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$msg)
    try { Add-Content -LiteralPath `$log -Value `$line -Encoding UTF8 } catch { }
}

try {
    Write-UpdateLog 'Waiting for SyncMe host to exit...'
    for (`$i = 0; `$i -lt 60; `$i++) {
        `$alive = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { `$_.Name -match 'powershell' -and `$_.CommandLine -match 'SyncMe-Host\.ps1' }
        if (-not `$alive) { break }
        Start-Sleep -Seconds 1
    }
    Start-Sleep -Seconds 2

    `$cfg = Join-Path `$install 'Config.ps1'
    `$bak = Join-Path `$install ("Config.ps1.bak-" + `$stamp)
    `$preserve = `$null
    if (Test-Path -LiteralPath `$cfg) {
        Copy-Item -LiteralPath `$cfg -Destination `$bak -Force
        `$preserve = Join-Path `$env:TEMP ('SyncMe-Config-Preserve-' + [guid]::NewGuid().ToString() + '.ps1')
        Copy-Item -LiteralPath `$cfg -Destination `$preserve -Force
        Write-UpdateLog ("Backed up Config.ps1 to " + `$bak)
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    `$extract = Join-Path `$workRoot 'extracted'
    if (Test-Path -LiteralPath `$extract) { Remove-Item -LiteralPath `$extract -Recurse -Force }
    New-Item -ItemType Directory -Path `$extract -Force | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory(`$zipPath, `$extract)

    `$payload = Get-ChildItem -Path `$extract -Filter 'SyncMe-Payload.zip' -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    `$payloadExtract = Join-Path `$workRoot 'payload'
    New-Item -ItemType Directory -Path `$payloadExtract -Force | Out-Null

    if (`$payload) {
        [IO.Compression.ZipFile]::ExtractToDirectory(`$payload.FullName, `$payloadExtract)
        Write-UpdateLog 'Extracted SyncMe-Payload.zip from setup package.'
    } else {
        # Flat tree zip fallback
        Get-ChildItem -LiteralPath `$extract -Force | ForEach-Object {
            Copy-Item -LiteralPath `$_.FullName -Destination (Join-Path `$payloadExtract `$_.Name) -Recurse -Force
        }
        Write-UpdateLog 'Extracted flat package tree.'
    }

    `$mergePs1 = Join-Path `$payloadExtract 'Modules\InstallMerge.ps1'
    if (-not (Test-Path -LiteralPath `$mergePs1)) {
        throw 'Update package missing Modules\\InstallMerge.ps1'
    }
    . `$mergePs1
    Copy-SyncMeTreeMerge -SourceRoot `$payloadExtract -DestRoot `$install -SkipNames @('Config.ps1')
    Clear-SyncMeNestedInstallJunk -InstallRoot `$install
    foreach (`$req in @('SyncMe-Host.ps1','Modules\Update.ps1','Modules\MonitorClient.ps1','Modules\InstallMerge.ps1','ui\js\app.js')) {
        if (-not (Test-Path -LiteralPath (Join-Path `$install `$req))) {
            throw ('Update incomplete: missing ' + `$req)
        }
    }
    Write-UpdateLog 'Copied update files (Config.ps1 skipped during copy).'

    if (`$preserve -and (Test-Path -LiteralPath `$preserve)) {
        Copy-Item -LiteralPath `$preserve -Destination `$cfg -Force
        Remove-Item -LiteralPath `$preserve -Force -ErrorAction SilentlyContinue
        Write-UpdateLog 'Restored Config.ps1 from preserve copy.'
    }

    Write-UpdateLog 'Update apply finished. Starting SyncMe...'
    `$bat = Join-Path `$install 'SyncMe.bat'
    if (Test-Path -LiteralPath `$bat) {
        Start-Process -FilePath `$bat
    }
} catch {
    Write-UpdateLog ('ERROR: ' + `$_.Exception.Message)
} finally {
    try { Remove-Item -LiteralPath `$workRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
"@

    [IO.File]::WriteAllText($applyPath, $applyScript, (New-Object System.Text.UTF8Encoding $true))

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $applyPath
    ) -WindowStyle Hidden | Out-Null

    return @{
        Ok      = $true
        Message = "Update $($UpdateInfo.Version) downloaded and verified. SyncMe will restart to finish installing. Your Config.ps1 was backed up first."
        Version = $UpdateInfo.Version
        Backup  = ("Config.ps1.bak-" + $stamp)
    }
}
