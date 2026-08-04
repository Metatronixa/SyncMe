#Requires -Version 5.1
<#
.SYNOPSIS
  Detached restore runner for SyncMe (cancellable from the host).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SetId,
    [Parameter(Mandatory)][string]$Snapshot,
    [Parameter(Mandatory)][string]$Target,
    [string]$Include = '',
    [string]$StatusFile = ''
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot
. (Join-Path $ScriptRoot 'Modules\Common.ps1')
. (Join-Path $ScriptRoot 'Modules\Notify.ps1')
. (Join-Path $ScriptRoot 'Modules\Restore.ps1')
. (Join-Path $ScriptRoot 'Modules\Sets.ps1')

function Write-RestoreStatus {
    param([hashtable]$Payload)
    if ([string]::IsNullOrWhiteSpace($StatusFile)) { return }
    try {
        $dir = Split-Path -Parent $StatusFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        ($Payload | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $StatusFile -Encoding UTF8
    } catch { }
}

$cfg = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $SetId
if (-not $cfg) { throw "Backup set not found: $SetId" }

$tools = Join-Path $ScriptRoot 'tools'
if (Test-Path $tools) { $env:PATH = "$tools;$env:PATH" }
if ($cfg.RcloneConfigPath) {
    $env:RCLONE_CONFIG = [string]$cfg.RcloneConfigPath
} else {
    $defaultRclone = Join-Path $ScriptRoot 'Config\rclone.conf'
    if (Test-Path -LiteralPath $defaultRclone) { $env:RCLONE_CONFIG = $defaultRclone }
}

Write-RestoreStatus @{
    running  = $true
    finished = $false
    success  = $false
    message  = "Restoring $Snapshot..."
    target   = $Target
    exitCode = $null
    setId    = $SetId
    snapshot = $Snapshot
    updated  = (Get-Date).ToUniversalTime().ToString('o')
}

try {
    $result = Invoke-SyncMeRestore -Config $cfg -Snapshot $Snapshot -TargetPath $Target -Include $Include
    Write-RestoreStatus @{
        running  = $false
        finished = $true
        success  = [bool]$result.Success
        message  = [string]$result.Message
        target   = [string]$result.TargetPath
        exitCode = [int]$result.ExitCode
        setId    = $SetId
        snapshot = $Snapshot
        updated  = (Get-Date).ToUniversalTime().ToString('o')
    }
    if (-not $result.Success) { exit 1 }
    exit 0
} catch {
    Write-RestoreStatus @{
        running  = $false
        finished = $true
        success  = $false
        message  = $_.Exception.Message
        target   = $Target
        exitCode = 1
        setId    = $SetId
        snapshot = $Snapshot
        updated  = (Get-Date).ToUniversalTime().ToString('o')
    }
    exit 1
} finally {
    Remove-Item Env:RCLONE_CONFIG -ErrorAction SilentlyContinue
}
