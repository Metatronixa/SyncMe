#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe migration package export/import (secondary Backup PC hand-off).
#>

function Protect-SyncMeMigrationBytes {
    param(
        [byte[]]$PlainBytes,
        [string]$Password
    )
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($salt)
        $rng.GetBytes($iv)
    } finally {
        $rng.Dispose()
    }

    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
    try {
        $key = $derive.GetBytes(32)
    } finally {
        $derive.Dispose()
    }

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $key
        $aes.IV = $iv
        $enc = $aes.CreateEncryptor()
        try {
            $cipher = $enc.TransformFinalBlock($PlainBytes, 0, $PlainBytes.Length)
        } finally {
            $enc.Dispose()
        }
    } finally {
        $aes.Dispose()
    }

    $out = New-Object byte[] ($salt.Length + $iv.Length + $cipher.Length)
    [Array]::Copy($salt, 0, $out, 0, 16)
    [Array]::Copy($iv, 0, $out, 16, 16)
    [Array]::Copy($cipher, 0, $out, 32, $cipher.Length)
    return ,$out
}

function Unprotect-SyncMeMigrationBytes {
    param(
        [byte[]]$PackageBytes,
        [string]$Password
    )
    if ($null -eq $PackageBytes -or $PackageBytes.Length -lt 48) {
        throw 'Migration package is too short or corrupt.'
    }
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    [Array]::Copy($PackageBytes, 0, $salt, 0, 16)
    [Array]::Copy($PackageBytes, 16, $iv, 0, 16)
    $cipherLen = $PackageBytes.Length - 32
    $cipher = New-Object byte[] $cipherLen
    [Array]::Copy($PackageBytes, 32, $cipher, 0, $cipherLen)

    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
    try {
        $key = $derive.GetBytes(32)
    } finally {
        $derive.Dispose()
    }

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $key
        $aes.IV = $iv
        $dec = $aes.CreateDecryptor()
        try {
            return ,$dec.TransformFinalBlock($cipher, 0, $cipher.Length)
        } catch {
            throw 'Could not decrypt migration package. Check the migration password.'
        } finally {
            $dec.Dispose()
        }
    } finally {
        $aes.Dispose()
    }
}

function ConvertTo-SyncMeMigrationSetDto {
    param($Set)
    $s = ConvertTo-SyncMeSetObject -Config $Set -Id $(if ($Set.Id) { [string]$Set.Id } else { 'set1' }) `
        -DisplayName $(if ($Set.DisplayName) { [string]$Set.DisplayName } else { 'Backup set' })
    # Drop machine-local exe paths that will be re-resolved on the new PC
    $s | Add-Member -NotePropertyName RclonePath -NotePropertyValue '' -Force
    if ($s.RcloneConfigPath -and ($s.RcloneConfigPath -notmatch '[\\/]Config[\\/]rclone\.conf$')) {
        $s | Add-Member -NotePropertyName RcloneConfigPath -NotePropertyValue '' -Force
    }
    return $s
}

function Export-SyncMeMigrationPackage {
    <#
      Builds an AES-encrypted .syncme-migrate file with sets, CM target names,
      optional Credential Manager secrets, and optional rclone.conf bytes.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$Password,
        [string]$OutputPath = '',
        [switch]$IncludeSecrets
    )

    if ([string]::IsNullOrWhiteSpace($Password) -or $Password.Length -lt 8) {
        throw 'Migration password must be at least 8 characters.'
    }

    if (-not (Get-Command Get-SyncMeSetsFromConfigFile -ErrorAction SilentlyContinue)) {
        . (Join-Path $ScriptRoot 'Modules\Sets.ps1')
    }
    if (-not (Get-Command Get-BackupStoredCredential -ErrorAction SilentlyContinue)) {
        . (Join-Path $ScriptRoot 'Modules\Notify.ps1')
    }
    if (-not (Get-Command Get-SyncMeOptions -ErrorAction SilentlyContinue)) {
        . (Join-Path $ScriptRoot 'Modules\Update.ps1')
    }

    $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
    if ($sets.Count -lt 1) { throw 'No backup sets configured to export.' }

    $dtos = @($sets | ForEach-Object { ConvertTo-SyncMeMigrationSetDto -Set $_ })
    $secrets = [ordered]@{}
    if ($IncludeSecrets) {
        $targets = New-Object System.Collections.Generic.HashSet[string]
        foreach ($s in $dtos) {
            foreach ($name in @($s.ResticCredentialName, $s.ShareCredentialName, 'SyncMeSmtp')) {
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                [void]$targets.Add([string]$name)
            }
        }
        foreach ($t in $targets) {
            try {
                $cred = Get-BackupStoredCredential -TargetName $t
                $secrets[$t] = @{
                    user     = [string]$cred.UserName
                    password = [string]$cred.GetNetworkCredential().Password
                }
            } catch {
                # Missing secret is OK — import will prompt
            }
        }
    }

    $rcloneB64 = ''
    $rclonePath = Join-Path $ScriptRoot 'Config\rclone.conf'
    if (Test-Path -LiteralPath $rclonePath) {
        $rcloneB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($rclonePath))
    }

    $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
    $manifest = [ordered]@{
        format           = 'SyncMe.Migration.v1'
        exportedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        packageVersion   = $(try { (Get-Content -LiteralPath (Join-Path $ScriptRoot 'VERSION.txt') -TotalCount 1).Trim() } catch { '' })
        hostname         = $env:COMPUTERNAME
        includeSecrets   = [bool]$IncludeSecrets
        sets             = @($dtos)
        secretTargets    = @($dtos | ForEach-Object {
            @{
                setId                 = $_.Id
                resticCredentialName  = [string]$_.ResticCredentialName
                shareCredentialName   = [string]$_.ShareCredentialName
                smtpCredentialName    = 'SyncMeSmtp'
            }
        })
        secrets          = $secrets
        options          = @{
            UpdateFeedUrl   = [string]$opts.UpdateFeedUrl
            MonitorUrl      = [string]$opts.MonitorUrl
            MonitorSiteId   = [string]$opts.MonitorSiteId
            # Token omitted unless IncludeSecrets — keep fleet pairing intentional
            MonitorToken    = $(if ($IncludeSecrets) { [string]$opts.MonitorToken } else { '' })
            LocalOpsUrl     = [string]$opts.LocalOpsUrl
            LocalOpsEnabled = [bool]$opts.LocalOpsEnabled
        }
        rcloneConfBase64 = $rcloneB64
        notes            = 'Import on the new Backup PC, re-register Task Scheduler (Windows password required), install restic/rclone from Prerequisites, verify UNC paths.'
    }

    $json = ($manifest | ConvertTo-Json -Depth 10 -Compress)
    $plain = [Text.Encoding]::UTF8.GetBytes($json)
    $blob = Protect-SyncMeMigrationBytes -PlainBytes $plain -Password $Password

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $dir = Join-Path $ScriptRoot 'Reports'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $OutputPath = Join-Path $dir ("SyncMe-Migration-{0}.syncme-migrate" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($OutputPath, $blob)

    return @{
        Ok      = $true
        Path    = $OutputPath
        SetCount = $dtos.Count
        Secrets = $secrets.Count
        Message = "Migration package written ($($dtos.Count) set(s)). Keep the migration password with the file."
    }
}

function Import-SyncMeMigrationPackage {
    <#
      Decrypts a .syncme-migrate package, writes Config.ps1 sets, restores optional secrets
      and rclone.conf. Does not register Task Scheduler (caller must supply Windows password).
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$PackagePath,
        [switch]$RestoreSecrets
    )

    if (-not (Test-Path -LiteralPath $PackagePath)) {
        throw "Migration package not found: $PackagePath"
    }
    if ([string]::IsNullOrWhiteSpace($Password)) {
        throw 'Migration password is required.'
    }

    if (-not (Get-Command ConvertTo-SyncMeSetObject -ErrorAction SilentlyContinue)) {
        . (Join-Path $ScriptRoot 'Modules\Sets.ps1')
    }
    if (-not (Get-Command Get-SyncMeOptions -ErrorAction SilentlyContinue)) {
        . (Join-Path $ScriptRoot 'Modules\Update.ps1')
    }

    $bytes = [IO.File]::ReadAllBytes($PackagePath)
    $plain = Unprotect-SyncMeMigrationBytes -PackageBytes $bytes -Password $Password
    $json = [Text.Encoding]::UTF8.GetString($plain)
    $manifest = $json | ConvertFrom-Json
    if (-not $manifest -or [string]$manifest.format -ne 'SyncMe.Migration.v1') {
        throw 'Unrecognized migration package format.'
    }

    $rawSets = @($manifest.sets)
    if ($rawSets.Count -lt 1) { throw 'Migration package contains no backup sets.' }
    $sets = @($rawSets | ForEach-Object {
        ConvertTo-SyncMeSetObject -Config $_ -Id $(if ($_.Id) { [string]$_.Id } else { 'set1' }) `
            -DisplayName $(if ($_.DisplayName) { [string]$_.DisplayName } else { 'Backup set' })
    })

    if (-not (Get-Command Write-SyncMeSetsConfigFile -ErrorAction SilentlyContinue)) {
        throw 'Write-SyncMeSetsConfigFile is not loaded (host context required).'
    }
    Write-SyncMeSetsConfigFile -Sets $sets

    $secretsRestored = 0
    if ($RestoreSecrets -and $manifest.secrets) {
        if (-not (Get-Command Set-CmdKeyGeneric -ErrorAction SilentlyContinue)) {
            throw 'Set-CmdKeyGeneric is not loaded (host context required).'
        }
        foreach ($p in $manifest.secrets.PSObject.Properties) {
            $target = [string]$p.Name
            $val = $p.Value
            $user = if ($val.user) { [string]$val.user } else { 'syncme' }
            $pass = if ($val.password) { [string]$val.password } else { '' }
            if ([string]::IsNullOrWhiteSpace($pass)) { continue }
            Set-CmdKeyGeneric -Target $target -User $user -Password $pass
            $secretsRestored++
        }
    }

    if ($manifest.rcloneConfBase64) {
        $cfgDir = Join-Path $ScriptRoot 'Config'
        if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
        $rclonePath = Join-Path $cfgDir 'rclone.conf'
        [IO.File]::WriteAllBytes($rclonePath, [Convert]::FromBase64String([string]$manifest.rcloneConfBase64))
    }

    if ($manifest.options) {
        $o = $manifest.options
        $saveArgs = @{ ScriptRoot = $ScriptRoot }
        if ($null -ne $o.UpdateFeedUrl) { $saveArgs.UpdateFeedUrl = [string]$o.UpdateFeedUrl }
        if ($null -ne $o.MonitorUrl) { $saveArgs.MonitorUrl = [string]$o.MonitorUrl }
        if ($null -ne $o.MonitorSiteId) { $saveArgs.MonitorSiteId = [string]$o.MonitorSiteId }
        if ($RestoreSecrets -and $null -ne $o.MonitorToken) { $saveArgs.MonitorToken = [string]$o.MonitorToken }
        if ($null -ne $o.LocalOpsUrl) { $saveArgs.LocalOpsUrl = [string]$o.LocalOpsUrl }
        if ($null -ne $o.LocalOpsEnabled) { $saveArgs.LocalOpsEnabled = $o.LocalOpsEnabled }
        Save-SyncMeOptions @saveArgs | Out-Null
    }

    return @{
        Ok              = $true
        SetCount        = $sets.Count
        SecretsRestored = $secretsRestored
        Sets            = @($sets | ForEach-Object { @{ id = $_.Id; displayName = $_.DisplayName; runTime = $_.RunTime } })
        Message         = "Imported $($sets.Count) set(s). Re-register scheduled tasks (Windows password) and verify Prerequisites / UNC paths."
    }
}
