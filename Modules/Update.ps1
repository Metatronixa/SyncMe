#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe options (update feed + Monitor + LocalOps) and in-app update helpers.
#>

function Get-SyncMeDefaultUpdateFeedUrl {
    return 'https://www.syncme.co.za/updates/latest.json'
}

function Assert-SyncMeHttpsUrl {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Label = 'URL',
        [switch]$AllowLoopbackHttp
    )
    $u = $Url.Trim()
    if ($u -match '^(?i)https://') { return $u }
    if ($AllowLoopbackHttp -and $u -match '^(?i)http://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(/|$)') {
        return $u
    }
    throw "$Label must use HTTPS (got: $u)."
}

function Get-SyncMeUpdateCanonicalPayload {
    param(
        [string]$Version,
        [string]$File,
        [string]$Sha256,
        [string]$Url
    )
    $sha = ([string]$Sha256).Trim().ToLowerInvariant()
    return ("{0}`n{1}`n{2}`n{3}" -f ([string]$Version).Trim(), ([string]$File).Trim(), $sha, ([string]$Url).Trim())
}

function Get-SyncMeUpdatePublicKeyXml {
    param([string]$ScriptRoot)
    $candidates = @(
        (Join-Path $ScriptRoot 'Modules\UpdatePublicKey.xml')
        (Join-Path $PSScriptRoot 'UpdatePublicKey.xml')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return (Get-Content -LiteralPath $p -Raw -ErrorAction Stop).Trim()
        }
    }
    throw 'Update public key missing (Modules\UpdatePublicKey.xml).'
}

function Test-SyncMeUpdateManifestSignature {
    param(
        [string]$ScriptRoot,
        [string]$Version,
        [string]$File,
        [string]$Sha256,
        [string]$Url,
        [string]$SignatureBase64
    )
    if ([string]::IsNullOrWhiteSpace($SignatureBase64)) { return $false }
    $xml = Get-SyncMeUpdatePublicKeyXml -ScriptRoot $ScriptRoot
    $payload = Get-SyncMeUpdateCanonicalPayload -Version $Version -File $File -Sha256 $Sha256 -Url $Url
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString($xml)
        $data = [Text.Encoding]::UTF8.GetBytes($payload)
        $sig = [Convert]::FromBase64String($SignatureBase64.Trim())
        $oid = [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
        return [bool]$rsa.VerifyData($data, $oid, $sig)
    } finally {
        $rsa.PersistKeyInCsp = $false
        $rsa.Dispose()
    }
}

function New-SyncMeUpdateManifestSignature {
    param(
        [string]$PrivateKeyXmlPath,
        [string]$Version,
        [string]$File,
        [string]$Sha256,
        [string]$Url
    )
    $xml = (Get-Content -LiteralPath $PrivateKeyXmlPath -Raw -ErrorAction Stop).Trim()
    $payload = Get-SyncMeUpdateCanonicalPayload -Version $Version -File $File -Sha256 $Sha256 -Url $Url
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString($xml)
        $data = [Text.Encoding]::UTF8.GetBytes($payload)
        $oid = [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
        $sig = $rsa.SignData($data, $oid)
        return [Convert]::ToBase64String($sig)
    } finally {
        $rsa.PersistKeyInCsp = $false
        $rsa.Dispose()
    }
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
    $feed = Assert-SyncMeHttpsUrl -Url $feed -Label 'UpdateFeedUrl' -AllowLoopbackHttp

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
    $feedUrl = Assert-SyncMeHttpsUrl -Url $feedUrl -Label 'Update feed URL' -AllowLoopbackHttp

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
    if ([string]::IsNullOrWhiteSpace($sha) -or $sha -notmatch '^[a-f0-9]{64}$') {
        throw 'Update feed is missing a valid sha256.'
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
    $downloadUrl = Assert-SyncMeHttpsUrl -Url $downloadUrl -Label 'Update package URL' -AllowLoopbackHttp

    $sig = ''
    if ($manifest.PSObject.Properties['signature'] -and $manifest.signature) {
        $sig = [string]$manifest.signature
    }
    $isOfficialHost = ($feedUrl -match '(?i)^https://([a-z0-9-]+\.)*syncme\.co\.za(/|$)')
    $requireSig = $isOfficialHost -or (-not [string]::IsNullOrWhiteSpace($sig))
    if ($requireSig) {
        if ([string]::IsNullOrWhiteSpace($sig)) {
            throw 'Update feed is missing signature (required for official SyncMe feeds).'
        }
        if (-not (Test-SyncMeUpdateManifestSignature -ScriptRoot $ScriptRoot -Version $remoteVer -File $fileName -Sha256 $sha -Url $downloadUrl -SignatureBase64 $sig)) {
            throw 'Update feed signature verification failed. Refusing update.'
        }
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
        Signature       = $sig
        Signed          = (-not [string]::IsNullOrWhiteSpace($sig))
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
    $null = Assert-SyncMeHttpsUrl -Url ([string]$UpdateInfo.Url) -Label 'Update package URL' -AllowLoopbackHttp
    $isOfficial = ([string]$UpdateInfo.FeedUrl -match '(?i)^https://([a-z0-9-]+\.)*syncme\.co\.za(/|$)') -or
        ([string]$UpdateInfo.Url -match '(?i)^https://([a-z0-9-]+\.)*syncme\.co\.za(/|$)')
    if (($isOfficial -or $UpdateInfo.Signed) -and [string]::IsNullOrWhiteSpace([string]$UpdateInfo.Signature)) {
        throw 'Refusing to install an unsigned official update package.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$UpdateInfo.Signature)) {
        if (-not (Test-SyncMeUpdateManifestSignature -ScriptRoot $ScriptRoot -Version ([string]$UpdateInfo.Version) -File ([string]$UpdateInfo.File) -Sha256 ([string]$UpdateInfo.Sha256) -Url ([string]$UpdateInfo.Url) -SignatureBase64 ([string]$UpdateInfo.Signature))) {
            throw 'Update signature verification failed before download. Refusing update.'
        }
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
`$statePath = Join-Path `$install 'Logs\update-state.json'
`$merged = `$false
`$prev = Join-Path `$install 'Logs\previous-release'

function Write-UpdateLog([string]`$msg) {
    `$line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$msg)
    try { Add-Content -LiteralPath `$log -Value `$line -Encoding UTF8 } catch { }
}
function Write-UpdateState([string]`$phase, [string]`$detail = '') {
    `$obj = [ordered]@{
        phase     = `$phase
        detail    = `$detail
        stamp     = `$stamp
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    try {
        [IO.File]::WriteAllText(`$statePath, ((`$obj | ConvertTo-Json -Compress) + "`r`n"), (New-Object System.Text.UTF8Encoding `$false))
    } catch { }
}
function Restore-PreviousReleaseTree {
    param([string]`$PrevRoot, [string]`$InstallRoot)
    if (-not (Test-Path -LiteralPath `$PrevRoot)) { return `$false }
    foreach (`$rel in @('SyncMe-Host.ps1','SyncMe-Backup.ps1','SyncMe-Restore.ps1','VERSION.txt','Modules','ui','RescueKit')) {
        `$from = Join-Path `$PrevRoot `$rel
        `$to = Join-Path `$InstallRoot `$rel
        if (-not (Test-Path -LiteralPath `$from)) { continue }
        if (Test-Path -LiteralPath `$from -PathType Container) {
            if (Test-Path -LiteralPath `$to) { Remove-Item -LiteralPath `$to -Recurse -Force }
            Copy-Item -LiteralPath `$from -Destination `$to -Recurse -Force
        } else {
            Copy-Item -LiteralPath `$from -Destination `$to -Force
        }
    }
    return `$true
}

try {
    Write-UpdateState 'waiting-host'
    Write-UpdateLog 'Waiting for SyncMe host to exit...'
    for (`$i = 0; `$i -lt 60; `$i++) {
        `$alive = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { `$_.Name -match 'powershell' -and `$_.CommandLine -match 'SyncMe-Host\.ps1' }
        if (-not `$alive) { break }
        Start-Sleep -Seconds 1
    }
    Start-Sleep -Seconds 2

    Write-UpdateState 'snapshot'
    if (Test-Path -LiteralPath `$prev) { Remove-Item -LiteralPath `$prev -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path `$prev -Force | Out-Null
    foreach (`$rel in @('SyncMe-Host.ps1','SyncMe-Backup.ps1','SyncMe-Restore.ps1','VERSION.txt','Modules','ui','RescueKit')) {
        `$from = Join-Path `$install `$rel
        if (Test-Path -LiteralPath `$from) {
            Copy-Item -LiteralPath `$from -Destination (Join-Path `$prev `$rel) -Recurse -Force
        }
    }
    Write-UpdateLog ('Previous release snapshot at ' + `$prev)

    `$cfg = Join-Path `$install 'Config.ps1'
    `$bak = Join-Path `$install ("Config.ps1.bak-" + `$stamp)
    `$preserve = `$null
    if (Test-Path -LiteralPath `$cfg) {
        Copy-Item -LiteralPath `$cfg -Destination `$bak -Force
        `$preserve = Join-Path `$env:TEMP ('SyncMe-Config-Preserve-' + [guid]::NewGuid().ToString() + '.ps1')
        Copy-Item -LiteralPath `$cfg -Destination `$preserve -Force
        Write-UpdateLog ("Backed up Config.ps1 to " + `$bak)
    }

    Write-UpdateState 'stage-extract'
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
        Get-ChildItem -LiteralPath `$extract -Force | ForEach-Object {
            Copy-Item -LiteralPath `$_.FullName -Destination (Join-Path `$payloadExtract `$_.Name) -Recurse -Force
        }
        Write-UpdateLog 'Extracted flat package tree.'
    }

    foreach (`$req in @('SyncMe-Host.ps1','Modules\Update.ps1','Modules\InstallMerge.ps1','Modules\Security.ps1','ui\js\app.js','VERSION.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path `$payloadExtract `$req))) {
            throw ('Staged update missing required file: ' + `$req)
        }
    }

    `$mergePs1 = Join-Path `$payloadExtract 'Modules\InstallMerge.ps1'
    . `$mergePs1
    Write-UpdateState 'merging'
    Copy-SyncMeTreeMerge -SourceRoot `$payloadExtract -DestRoot `$install -SkipNames @('Config.ps1')
    `$merged = `$true
    Clear-SyncMeNestedInstallJunk -InstallRoot `$install
    foreach (`$req in @('SyncMe-Host.ps1','Modules\Update.ps1','Modules\MonitorClient.ps1','Modules\InstallMerge.ps1','Modules\Security.ps1','Modules\Jobs.ps1','Modules\UpdatePublicKey.xml','ui\js\app.js')) {
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

    `$parseFail = `$false
    foreach (`$check in @('SyncMe-Host.ps1','SyncMe-Backup.ps1','Modules\Security.ps1','Modules\Update.ps1','Modules\Jobs.ps1')) {
        `$cf = Join-Path `$install `$check
        if (-not (Test-Path -LiteralPath `$cf)) { continue }
        `$errs = `$null
        `$null = [System.Management.Automation.Language.Parser]::ParseFile(`$cf, [ref]`$null, [ref]`$errs)
        if (`$errs -and `$errs.Count -gt 0) {
            Write-UpdateLog ('Health FAIL parse ' + `$check + ': ' + `$errs[0].Message)
            `$parseFail = `$true
            break
        }
    }
    if (`$parseFail) {
        Write-UpdateState 'rollback' 'parse-health'
        Write-UpdateLog 'Rolling back to previous-release snapshot...'
        if (-not (Restore-PreviousReleaseTree -PrevRoot `$prev -InstallRoot `$install)) {
            throw 'Update health check failed and previous-release snapshot was missing.'
        }
        Write-UpdateLog 'Rollback complete. Starting previous SyncMe...'
        Write-UpdateState 'rolled-back' 'parse-health'
        `$bat = Join-Path `$install 'SyncMe.bat'
        if (Test-Path -LiteralPath `$bat) { Start-Process -FilePath `$bat }
        throw 'Update health check failed; rolled back to previous release.'
    }

    Write-UpdateState 'complete'
    Write-UpdateLog 'Update apply finished (health OK). Starting SyncMe...'
    `$bat = Join-Path `$install 'SyncMe.bat'
    if (Test-Path -LiteralPath `$bat) {
        Start-Process -FilePath `$bat
    }
} catch {
    Write-UpdateLog ('ERROR: ' + `$_.Exception.Message)
    if (`$merged) {
        try {
            Write-UpdateState 'rollback' `$_.Exception.Message
            if (Restore-PreviousReleaseTree -PrevRoot `$prev -InstallRoot `$install) {
                Write-UpdateLog 'Error after merge; restored previous-release snapshot.'
                Write-UpdateState 'rolled-back' `$_.Exception.Message
                `$bat = Join-Path `$install 'SyncMe.bat'
                if (Test-Path -LiteralPath `$bat) { Start-Process -FilePath `$bat }
            }
        } catch {
            Write-UpdateLog ('ROLLBACK ERROR: ' + `$_.Exception.Message)
            Write-UpdateState 'rollback-failed' `$_.Exception.Message
        }
    } else {
        Write-UpdateState 'failed' `$_.Exception.Message
    }
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
        Message = "Update $($UpdateInfo.Version) downloaded and verified (SHA-256$(if ($UpdateInfo.Signed) { ' + signature' } else { '' })). SyncMe will restart to finish installing. A previous-release snapshot is kept under Logs\previous-release for rollback; Config.ps1 is preserved."
        Version = $UpdateInfo.Version
        Backup  = ("Config.ps1.bak-" + $stamp)
        Signed  = [bool]$UpdateInfo.Signed
    }
}
