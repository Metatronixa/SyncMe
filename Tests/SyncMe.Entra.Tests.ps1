#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:root 'Modules\Logging.ps1')
    . (Join-Path $script:root 'Modules\ModuleEntra.ps1')
}

Describe 'ModuleEntra fingerprint' {
    It 'flags over-permissioned Graph roles' {
        $r = Compare-SyncMeEntraPermissionFingerprint `
            -ExpectedAppRoles @('Sites.Selected') `
            -GrantedAppRoles @('Sites.Selected', 'Directory.Read.All') `
            -Workloads @('SharePoint')
        $r.Status | Should -Be 'warn'
        $r.OverPermissioned | Should -Contain 'Directory.Read.All'
        $r.Drift | Should -BeTrue
    }

    It 'matches expected fingerprint as ok' {
        $r = Compare-SyncMeEntraPermissionFingerprint `
            -ExpectedAppRoles @('Sites.Selected') `
            -GrantedAppRoles @('Sites.Selected') `
            -Workloads @('SharePoint') `
            -SelectedSiteIds @('site-a')
        $r.Status | Should -Be 'ok'
        $r.Drift | Should -BeFalse
    }

    It 'prefers Sites.Selected note when SharePoint on without it' {
        $r = Compare-SyncMeEntraPermissionFingerprint `
            -ExpectedAppRoles @() `
            -GrantedAppRoles @() `
            -Workloads @('SharePoint')
        $r.Status | Should -Be 'warn'
        ($r.Notes -join ' ') | Should -Match 'Sites\.Selected'
    }

    It 'health skips when disabled' {
        $tmp = Join-Path $env:TEMP ('sm-entra-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $tmp 'Config') -Force | Out-Null
        try {
            $h = Test-SyncMeEntraHealth -ScriptRoot $tmp -SkipTokenAcquire
            $h.status | Should -Be 'skipped'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'health warns on mocked over-permission' {
        $tmp = Join-Path $env:TEMP ('sm-entra2-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $tmp 'Config') -Force | Out-Null
        try {
            $null = Save-SyncMeEntraConfig -ScriptRoot $tmp -EntraEnabled $true -TenantId 't' -ClientId 'c' `
                -ExpectedAppRoles @('Sites.Selected') -Workloads @('SharePoint') -SelectedSiteIds @('s1')
            $h = Test-SyncMeEntraHealth -ScriptRoot $tmp -SkipTokenAcquire -GrantedRoleValues @('Sites.ReadWrite.All')
            $h.status | Should -Be 'warn'
            $h.fingerprint.OverPermissioned | Should -Contain 'Sites.ReadWrite.All'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exposes compromise playbook steps' {
        $pb = Get-SyncMeEntraCompromisePlaybook
        $pb.steps.Count | Should -BeGreaterThan 5
        ($pb.note) | Should -Match 'does not call'
    }
}
