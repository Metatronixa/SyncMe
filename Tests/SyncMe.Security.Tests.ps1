#Requires -Version 5.1
<#
.SYNOPSIS
  Pester tests for SyncMe Phase 1/2 security hardening.
#>
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:root 'Modules\Security.ps1')
    . (Join-Path $script:root 'Modules\Restore.ps1')
    . (Join-Path $script:root 'Modules\Update.ps1')
    . (Join-Path $script:root 'Modules\Jobs.ps1')
}

Describe 'Restore target safety' {
    It 'rejects non-empty targets' {
        $tmp = Join-Path $env:TEMP ('sm-restore-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        'x' | Set-Content (Join-Path $tmp 'sentinel.txt')
        try {
            $r = Test-SyncMeRestoreTargetSafe -TargetPath $tmp -ResticRepo 'D:\fake-repo' -ScriptRoot $script:root
            $r.Ok | Should -BeFalse
            $r.NonEmpty | Should -BeTrue
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }

    It 'rejects drive roots' {
        $r = Test-SyncMeRestoreTargetSafe -TargetPath 'C:\' -ResticRepo 'D:\fake-repo' -ScriptRoot $script:root
        $r.Ok | Should -BeFalse
        $r.Message | Should -Match 'drive root'
    }

    It 'accepts empty folder outside install' {
        $tmp = Join-Path $env:TEMP ('sm-restore-empty-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $r = Test-SyncMeRestoreTargetSafe -TargetPath $tmp -ResticRepo 'D:\fake-repo' -ScriptRoot $script:root
            $r.Ok | Should -BeTrue
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }
}

Describe 'CSRF helpers' {
    It 'creates a non-empty token' {
        $t = New-SyncMeCsrfToken
        $t.Length | Should -BeGreaterThan 20
    }

    It 'constant-time equals works' {
        (Test-SyncMeConstantTimeEquals -A 'abc' -B 'abc') | Should -BeTrue
        (Test-SyncMeConstantTimeEquals -A 'abc' -B 'abd') | Should -BeFalse
    }
}

Describe 'HTTPS URL enforcement' {
    It 'allows https' {
        Assert-SyncMeHttpsUrl -Url 'https://www.syncme.co.za/updates/latest.json' -Label 'feed' | Should -Match '^https://'
    }

    It 'rejects plain http remote' {
        { Assert-SyncMeHttpsUrl -Url 'http://evil.example/updates/latest.json' -Label 'feed' } | Should -Throw
    }

    It 'allows loopback http when opted in' {
        Assert-SyncMeHttpsUrl -Url 'http://127.0.0.1:9/latest.json' -Label 'feed' -AllowLoopbackHttp | Should -Match '^http://127'
    }
}

Describe 'Update manifest signatures' {
    It 'round-trips sign and verify with Tools private key when present' {
        $priv = Join-Path $script:root 'Tools\syncme-update-private.xml'
        if (-not (Test-Path -LiteralPath $priv)) {
            Set-ItResult -Skipped -Because 'private key not present on this machine'
            return
        }
        $ver = '9.9.9'
        $file = 'SyncMe-Setup-9.9.9.zip'
        $sha = ('a' * 64)
        $url = 'https://www.syncme.co.za/updates/SyncMe-Setup-9.9.9.zip'
        $sig = New-SyncMeUpdateManifestSignature -PrivateKeyXmlPath $priv -Version $ver -File $file -Sha256 $sha -Url $url
        $ok = Test-SyncMeUpdateManifestSignature -ScriptRoot $script:root -Version $ver -File $file -Sha256 $sha -Url $url -SignatureBase64 $sig
        $ok | Should -BeTrue
        $bad = Test-SyncMeUpdateManifestSignature -ScriptRoot $script:root -Version $ver -File $file -Sha256 ('b' * 64) -Url $url -SignatureBase64 $sig
        $bad | Should -BeFalse
    }
}

Describe 'Fleet outcome' {
    It 'maps exit 3 to degraded' {
        Get-SyncMeFleetOutcome -RunInfo ([pscustomobject]@{ Success = $true; BackupExitCode = '3' }) | Should -Be 'degraded'
    }

    It 'maps success 0 to ok' {
        Get-SyncMeFleetOutcome -RunInfo ([pscustomobject]@{ Success = $true; BackupExitCode = '0' }) | Should -Be 'ok'
    }

    It 'maps failure to failed' {
        Get-SyncMeFleetOutcome -RunInfo ([pscustomobject]@{ Success = $false; BackupExitCode = '1' }) | Should -Be 'failed'
    }
}

Describe 'Repository canonical keys' {
    It 'normalizes local paths' {
        $a = Get-SyncMeCanonicalRepoKey -ResticRepo 'D:\Backups\Repo'
        $b = Get-SyncMeCanonicalRepoKey -ResticRepo 'D:\Backups\Repo\'
        $a | Should -Be $b
    }

    It 'keeps rclone distinct' {
        (Get-SyncMeCanonicalRepoKey -ResticRepo 'rclone:remote:path') | Should -Match '^rclone:'
    }
}

Describe 'Operator session' {
    It 'issues a session with csrf and expiry' {
        $tmp = Join-Path $env:TEMP ('sm-sess-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $s = New-SyncMeOperatorSession -ScriptRoot $tmp -TtlHours 12
            $s.sessionToken.Length | Should -BeGreaterThan 20
            $s.csrfToken.Length | Should -BeGreaterThan 20
            $s.expiresUtc | Should -Not -BeNullOrEmpty
            (Test-SyncMeOperatorSessionValid -ScriptRoot $tmp -SessionToken $s.sessionToken) | Should -BeTrue
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects missing session token' {
        $tmp = Join-Path $env:TEMP ('sm-sess-miss-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $null = New-SyncMeOperatorSession -ScriptRoot $tmp -TtlHours 12
            (Test-SyncMeOperatorSessionValid -ScriptRoot $tmp -SessionToken '') | Should -BeFalse
            (Test-SyncMeOperatorSessionValid -ScriptRoot $tmp -SessionToken 'wrong-token') | Should -BeFalse
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails closed when expired' {
        $tmp = Join-Path $env:TEMP ('sm-sess-exp-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $s = New-SyncMeOperatorSession -ScriptRoot $tmp -TtlHours 12
            $path = Join-Path $tmp 'Data\Session\current.json'
            $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $raw.expiresUtc = ([DateTime]::UtcNow.AddHours(-1)).ToString('o')
            ($raw | ConvertTo-Json -Compress) | Set-Content -LiteralPath $path -Encoding UTF8
            (Test-SyncMeOperatorSessionValid -ScriptRoot $tmp -SessionToken $s.sessionToken) | Should -BeFalse
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rotation invalidates previous token' {
        $tmp = Join-Path $env:TEMP ('sm-sess-rot-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $a = New-SyncMeOperatorSession -ScriptRoot $tmp -TtlHours 12
            $b = New-SyncMeOperatorSession -ScriptRoot $tmp -TtlHours 12
            (Test-SyncMeOperatorSessionValid -ScriptRoot $tmp -SessionToken $a.sessionToken) | Should -BeFalse
            (Test-SyncMeOperatorSessionValid -ScriptRoot $tmp -SessionToken $b.sessionToken) | Should -BeTrue
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'mutating API rejects missing session when required' {
        $tmp = Join-Path $env:TEMP ('sm-sess-mut-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $s = New-SyncMeOperatorSession -ScriptRoot $tmp -TtlHours 12
            $req = [pscustomobject]@{
                HttpMethod      = 'POST'
                Headers         = @{
                    Host            = '127.0.0.1:17890'
                    Origin          = 'http://127.0.0.1:17890'
                    'X-SyncMe-CSRF' = [string]$s.csrfToken
                }
                HasEntityBody   = $false
                ContentType     = ''
                ContentLength64 = 0
                Url             = [uri]'http://127.0.0.1:17890/api/schedule'
            }
            { Assert-SyncMeMutatingApiRequest -Request $req -ExpectedPort 17890 -CsrfToken $s.csrfToken -ScriptRoot $tmp -RequireSession } | Should -Throw
            $req.Headers['X-SyncMe-Session'] = [string]$s.sessionToken
            { Assert-SyncMeMutatingApiRequest -Request $req -ExpectedPort 17890 -CsrfToken $s.csrfToken -ScriptRoot $tmp -RequireSession } | Should -Not -Throw
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'destructive confirm requires header' {
        $req = [pscustomobject]@{ Headers = @{} }
        { Assert-SyncMeDestructiveConfirm -Request $req } | Should -Throw
        $req2 = [pscustomobject]@{ Headers = @{ 'X-SyncMe-Confirm' = '1' } }
        { Assert-SyncMeDestructiveConfirm -Request $req2 } | Should -Not -Throw
    }
}

Describe 'Elevation DPAPI handoff' {
    It 'protects and unprotects a secret' {
        Add-Type -AssemblyName System.Security
        $plain = 'test-secret-' + [guid]::NewGuid().ToString('n')
        $path = Join-Path $env:TEMP ('sm-elev-' + [guid]::NewGuid().ToString('n') + '.dpapi')
        $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
        $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes($path, $protected)
        try {
            $raw = [IO.File]::ReadAllBytes($path)
            $out = [Text.Encoding]::UTF8.GetString(
                [Security.Cryptography.ProtectedData]::Unprotect($raw, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
            $out | Should -Be $plain
        } finally {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }
}
