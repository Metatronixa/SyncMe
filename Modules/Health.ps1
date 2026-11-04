#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe health probe (credentials readiness, tools, scheduler, disk, locks).
#>

function Get-SyncMeHealthProbe {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [string]$SetId = ''
    )
    $checks = [System.Collections.Generic.List[object]]::new()
    $overall = 'ok'

    function Add-Check([string]$Name, [string]$Status, [string]$Detail = '') {
        $checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail }) | Out-Null
        if ($Status -eq 'fail') { $script:overall = 'fail' }
        elseif ($Status -eq 'warn' -and $script:overall -eq 'ok') { $script:overall = 'degraded' }
    }

    $ver = ''
    $vf = Join-Path $ScriptRoot 'VERSION.txt'
    if (Test-Path -LiteralPath $vf) {
        try { $ver = (Get-Content -LiteralPath $vf -TotalCount 1).Trim() } catch { }
    }

    $cfg = $null
    if (Get-Command Get-SyncMeSetById -ErrorAction SilentlyContinue) {
        $cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $SetId
    }
    if (-not $cfg) {
        Add-Check 'configuration' 'warn' 'No backup set configured'
    } else {
        Add-Check 'configuration' 'ok' ("set=" + $(if ($cfg.Id) { $cfg.Id } else { 'set1' }))
        $credName = if ($cfg.ResticCredentialName) { [string]$cfg.ResticCredentialName } else { 'SyncMeRestic' }
        $credOk = $false
        try {
            if (Get-Command Get-GenericCredentialPassword -ErrorAction SilentlyContinue) {
                $null = Get-GenericCredentialPassword -TargetName $credName
                $credOk = $true
            } elseif (Get-Command Test-SyncMeResticCredential -ErrorAction SilentlyContinue) {
                $t = Test-SyncMeResticCredential -TargetName $credName
                $credOk = [bool]$t.Ok
            }
        } catch { $credOk = $false }
        Add-Check 'resticCredential' $(if ($credOk) { 'ok' } else { 'fail' }) $credName

        if (Get-Command Get-SyncMeCanonicalRepoKey -ErrorAction SilentlyContinue) {
            try {
                Assert-SyncMeUniqueRepositories -ScriptRoot $ScriptRoot
                Add-Check 'repositoryUniqueness' 'ok' ''
            } catch {
                Add-Check 'repositoryUniqueness' 'fail' $_.Exception.Message
            }
        }
    }

    $restic = $null
    if (Get-Command Get-ResticOnPath -ErrorAction SilentlyContinue) {
        $restic = Get-ResticOnPath
    }
    if ($restic -and $restic.Ok) {
        Add-Check 'restic' 'ok' $restic.Path
    } else {
        Add-Check 'restic' 'warn' 'restic not on PATH'
    }

    $task = Get-ScheduledTask -TaskName 'SyncMe-Backup' -ErrorAction SilentlyContinue
    if ($task) {
        Add-Check 'scheduler' 'ok' $task.State.ToString()
    } else {
        Add-Check 'scheduler' 'warn' 'SyncMe-Backup task not registered'
    }

    $mods = @('Modules\Security.ps1', 'Modules\Jobs.ps1', 'Modules\Update.ps1', 'Modules\ProcessRunner.ps1', 'Modules\Router.ps1')
    foreach ($m in $mods) {
        $p = Join-Path $ScriptRoot $m
        if (Test-Path -LiteralPath $p) {
            Add-Check ('module:' + [IO.Path]::GetFileNameWithoutExtension($m)) 'ok' ''
        } else {
            Add-Check ('module:' + [IO.Path]::GetFileNameWithoutExtension($m)) 'fail' 'missing'
        }
    }

    $pub = Join-Path $ScriptRoot 'Modules\UpdatePublicKey.xml'
    Add-Check 'updatePublicKey' $(if (Test-Path -LiteralPath $pub) { 'ok' } else { 'warn' }) ''

    if ($cfg) {
        $sid = if ($cfg.Id) { [string]$cfg.Id } else { 'set1' }
        $evPath = Join-Path $ScriptRoot ("Logs\sets\$sid\restore-verify-evidence.json")
        if (Test-Path -LiteralPath $evPath) {
            try {
                $ev = (Get-Content -LiteralPath $evPath -Raw) | ConvertFrom-Json
                $ageH = $null
                if ($ev.verifiedUtc) {
                    $t = [datetime]::Parse([string]$ev.verifiedUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
                    $ageH = [math]::Round(((Get-Date).ToUniversalTime() - $t.ToUniversalTime()).TotalHours, 1)
                }
                $detail = "ageHours=$ageH size=$($ev.size)"
                if ($null -ne $ageH -and $ageH -gt (14 * 24)) {
                    Add-Check 'restoreVerification' 'warn' $detail
                } else {
                    Add-Check 'restoreVerification' 'ok' $detail
                }
            } catch {
                Add-Check 'restoreVerification' 'warn' 'evidence unreadable'
            }
        } else {
            Add-Check 'restoreVerification' 'warn' 'no evidence yet (run weekly data check)'
        }
    }

    return [ordered]@{
        ok       = ($overall -ne 'fail')
        status   = $overall
        version  = $ver
        product  = 'SyncMe'
        checks   = @($checks)
        checkedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}
