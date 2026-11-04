#Requires -Version 5.1
<#
.SYNOPSIS
  Runs SyncMe Pester tests (installs Pester 5 into CurrentUser if missing).
#>
[CmdletBinding()]
param(
    [string]$Output = 'Detailed'
)

$ErrorActionPreference = 'Stop'
$testsRoot = $PSScriptRoot

function Ensure-Pester5 {
    $mod = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
    if ($mod -and $mod.Version -ge [version]'5.0.0') {
        Import-Module Pester -MinimumVersion 5.0.0 -Force
        return
    }
    Write-Host 'Installing Pester 5 for CurrentUser...' -ForegroundColor Yellow
    Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
    Import-Module Pester -MinimumVersion 5.0.0 -Force
}

Ensure-Pester5
$config = New-PesterConfiguration
$config.Run.Path = $testsRoot
$config.Run.Exit = $true
$config.Output.Verbosity = $Output
Invoke-Pester -Configuration $config
