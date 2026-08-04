#Requires -Version 5.1
<#
.SYNOPSIS
  Merge-copy a payload tree into an install folder without nesting (ui\ui, Modules\Modules).
#>

function Copy-SyncMeTreeMerge {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestRoot,
        [string[]]$SkipNames = @()
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source root not found: $SourceRoot"
    }
    if (-not (Test-Path -LiteralPath $DestRoot)) {
        New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    }

    Get-ChildItem -LiteralPath $SourceRoot -Force | ForEach-Object {
        if ($SkipNames -contains $_.Name) { return }
        $dest = Join-Path $DestRoot $_.Name
        if ($_.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            $rc = & robocopy $_.FullName $dest /E /IS /IT /NFL /NDL /NJH /NJS /NC /NS /NP
            # robocopy: 0-7 success, >=8 failure
            if ($LASTEXITCODE -ge 8) {
                throw "robocopy failed for $($_.Name) (exit $LASTEXITCODE)"
            }
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        }
    }
}

function Clear-SyncMeNestedInstallJunk {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $junk = @(
        'Modules\Modules',
        'ui\ui',
        'ui\js\js',
        'ui\css\css',
        'ui\assets\assets',
        'OfficeAgent\OfficeAgent'
    )
    foreach ($rel in $junk) {
        $p = Join-Path $InstallRoot $rel
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
