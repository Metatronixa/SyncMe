#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:root 'Modules\Http.ps1')
    . (Join-Path $script:root 'Modules\Router.ps1')
    . (Join-Path $script:root 'Modules\ProcessRunner.ps1')
    . (Join-Path $script:root 'Modules\Logging.ps1')
    . (Join-Path $script:root 'Modules\Health.ps1')
    . (Join-Path $script:root 'Modules\ConfigMigrate.ps1')
    . (Join-Path $script:root 'Modules\Sets.ps1')
    . (Join-Path $script:root 'Modules\Jobs.ps1')
    . (Join-Path $script:root 'Modules\Update.ps1')
}

Describe 'Router' {
    It 'registers and lists routes' {
        Clear-SyncMeRoutes
        Register-SyncMeRoute -Method GET -Path '/api/health' -Name 'Health' -Handler { param($Request,$Response,$Context) }
        $routes = @(Get-SyncMeRegisteredRoutes)
        $routes.Count | Should -Be 1
        $routes[0].Path | Should -Be '/api/health'
    }
}

Describe 'Config migration' {
    It 'writes schema version marker' {
        $tmp = Join-Path $env:TEMP ('sm-cfg-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $r = Invoke-SyncMeConfigMigrate -ScriptRoot $tmp -TargetVersion 2
            $r.Ok | Should -BeTrue
            (Get-SyncMeConfigSchemaVersion -ScriptRoot $tmp) | Should -Be 2
            Test-Path (Join-Path $tmp 'Config\schema-version.txt') | Should -BeTrue
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }
}

Describe 'Job state' {
    It 'writes and clears job state' {
        $tmp = Join-Path $env:TEMP ('sm-job-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            Write-SyncMeJobState -ScriptRoot $tmp -JobName 'backup' -Kind 'backup' -SetId 'set1' -Phase 'starting' -Message 'hi'
            $st = Read-SyncMeJobState -ScriptRoot $tmp -JobName 'backup'
            $st.kind | Should -Be 'backup'
            $st.setId | Should -Be 'set1'
            Clear-SyncMeJobState -ScriptRoot $tmp -JobName 'backup'
            (Read-SyncMeJobState -ScriptRoot $tmp -JobName 'backup') | Should -BeNullOrEmpty
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }
}

Describe 'ProcessRunner' {
    It 'runs a simple powershell command' {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $r = Invoke-SyncMeExternalProcess -FilePath $ps -ArgumentList @('-NoProfile','-Command','Write-Output hello-syncme') -NoWindow
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Match 'hello-syncme'
    }
}

Describe 'Health probe' {
    It 'returns structured probe for repo root' {
        $p = Get-SyncMeHealthProbe -ScriptRoot $script:root
        $p.product | Should -Be 'SyncMe'
        $p.checks.Count | Should -BeGreaterThan 3
        $p.status | Should -BeIn @('ok','degraded','fail')
    }
}

Describe 'Structured logging' {
    It 'emits key=value line' {
        $line = Write-SyncMeStructuredLog -Message 'test' -Level INFO -Fields @{ a = '1' }
        $line | Should -Match 'level=INFO'
        $line | Should -Match 'msg="test"'
    }

    It 'never persists SECRET class' {
        $tmp = Join-Path $env:TEMP ('sm-log-' + [guid]::NewGuid().ToString('n') + '.log')
        try {
            $line = Write-SyncMeStructuredLog -Message 'password=hunter2' -Level SECRET -LogPath $tmp
            $line | Should -Match 'redacted'
            (Test-Path $tmp) | Should -BeFalse
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Restore verify evidence' {
    It 'writes and reads evidence json' {
        . (Join-Path $script:root 'Modules\Restore.ps1')
        $tmp = Join-Path $env:TEMP ('sm-ev-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $path = Write-SyncMeRestoreVerifyEvidence -ScriptRoot $tmp -SetId 'set1' -Evidence @{
                ok = $true; sha256 = ('a' * 64); size = 12; snapshotId = 'abc'
            }
            Test-Path $path | Should -BeTrue
            $ev = Get-SyncMeRestoreVerifyEvidence -ScriptRoot $tmp -SetId 'set1'
            $ev.sha256 | Should -Be ('a' * 64)
            $ev.size | Should -Be 12
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }
}

Describe 'Path reparse helper' {
    It 'rejects .. via Assert-SyncMeSafePath' {
        . (Join-Path $script:root 'Modules\Security.ps1')
        { Assert-SyncMeSafePath -Path 'C:\Windows\..\Windows' } | Should -Throw
    }
}
