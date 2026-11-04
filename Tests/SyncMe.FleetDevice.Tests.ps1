#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:root 'Modules\Security.ps1')
    . (Join-Path $script:root 'Modules\FleetDevice.ps1')
}

Describe 'FleetDevice identity' {
    It 'creates DPAPI-protected device identity' {
        $tmp = Join-Path $env:TEMP ('sm-fleet-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $a = Get-SyncMeFleetDeviceIdentity -ScriptRoot $tmp -Ensure
            $a.deviceId | Should -Match '^smdev-'
            $a.secretBytes.Length | Should -Be 32
            $b = Get-SyncMeFleetDeviceIdentity -ScriptRoot $tmp
            $b.deviceId | Should -Be $a.deviceId
            $b.secretBase64 | Should -Be $a.secretBase64
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'signs and verifies canonical payload' {
        $tmp = Join-Path $env:TEMP ('sm-fleet2-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $id = Get-SyncMeFleetDeviceIdentity -ScriptRoot $tmp -Ensure
            $body = '{"siteId":"x"}'
            $hdr = Get-SyncMeFleetDeviceAuthHeaders -ScriptRoot $tmp -BodyJson $body -EnsureDevice
            $hdr['X-SyncMe-Device-Id'] | Should -Be $id.deviceId
            $canonical = Get-SyncMeFleetDeviceCanonical -DeviceId $hdr['X-SyncMe-Device-Id'] `
                -TimestampUnix $hdr['X-SyncMe-Device-Ts'] -Nonce $hdr['X-SyncMe-Device-Nonce'] `
                -BodySha256Hex (Get-SyncMeFleetBodySha256Hex -Body $body)
            (Test-SyncMeFleetDeviceSignature -SecretBytes $id.secretBytes -Canonical $canonical -Signature $hdr['X-SyncMe-Device-Sig']) | Should -BeTrue
            (Test-SyncMeFleetDeviceSignature -SecretBytes $id.secretBytes -Canonical $canonical -Signature 'bad') | Should -BeFalse
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
