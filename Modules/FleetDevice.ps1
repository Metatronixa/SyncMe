#Requires -Version 5.1
<#
.SYNOPSIS
  Per-device HMAC fleet identity (DPAPI-protected secret) + request signing helpers.
#>

function Get-SyncMeFleetDevicePath {
    param([Parameter(Mandatory)][string]$ScriptRoot)
    return (Join-Path $ScriptRoot 'Data\Fleet\device.json')
}

function New-SyncMeFleetDeviceSecretBytes {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return $bytes
}

function Protect-SyncMeFleetSecret {
    param([byte[]]$PlainBytes)
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    return [Security.Cryptography.ProtectedData]::Protect(
        $PlainBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
}

function Unprotect-SyncMeFleetSecret {
    param([byte[]]$ProtectedBytes)
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    return [Security.Cryptography.ProtectedData]::Unprotect(
        $ProtectedBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
}

function Get-SyncMeFleetDeviceIdentity {
    <#
      Loads or creates Data/Fleet/device.json (deviceId + DPAPI-protected HMAC secret).
      Returns deviceId, secretBytes, secretBase64 (for loopback register only).
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [switch]$Ensure
    )
    $path = Get-SyncMeFleetDevicePath -ScriptRoot $ScriptRoot
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        if (-not $Ensure) { return $null }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $path) {
        try {
            $obj = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) | ConvertFrom-Json
            $deviceId = [string]$obj.deviceId
            $protB64 = [string]$obj.hmacSecretProtected
            if ([string]::IsNullOrWhiteSpace($deviceId) -or [string]::IsNullOrWhiteSpace($protB64)) {
                throw 'incomplete device.json'
            }
            $prot = [Convert]::FromBase64String($protB64)
            $plain = Unprotect-SyncMeFleetSecret -ProtectedBytes $prot
            return [pscustomobject]@{
                deviceId     = $deviceId
                secretBytes  = $plain
                secretBase64 = [Convert]::ToBase64String($plain)
                createdUtc   = $(if ($obj.createdUtc) { [string]$obj.createdUtc } else { '' })
            }
        } catch {
            if (-not $Ensure) { return $null }
            # Fall through to recreate
        }
    }

    if (-not $Ensure) { return $null }

    $deviceId = ('smdev-' + [guid]::NewGuid().ToString('n'))
    $plain = New-SyncMeFleetDeviceSecretBytes
    $prot = Protect-SyncMeFleetSecret -PlainBytes $plain
    $meta = [ordered]@{
        deviceId            = $deviceId
        hmacSecretProtected = [Convert]::ToBase64String($prot)
        createdUtc          = [DateTime]::UtcNow.ToString('o')
        schema              = 1
    }
    $json = ($meta | ConvertTo-Json -Compress)
    [IO.File]::WriteAllText($path, $json + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    return [pscustomobject]@{
        deviceId     = $deviceId
        secretBytes  = $plain
        secretBase64 = [Convert]::ToBase64String($plain)
        createdUtc   = [string]$meta.createdUtc
    }
}

function Get-SyncMeFleetBodySha256Hex {
    param([string]$Body)
    if ($null -eq $Body) { $Body = '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function New-SyncMeFleetDeviceNonce {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($bytes).TrimEnd('=') -replace '\+', '-' -replace '/', '_')
}

function Get-SyncMeFleetDeviceCanonical {
    param(
        [string]$DeviceId,
        [string]$TimestampUnix,
        [string]$Nonce,
        [string]$BodySha256Hex
    )
    return ("{0}`n{1}`n{2}`n{3}" -f $DeviceId, $TimestampUnix, $Nonce, $BodySha256Hex)
}

function New-SyncMeFleetDeviceSignature {
    param(
        [byte[]]$SecretBytes,
        [string]$Canonical
    )
    $hmac = [Security.Cryptography.HMACSHA256]::new($SecretBytes)
    try {
        $sig = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Canonical))
    } finally {
        $hmac.Dispose()
    }
    return ([Convert]::ToBase64String($sig).TrimEnd('=') -replace '\+', '-' -replace '/', '_')
}

function Test-SyncMeFleetDeviceSignature {
    param(
        [byte[]]$SecretBytes,
        [string]$Canonical,
        [string]$Signature
    )
    $expected = New-SyncMeFleetDeviceSignature -SecretBytes $SecretBytes -Canonical $Canonical
    if (Get-Command Test-SyncMeConstantTimeEquals -ErrorAction SilentlyContinue) {
        return (Test-SyncMeConstantTimeEquals -A $expected -B $Signature)
    }
    return ($expected -eq $Signature)
}

function Get-SyncMeFleetDeviceAuthHeaders {
    <#
      Returns hashtable of X-SyncMe-Device-* headers for a JSON body string.
      Ensures device identity exists when MonitorToken / fleet is in use.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$BodyJson,
        [switch]$EnsureDevice
    )
    $id = Get-SyncMeFleetDeviceIdentity -ScriptRoot $ScriptRoot -Ensure:$EnsureDevice
    if (-not $id) { return $null }
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    $nonce = New-SyncMeFleetDeviceNonce
    $bodyHash = Get-SyncMeFleetBodySha256Hex -Body $BodyJson
    $canonical = Get-SyncMeFleetDeviceCanonical -DeviceId $id.deviceId -TimestampUnix $ts -Nonce $nonce -BodySha256Hex $bodyHash
    $sig = New-SyncMeFleetDeviceSignature -SecretBytes $id.secretBytes -Canonical $canonical
    return @{
        'X-SyncMe-Device-Id'    = [string]$id.deviceId
        'X-SyncMe-Device-Ts'    = $ts
        'X-SyncMe-Device-Nonce' = $nonce
        'X-SyncMe-Device-Sig'   = $sig
    }
}
