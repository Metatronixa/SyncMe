#Requires -Version 5.1
<#
.SYNOPSIS
  Versioned SyncMe configuration migration (Config.ps1 + SyncMeOptions.json).
#>

function Get-SyncMeConfigSchemaVersion {
    param([string]$ScriptRoot)
    $marker = Join-Path $ScriptRoot 'Config\schema-version.txt'
    if (Test-Path -LiteralPath $marker) {
        try {
            $v = (Get-Content -LiteralPath $marker -TotalCount 1).Trim()
            if ($v -match '^\d+$') { return [int]$v }
        } catch { }
    }
    # Pre-marker installs are schema 1 (Config.ps1 with BackupSets)
    if (Test-Path -LiteralPath (Join-Path $ScriptRoot 'Config.ps1')) { return 1 }
    return 0
}

function Set-SyncMeConfigSchemaVersion {
    param([string]$ScriptRoot, [int]$Version)
    $dir = Join-Path $ScriptRoot 'Config'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'schema-version.txt'
    Set-Content -LiteralPath $path -Value ([string]$Version) -Encoding UTF8
}

function Invoke-SyncMeConfigMigrate {
    <#
      Applies forward-only migrations. Current target schema: 2
      v1 -> v2: ensure SyncMeOptions.json exists; ensure set defaults; write schema marker.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [int]$TargetVersion = 2
    )
    $from = Get-SyncMeConfigSchemaVersion -ScriptRoot $ScriptRoot
    $actions = [System.Collections.Generic.List[string]]::new()
    if ($from -ge $TargetVersion) {
        return @{ Ok = $true; From = $from; To = $from; Actions = @(); Skipped = $true }
    }

    if ($from -lt 1 -and $TargetVersion -ge 1) {
        # Nothing to do if no Config.ps1 yet (fresh install)
        [void]$actions.Add('schema baseline ready for Config.ps1')
        $from = 1
    }

    if ($from -lt 2 -and $TargetVersion -ge 2) {
        $optPath = Join-Path $ScriptRoot 'Config\SyncMeOptions.json'
        if (-not (Test-Path -LiteralPath $optPath)) {
            if (Get-Command Get-SyncMeOptions -ErrorAction SilentlyContinue) {
                $opts = Get-SyncMeOptions -ScriptRoot $ScriptRoot
                $dir = Split-Path $optPath -Parent
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [IO.File]::WriteAllText($optPath, (($opts | ConvertTo-Json -Depth 6) + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
                [void]$actions.Add('created Config/SyncMeOptions.json defaults')
            }
        } else {
            [void]$actions.Add('SyncMeOptions.json already present')
        }

        # Ensure BackupSets have Id / DisplayName via reload path (non-destructive)
        if (Get-Command Get-SyncMeSetsFromConfigFile -ErrorAction SilentlyContinue) {
            $sets = @(Get-SyncMeSetsFromConfigFile -ScriptRoot $ScriptRoot)
            [void]$actions.Add(('validated {0} backup set(s)' -f $sets.Count))
        }
        Set-SyncMeConfigSchemaVersion -ScriptRoot $ScriptRoot -Version 2
        $from = 2
    }

    Set-SyncMeConfigSchemaVersion -ScriptRoot $ScriptRoot -Version $TargetVersion
    return @{
        Ok      = $true
        From    = (Get-SyncMeConfigSchemaVersion -ScriptRoot $ScriptRoot)
        To      = $TargetVersion
        Actions = @($actions)
        Skipped = $false
    }
}
