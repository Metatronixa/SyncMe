#Requires -Version 5.1
<#
.SYNOPSIS
  Path+method router for SyncMe API controllers.
#>

$script:SyncMeRoutes = [System.Collections.Generic.List[object]]::new()

function Clear-SyncMeRoutes {
    $script:SyncMeRoutes = [System.Collections.Generic.List[object]]::new()
}

function Register-SyncMeRoute {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS')]
        [string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Handler,
        [string]$Name = ''
    )
    if (-not $script:SyncMeRoutes) {
        $script:SyncMeRoutes = [System.Collections.Generic.List[object]]::new()
    }
    $script:SyncMeRoutes.Add([pscustomobject]@{
            Method  = $Method.ToUpperInvariant()
            Path    = $Path
            Handler = $Handler
            Name    = $Name
        }) | Out-Null
}

function Invoke-SyncMeRouter {
    <#
      Returns $true if a route handled the request (response already written), else $false.
    #>
    param(
        $Request,
        $Response,
        $Context = $null
    )
    $method = [string]$Request.HttpMethod
    $path = [string]$Request.Url.AbsolutePath
    foreach ($route in @($script:SyncMeRoutes)) {
        if ($route.Method -ne $method) { continue }
        if ($route.Path -ne $path) { continue }
        & $route.Handler -Request $Request -Response $Response -Context $Context
        return $true
    }
    return $false
}

function Get-SyncMeRegisteredRoutes {
    return @($script:SyncMeRoutes | ForEach-Object {
            [pscustomobject]@{ Method = $_.Method; Path = $_.Path; Name = $_.Name }
        })
}
