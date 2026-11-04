#Requires -Version 5.1
<#
.SYNOPSIS
  Registers SyncMe controller routes on the shared Router.
  Domain handlers for setup/backup/restore/snapshots/schedule/updates live in ApiDispatch;
  this module adds explicit foundation routes (health) and documents the controller map.
#>

function Register-SyncMeControllerRoutes {
    param(
        [string]$ScriptRoot,
        [int]$Port,
        [string]$CsrfToken
    )

    Clear-SyncMeRoutes

    Register-SyncMeRoute -Method GET -Path '/api/health' -Name 'Health.Get' -Handler {
        param($Request, $Response, $Context)
        $root = if ($Context -and $Context.ScriptRoot) { [string]$Context.ScriptRoot } else { $ScriptRoot }
        $qSet = [string]$Request.QueryString['setId']
        $probe = Get-SyncMeHealthProbe -ScriptRoot $root -SetId $qSet
        Write-SyncMeJson $probe -Response $Response
    }

    Register-SyncMeRoute -Method GET -Path '/api/routes' -Name 'Router.List' -Handler {
        param($Request, $Response, $Context)
        Write-SyncMeJson @{
            ok      = $true
            routes  = @(Get-SyncMeRegisteredRoutes)
            note    = 'Domain APIs are dispatched via Invoke-SyncMeApiDispatch (setup/backup/restore/snapshots/schedule/updates).'
        } -Response $Response
    }
}

function Invoke-SyncMeControllerPipeline {
    <#
      Prefer Router for foundation routes; fall back to ApiDispatch for product APIs.
      Returns: $true handled | $false not found | 'shutdown'
    #>
    param(
        $Request,
        $Response,
        [string]$ScriptRoot,
        [int]$Port,
        [string]$CsrfToken,
        $Listener = $null
    )
    $ctx = @{
        ScriptRoot = $ScriptRoot
        Port       = $Port
        CsrfToken  = $CsrfToken
    }
    if (Invoke-SyncMeRouter -Request $Request -Response $Response -Context $ctx) {
        return $true
    }
    return (Invoke-SyncMeApiDispatch -Request $Request -Response $Response -ScriptRoot $ScriptRoot -Port $Port -CsrfToken $CsrfToken -Listener $Listener)
}
