#Requires -Version 5.1
<#
.SYNOPSIS
  SyncMe backup engine: pulls source data into a restic repo on the Backup PC,
  prunes old snapshots, and optionally restores a plain-file copy to Disk 2.

.DESCRIPTION
  Run via SyncMe console / Task Scheduler on the Backup PC. Configure in Config.ps1.
  Store the restic password and optional SMB share credentials in Windows Credential Manager
  (see README.md).

.EXAMPLE
  .\SyncMe-Backup.ps1

.EXAMPLE
  .\SyncMe-Backup.ps1 -SkipArchive -NoNotify
#>
[CmdletBinding()]
param(
    [switch]$SkipArchive,
    [switch]$ForceArchive,
    [switch]$SkipPrune,
    [switch]$NoNotify,
    [switch]$WhatIf,
    [switch]$SkipCheck,
    [switch]$RunDataCheck,
    [switch]$CheckOnly,
    [switch]$PruneOnly,
    [string]$SetId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
. (Join-Path $ScriptRoot 'Config.ps1')
. (Join-Path $ScriptRoot 'Modules\Common.ps1')
. (Join-Path $ScriptRoot 'Modules\Notify.ps1')
. (Join-Path $ScriptRoot 'Modules\Restore.ps1')
. (Join-Path $ScriptRoot 'Modules\Report.ps1')
. (Join-Path $ScriptRoot 'Modules\Sets.ps1')
foreach ($mod in @('Update.ps1', 'MonitorClient.ps1', 'LocalOpsClient.ps1')) {
    $modPath = Join-Path $ScriptRoot ('Modules\' + $mod)
    if (-not (Test-Path -LiteralPath $modPath)) {
        throw "Missing $modPath. Re-run SyncMe-Setup 1.4.0 (or copy Modules\$mod into the install folder)."
    }
    . $modPath
}

$Config = $null
if ($SetId) {
    $Config = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId $SetId
} elseif (Get-Command Get-BackupConfig -ErrorAction SilentlyContinue) {
    $Config = Get-BackupConfig
    if (-not $Config) {
        $Config = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId ''
    }
} else {
    $Config = Get-SyncMeSetById -ScriptRoot $ScriptRoot -SetId ''
}
if (-not $Config) { throw 'No SyncMe backup set configured. Run the setup wizard.' }

$ActiveSetId = 'set1'
if ($Config.PSObject.Properties.Name -contains 'Id' -and $Config.Id) {
    $ActiveSetId = [string]$Config.Id
}

function Resolve-ConfigPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $ScriptRoot $Path)
}

function Write-Log {
    param(
        [string]$Message,
        [string]$LogPath,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($LogPath) {
        try { Add-SyncMeSharedLine -Path $LogPath -Line $line } catch {
            try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
        }
    }
    if ($Level -eq 'ERROR') {
        Write-Host $line -ForegroundColor Red
    } elseif ($Level -eq 'WARN') {
        Write-Host $line -ForegroundColor Yellow
    } else {
        Write-Host $line
    }
}

function Get-UncShareRoot {
    param([string]$UncPath)
    if ($UncPath -match '^\\\\([^\\]+)\\([^\\]+)') {
        return '\\{0}\{1}' -f $Matches[1], $Matches[2]
    }
    return $null
}

function Resolve-BackupSourcePaths {
    <#
      Returns hashtable: EffectivePaths, SourceMode, PointerValue, Detail, OpenFileRisk
    #>
    param(
        [string[]]$ConfiguredPaths,
        $Config,
        [string]$LogPath
    )

    $mode = 'Live'
    $pointerValue = ''
    $detail = 'Using configured source paths.'
    $openRisk = 'Low'
    $effective = New-Object System.Collections.Generic.List[string]

    $useShadow = $false
    if ($Config.PSObject.Properties.Name -contains 'UseShadowCopySources') {
        $useShadow = [bool]$Config.UseShadowCopySources
    }

    $anyUnc = $false
    foreach ($p in $ConfiguredPaths) {
        if ($p -match '^\\\\[^\\]+\\[^\\]+') { $anyUnc = $true; break }
    }
    if (-not $anyUnc) {
        $detail = 'Using local source path(s) on the Backup PC.'
    } elseif (-not $useShadow) {
        $detail = 'Using live UNC paths.'
    }

    if (-not $useShadow) {
        foreach ($p in $ConfiguredPaths) { $effective.Add($p) }
        return @{
            EffectivePaths = @($effective)
            SourceMode     = $mode
            PointerValue   = $pointerValue
            Detail         = $detail
            OpenFileRisk   = $(if ($anyUnc) { 'Medium' } else { 'Low' })
        }
    }

    $pointerNames = New-Object System.Collections.Generic.List[string]
    if ($Config.PSObject.Properties.Name -contains 'ShadowPointerRelativePath' -and $Config.ShadowPointerRelativePath) {
        [void]$pointerNames.Add([string]$Config.ShadowPointerRelativePath)
    }
    foreach ($n in @('.syncme-latest-shadow.txt', '.monarch-latest-shadow.txt')) {
        if (-not ($pointerNames -contains $n)) { [void]$pointerNames.Add($n) }
    }
    $required = $false
    if ($Config.PSObject.Properties.Name -contains 'ShadowCopyRequired') {
        $required = [bool]$Config.ShadowCopyRequired
    }

    $allShadow = $true
    foreach ($live in $ConfiguredPaths) {
        $shareRoot = Get-UncShareRoot -UncPath $live
        if (-not $shareRoot) {
            Write-Log "Cannot parse share root from $live - using live path" $LogPath 'WARN'
            $effective.Add($live)
            $allShadow = $false
            continue
        }

        $pointerUnc = $null
        $pointerName = $pointerNames[0]
        foreach ($n in $pointerNames) {
            $candidate = Join-Path $shareRoot $n
            if (Test-Path -LiteralPath $candidate) {
                $pointerUnc = $candidate
                $pointerName = $n
                break
            }
        }
        if (-not $pointerUnc) {
            $pointerUnc = Join-Path $shareRoot $pointerNames[0]
        }
        # Join-Path on UNC can be weird; build manually
        $pointerUnc = "$shareRoot\$pointerName"

        if (-not (Test-Path -LiteralPath $pointerUnc)) {
            $msg = "Shadow pointer missing: $pointerUnc"
            Write-Log $msg $LogPath 'WARN'
            if ($required) { throw "$msg (ShadowCopyRequired=true)" }
            $effective.Add($live)
            $allShadow = $false
            $detail = "Pointer missing; fell back to live path(s)."
            continue
        }

        $firstLine = (Get-Content -LiteralPath $pointerUnc -TotalCount 1 -ErrorAction Stop).Trim()
        $pointerValue = $firstLine
        $shadowBase = $firstLine
        if ($firstLine -match '^@GMT-') {
            $shadowBase = "$shareRoot\$firstLine"
        }

        # Map live path under share to path under @GMT base
        $suffix = ''
        if ($live.Length -gt $shareRoot.Length) {
            $suffix = $live.Substring($shareRoot.Length).TrimStart('\')
        }
        $shadowPath = if ($suffix) { "$shadowBase\$suffix" } else { $shadowBase }

        if (Test-Path -LiteralPath $shadowPath) {
            Write-Log "Shadow source OK: $shadowPath" $LogPath
            $effective.Add($shadowPath)
        } else {
            $msg = "Shadow path not reachable: $shadowPath (is Shadow Copies for Shared Folders enabled on office?)"
            Write-Log $msg $LogPath 'WARN'
            if ($required) { throw $msg }
            $effective.Add($live)
            $allShadow = $false
            $detail = "Shadow path unreachable; fell back to live. $msg"
        }
    }

    if ($allShadow -and $effective.Count -gt 0) {
        $mode = 'ShadowCopy'
        $openRisk = 'Low'
        $detail = "Using Shadow Copy @GMT sources via pointer '$pointerName'."
    } elseif ($effective.Count -gt 0) {
        $mode = 'LiveFallback'
        $openRisk = 'High'
        if (-not $detail) { $detail = 'Mixed/fallback to live UNC (open files may cause exit code 3).' }
    }

    return @{
        EffectivePaths = @($effective)
        SourceMode     = $mode
        PointerValue   = $pointerValue
        Detail         = $detail
        OpenFileRisk   = $openRisk
    }
}

function Get-WeeklyDataSubsetIndex {
    # Sunday=1 ... Saturday=7 for restic --read-data-subset=n/7
    $map = @{
        Sunday    = 1
        Monday    = 2
        Tuesday   = 3
        Wednesday = 4
        Thursday  = 5
        Friday    = 6
        Saturday  = 7
    }
    return $map[(Get-Date).DayOfWeek.ToString()]
}

function Get-PathFreeGb {
    param([string]$AnyPath)
    if ([string]::IsNullOrWhiteSpace($AnyPath)) { return $null }
    try {
        $root = [System.IO.Path]::GetPathRoot($AnyPath)
        if ([string]::IsNullOrWhiteSpace($root) -or $root.Length -lt 1) { return $null }
        $letter = $root.Substring(0, 1)
        $d = Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction Stop
        return [math]::Round(([double]$d.Free) / 1GB, 2)
    } catch {
        return $null
    }
}

function Test-MonarchFreeSpace {
    param(
        [string]$Path,
        [double]$MinGb,
        [string]$Label,
        [string]$LogPath,
        [switch]$RequireMounted
    )
    if ($MinGb -le 0 -and -not $RequireMounted) { return $true }
    if ($Path -match '^rclone:') {
        Write-Log "Skipping free-space check for cloud repo ($Label): $Path" $LogPath
        return $true
    }
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ($RequireMounted) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
            throw "$Label path is not available (drive missing or unmounted): $Path. Plug in / mount Disk 2 or clear ArchivePath."
        }
        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            throw "$Label parent folder does not exist: $parent"
        }
    }
    $free = Get-PathFreeGb -AnyPath $Path
    if ($null -eq $free) {
        if ($RequireMounted) {
            throw "$Label free space could not be determined (volume not mounted?): $Path"
        }
        Write-Log "Could not determine free space for $Label ($Path)" $LogPath 'WARN'
        return $true
    }
    if ($MinGb -le 0) { return $true }
    Write-Log "$Label free space: $free GB (min $MinGb GB) at $Path" $LogPath
    if ($free -lt $MinGb) {
        throw "$Label free space too low: ${free} GB available, need at least ${MinGb} GB ($Path)"
    }
    return $true
}

function Initialize-SyncMeRcloneEnvironment {
    param($Config, [string]$ScriptRoot, [string]$LogPath)
    $tools = Join-Path $ScriptRoot 'tools'
    if (Test-Path -LiteralPath $tools) {
        $env:PATH = "$tools;$env:PATH"
    }

    $rcloneExe = ''
    if ($Config.PSObject.Properties.Name -contains 'RclonePath' -and $Config.RclonePath -and (Test-Path -LiteralPath ([string]$Config.RclonePath))) {
        $rcloneExe = [string]$Config.RclonePath
    } else {
        $local = Join-Path $tools 'rclone.exe'
        if (Test-Path -LiteralPath $local) { $rcloneExe = $local }
        else {
            $cmd = Get-Command rclone -ErrorAction SilentlyContinue
            if ($cmd) { $rcloneExe = $cmd.Source }
        }
    }
    if ($rcloneExe) {
        Write-Log "Using rclone: $rcloneExe" $LogPath
        $rcloneDir = Split-Path -Parent $rcloneExe
        if ($rcloneDir) { $env:PATH = "$rcloneDir;$env:PATH" }
    }

    $conf = ''
    if ($Config.PSObject.Properties.Name -contains 'RcloneConfigPath' -and $Config.RcloneConfigPath) {
        $conf = [string]$Config.RcloneConfigPath
    }
    if (-not $conf) {
        $defaultConf = Join-Path $ScriptRoot 'Config\rclone.conf'
        if (Test-Path -LiteralPath $defaultConf) { $conf = $defaultConf }
    }
    if ($conf) {
        $env:RCLONE_CONFIG = $conf
        Write-Log "RCLONE_CONFIG=$conf" $LogPath
    }

    if ($Config.PSObject.Properties.Name -contains 'RcloneBwLimit' -and $Config.RcloneBwLimit -and [string]$Config.RcloneBwLimit -ne 'off') {
        $env:RCLONE_BWLIMIT = [string]$Config.RcloneBwLimit
    }
    if ($Config.PSObject.Properties.Name -contains 'RcloneTransfers' -and $null -ne $Config.RcloneTransfers) {
        $env:RCLONE_TRANSFERS = [string][int]$Config.RcloneTransfers
    }
    if ($Config.PSObject.Properties.Name -contains 'RcloneCheckers' -and $null -ne $Config.RcloneCheckers) {
        $env:RCLONE_CHECKERS = [string][int]$Config.RcloneCheckers
    }
    if ($Config.PSObject.Properties.Name -contains 'RcloneRetries' -and $null -ne $Config.RcloneRetries) {
        $env:RCLONE_RETRIES = [string][int]$Config.RcloneRetries
    }
    if ($Config.PSObject.Properties.Name -contains 'RcloneLowLevelRetries' -and $null -ne $Config.RcloneLowLevelRetries) {
        $env:RCLONE_LOW_LEVEL_RETRIES = [string][int]$Config.RcloneLowLevelRetries
    }
    if ($Config.PSObject.Properties.Name -contains 'RcloneMultiThreadStreams' -and $null -ne $Config.RcloneMultiThreadStreams) {
        $env:RCLONE_MULTI_THREAD_STREAMS = [string][int]$Config.RcloneMultiThreadStreams
    }
}

function Clear-SyncMeRcloneEnvironment {
    @(
        'RCLONE_CONFIG', 'RCLONE_BWLIMIT', 'RCLONE_TRANSFERS', 'RCLONE_CHECKERS',
        'RCLONE_RETRIES', 'RCLONE_LOW_LEVEL_RETRIES', 'RCLONE_MULTI_THREAD_STREAMS'
    ) | ForEach-Object {
        Remove-Item "Env:$_" -ErrorAction SilentlyContinue
    }
}

function Enter-BackupRunLock {
    param(
        [string]$LockPath,
        [double]$StaleHours,
        [string]$LogPath
    )
    $dir = Split-Path -Parent $LockPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $LockPath) {
        $raw = Get-Content -LiteralPath $LockPath -ErrorAction SilentlyContinue
        $oldPid = $null
        $started = $null
        foreach ($line in $raw) {
            if ($line -match '^PID=(.+)$') { $oldPid = [int]$Matches[1] }
            if ($line -match '^StartedUtc=(.+)$') {
                try { $started = [datetime]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
            }
        }
        $alive = $false
        if ($oldPid) {
            $alive = [bool](Get-Process -Id $oldPid -ErrorAction SilentlyContinue)
        }
        $stale = $false
        if ($started) {
            $stale = ((Get-Date).ToUniversalTime() - $started.ToUniversalTime()).TotalHours -gt $StaleHours
        } elseif (-not $alive) {
            $stale = $true
        }
        if ($alive -and -not $stale) {
            return @{ Acquired = $false; Message = "Backup already running (PID $oldPid, started $started)." }
        }
        Write-Log "Removing stale lock (PID=$oldPid alive=$alive stale=$stale)" $LogPath 'WARN'
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }
    @(
        "PID=$PID"
        "StartedUtc=$((Get-Date).ToUniversalTime().ToString('o'))"
        "Computer=$env:COMPUTERNAME"
    ) | Set-Content -LiteralPath $LockPath -Encoding UTF8
    return @{ Acquired = $true; Message = "Lock acquired: $LockPath" }
}

function Exit-BackupRunLock {
    param([string]$LockPath)
    if ($LockPath -and (Test-Path -LiteralPath $LockPath)) {
        $raw = Get-Content -LiteralPath $LockPath -ErrorAction SilentlyContinue
        $owner = $false
        foreach ($line in $raw) {
            if ($line -eq "PID=$PID") { $owner = $true }
        }
        if ($owner) {
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-LastSuccessStamp {
    param([string]$StampPath)
    $dir = Split-Path -Parent $StampPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $StampPath -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
}

function Clear-OldMonarchArtifacts {
    param(
        [string]$LogsDir,
        [string]$ReportsDir,
        [int]$RetentionDays,
        [string]$LogPath
    )
    if ($RetentionDays -le 0) { return }
    $cut = (Get-Date).AddDays(-$RetentionDays)
    foreach ($dir in @($LogsDir, $ReportsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cut -and $_.Name -notmatch 'last-success|backup\.lock|last-archive' } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "Retention deleted: $($_.FullName)" $LogPath
            }
    }
}

function Get-GenericCredentialPassword {
    <#
      Reads a password stored with cmdkey /generic:TargetName /user:... /pass:...
      Uses CredRead via P/Invoke (Windows Credential Manager).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TargetName
    )

    if (-not ('NativeCred' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class NativeCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern void CredFree(IntPtr cred);

    public static string ReadPassword(string target) {
        IntPtr ptr;
        // CRED_TYPE_GENERIC = 1
        if (!CredRead(target, 1, 0, out ptr) || ptr == IntPtr.Zero) {
            return null;
        }
        try {
            var cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0) {
                return null;
            }
            return Marshal.PtrToStringUni(cred.CredentialBlob, (int)cred.CredentialBlobSize / 2);
        } finally {
            CredFree(ptr);
        }
    }

    public static string ReadUserName(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr) || ptr == IntPtr.Zero) {
            return null;
        }
        try {
            var cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            return cred.UserName;
        } finally {
            CredFree(ptr);
        }
    }
}
"@
    }

    $password = [NativeCred]::ReadPassword($TargetName)
    if ([string]::IsNullOrEmpty($password)) {
        throw "Repository password not stored ('$TargetName'). In SyncMe, open Operations -> Store password (or Edit set -> Passwords)."
    }
    return $password
}

function Get-GenericCredentialUserName {
    param([Parameter(Mandatory)][string]$TargetName)
    # Ensure P/Invoke type is loaded (same Add-Type block as password helper)
    if (-not ('NativeCred' -as [type])) {
        [void](Get-GenericCredentialPassword -TargetName $TargetName)
    }
    $user = [NativeCred]::ReadUserName($TargetName)
    if ([string]::IsNullOrWhiteSpace($user)) {
        throw "Share credentials for '$TargetName' are incomplete (missing username). In SyncMe, edit the set and store share credentials under Passwords."
    }
    return $user
}

function Connect-BackupShare {
    param(
        [string]$CredentialName,
        [string]$DriveLetter,
        [string[]]$SourcePaths,
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($CredentialName)) {
        return $null
    }

    $pass = Get-GenericCredentialPassword -TargetName $CredentialName
    $user = Get-GenericCredentialUserName -TargetName $CredentialName
    $secure = ConvertTo-SecureString $pass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($user, $secure)

    # Use the root of the first UNC path as the share to map (skip local drive paths)
    $firstUnc = $SourcePaths | Where-Object { $_ -match '^\\\\[^\\]+\\[^\\]+' } | Select-Object -First 1
    if (-not $firstUnc) {
        Write-Log 'Share credentials configured but sources are local paths - skipping SMB map.' $LogPath
        return $null
    }
    if ($firstUnc -notmatch '^\\\\([^\\]+)\\([^\\]+)') {
        throw "Cannot parse UNC share from source path: $firstUnc"
    }
    $shareRoot = '\\{0}\{1}' -f $Matches[1], $Matches[2]

    if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
        # Session connection without drive letter
        Write-Log "Connecting to share $shareRoot as $user (no drive letter)" $LogPath
        if (-not $WhatIf) {
            New-PSDrive -Name 'OfficeBackupShare' -PSProvider FileSystem -Root $shareRoot -Credential $cred -ErrorAction Stop | Out-Null
        }
        return 'OfficeBackupShare'
    }

    $letter = $DriveLetter.TrimEnd(':')
    Write-Log "Mapping ${letter}: to $shareRoot as $user" $LogPath
    if (-not $WhatIf) {
        net use "${letter}:" /delete /y 2>$null | Out-Null
        $netPass = $pass
        $result = net use "${letter}:" $shareRoot /user:$user $netPass /persistent:no 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "net use failed: $result"
        }
    }
    return $letter
}

function Disconnect-BackupShare {
    param(
        [string]$Mapped,
        [string]$LogPath
    )
    if ([string]::IsNullOrWhiteSpace($Mapped)) { return }
    try {
        if ($Mapped -eq 'OfficeBackupShare') {
            Remove-PSDrive -Name 'OfficeBackupShare' -Force -ErrorAction SilentlyContinue
        } elseif ($Mapped -match '^OfficeBackupShare') {
            Remove-PSDrive -Name $Mapped -Force -ErrorAction SilentlyContinue
        } else {
            $letter = $Mapped.TrimEnd(':')
            net use "${letter}:" /delete /y 2>$null | Out-Null
        }
        Write-Log "Disconnected share mapping '$Mapped'" $LogPath
    } catch {
        Write-Log "Share disconnect warning: $_" $LogPath 'WARN'
    }
}

function Convert-BackupSourcesToDriveLetters {
    <#
      Map each unique UNC share to a drive letter and rewrite sources for restic.
      Windows restic cannot restore snapshots that stored UNC roots as tree node names.
    #>
    param(
        [string[]]$SourcePaths,
        [string]$PreferredLetter = '',
        [string]$CredentialName = '',
        [string]$LogPath = ''
    )

    $user = $null
    $pass = $null
    if (-not [string]::IsNullOrWhiteSpace($CredentialName)) {
        try {
            $user = Get-GenericCredentialUserName -TargetName $CredentialName
            $pass = Get-GenericCredentialPassword -TargetName $CredentialName
        } catch {
            Write-Log "Share credential read warning: $($_.Exception.Message)" $LogPath 'WARN'
        }
    }

    $shareToLetter = @{}
    $mapped = New-Object System.Collections.Generic.List[string]
    $out = New-Object System.Collections.Generic.List[string]

    $usedLetters = @()
    try {
        $usedLetters = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object {
            $_.Name.Substring(0, 1).ToUpperInvariant()
        })
    } catch { }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($PreferredLetter)) {
        [void]$candidates.Add($PreferredLetter.TrimEnd(':').ToUpperInvariant())
    }
    foreach ($code in 90..67) {
        $ch = [string][char]$code
        if ($candidates -notcontains $ch) { [void]$candidates.Add($ch) }
    }

    foreach ($src in @($SourcePaths)) {
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        if ($src -notmatch '^\\\\([^\\]+)\\([^\\]+)(.*)$') {
            [void]$out.Add($src)
            continue
        }
        $server = $Matches[1]
        $share = $Matches[2]
        $rest = [string]$Matches[3]
        if ([string]::IsNullOrWhiteSpace($rest)) { $rest = '\' }
        if (-not $rest.StartsWith('\')) { $rest = '\' + $rest }
        $shareRoot = '\\{0}\{1}' -f $server, $share
        $key = $shareRoot.ToLowerInvariant()

        if (-not $shareToLetter.ContainsKey($key)) {
            $letter = $null
            try {
                $existing = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.DisplayRoot -and ($_.DisplayRoot.TrimEnd('\') -ieq $shareRoot.TrimEnd('\')) -and
                        ($_.Name -match '^[A-Za-z]$')
                    } | Select-Object -First 1
                if ($existing) {
                    $letter = $existing.Name.ToUpperInvariant()
                    Write-Log "Reusing existing mapping ${letter}: for $shareRoot" $LogPath
                }
            } catch { }

            if (-not $letter) {
                foreach ($c in $candidates) {
                    if ($usedLetters -contains $c) { continue }
                    if ($mapped -contains $c) { continue }
                    $letter = $c
                    break
                }
                if (-not $letter) {
                    throw "No free drive letter available to map UNC share $shareRoot for restic backup."
                }
                Write-Log "Mapping $shareRoot -> ${letter}: for restic (UNC path rewrite)" $LogPath
                if (-not $WhatIf) {
                    net use "${letter}:" /delete /y 2>$null | Out-Null
                    $result = $null
                    if ($user -and $pass) {
                        $result = net use "${letter}:" $shareRoot /user:$user $pass /persistent:no 2>&1
                    } else {
                        $result = net use "${letter}:" $shareRoot /persistent:no 2>&1
                    }
                    if ($LASTEXITCODE -ne 0) {
                        throw "net use failed for $shareRoot : $result"
                    }
                    [void]$mapped.Add($letter)
                } else {
                    [void]$mapped.Add($letter)
                }
            }
            $shareToLetter[$key] = $letter
            $usedLetters += $letter
        }

        $letter = $shareToLetter[$key]
        $drivePath = ('{0}:{1}' -f $letter, $rest)
        Write-Log "Source rewrite for restic: $src -> $drivePath" $LogPath
        [void]$out.Add($drivePath)
    }

    return @{
        EffectivePaths = @($out)
        MappedLetters  = @($mapped)
    }
}

function Get-ResticJsonProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Invoke-Restic {
    param(
        [string]$ResticExe,
        [string]$Repo,
        [string]$Password,
        [string[]]$Arguments,
        [string]$LogPath,
        [string]$JsonLogPath,
        [string]$ProgressPhase = 'backup'
    )

    $env:RESTIC_REPOSITORY = $Repo
    $env:RESTIC_PASSWORD = $Password

    $argLine = ($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    }) -join ' '

    Write-Log "restic $argLine" $LogPath

    if ($WhatIf) {
        Write-Log 'WhatIf: skipping restic execution' $LogPath 'WARN'
        return ,@{ ExitCode = 0; Output = @(); JsonObjects = @() }
    }

    $jsonObjects = New-Object System.Collections.Generic.List[object]
    $lastStatusObj = $null
    $summaryObj = $null
    $exit = 1

    $utf8 = New-Object System.Text.UTF8Encoding $false
    $logWriter = $null
    $logFs = $null
    $jsonWriter = $null
    $jsonFs = $null
    $lastProgressUtc = [datetime]::MinValue
    $maxTotalBytes = [long]0

    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        if ($LogPath) {
            $logDir = Split-Path -Parent $LogPath
            if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            try {
                $logFs = [System.IO.File]::Open(
                    $LogPath,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite
                )
                $logWriter = New-Object System.IO.StreamWriter($logFs, $utf8)
                $logWriter.AutoFlush = $true
            } catch {
                $logWriter = $null
                $logFs = $null
            }
        }

        # Stream JSONL as lines arrive (do not buffer the whole run in RAM).
        if ($JsonLogPath) {
            try {
                $jDir = Split-Path -Parent $JsonLogPath
                if ($jDir -and -not (Test-Path -LiteralPath $jDir)) {
                    New-Item -ItemType Directory -Path $jDir -Force | Out-Null
                }
                $jsonFs = [System.IO.File]::Open(
                    $JsonLogPath,
                    [System.IO.FileMode]::Create,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite
                )
                $jsonWriter = New-Object System.IO.StreamWriter($jsonFs, $utf8)
                $jsonWriter.AutoFlush = $true
            } catch {
                $jsonWriter = $null
                $jsonFs = $null
                try { Write-Log "Could not open restic JSONL for streaming: $($_.Exception.Message)" $LogPath 'WARN' } catch { }
            }
        }

        $exit = -1
        try {
            # Discard pipeline output so progress helpers never pollute the function return value.
            & $ResticExe @Arguments 2>&1 | ForEach-Object {
                $text = if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    if ($_.Exception -and $_.Exception.Message) { [string]$_.Exception.Message }
                    else { $_.ToString() }
                } else {
                    [string]$_
                }
                if ([string]::IsNullOrWhiteSpace($text)) { return }
                try {
                    if ($logWriter) { $logWriter.WriteLine($text) }
                    elseif ($LogPath) { Add-SyncMeSharedLine -Path $LogPath -Line $text }
                } catch { }
                try {
                    if ($jsonWriter) { $jsonWriter.WriteLine($text) }
                } catch { }

                # Extract JSON even if PowerShell prefixed the line (e.g. "restic.exe : {...}")
                $jsonText = $null
                if ($text -match '^\s*\{') {
                    $jsonText = $text.Trim()
                } elseif ($text -match '(\{.*\})\s*$') {
                    $jsonText = $Matches[1]
                }
                if ($jsonText) {
                    $obj = $null
                    try { $obj = $jsonText | ConvertFrom-Json } catch { }
                    if ($obj) {
                        $msgType = [string](Get-ResticJsonProp $obj 'message_type')
                        if ($msgType -eq 'status') {
                            $lastStatusObj = $obj
                        } elseif ($msgType -eq 'summary') {
                            $summaryObj = $obj
                            [void]$jsonObjects.Add($obj)
                        }
                        if ($msgType -eq 'status' -or $msgType -eq 'summary') {
                            $now = Get-Date
                            $force = ($msgType -eq 'summary')
                            if ($force -or ($now - $lastProgressUtc).TotalSeconds -ge 2) {
                                $lastProgressUtc = $now
                                try {
                                    $percent = $null
                                    $bytesDone = $null
                                    $totalBytes = $null
                                    $filesDone = $null
                                    $totalFiles = $null
                                    $mode = 'scanning'

                                    if ($msgType -eq 'status') {
                                        $pd = Get-ResticJsonProp $obj 'percent_done'
                                        if ($null -ne $pd) {
                                            try { $percent = [math]::Round(([double]$pd) * 100, 1) } catch { $percent = $null }
                                        }
                                        $bd = Get-ResticJsonProp $obj 'bytes_done'
                                        if ($null -ne $bd) { try { $bytesDone = [long]$bd } catch { $bytesDone = $null } }
                                        $tb = Get-ResticJsonProp $obj 'total_bytes'
                                        if ($null -ne $tb) { try { $totalBytes = [long]$tb } catch { $totalBytes = $null } }
                                        $fd = Get-ResticJsonProp $obj 'files_done'
                                        if ($null -ne $fd) { try { $filesDone = [long]$fd } catch { $filesDone = $null } }
                                        $tf = Get-ResticJsonProp $obj 'total_files'
                                        if ($null -ne $tf) { try { $totalFiles = [long]$tf } catch { $totalFiles = $null } }
                                    } elseif ($msgType -eq 'summary') {
                                        $tbp = Get-ResticJsonProp $obj 'total_bytes_processed'
                                        if ($null -ne $tbp) {
                                            try {
                                                $totalBytes = [long]$tbp
                                                $bytesDone = $totalBytes
                                            } catch {
                                                $totalBytes = $null
                                                $bytesDone = $null
                                            }
                                        }
                                        $percent = 100
                                        $mode = 'done'
                                    }

                                    if ($null -ne $totalBytes -and $totalBytes -gt $maxTotalBytes) {
                                        $maxTotalBytes = $totalBytes
                                    }
                                    $displayTotal = if ($maxTotalBytes -gt 0) { $maxTotalBytes } else { $totalBytes }

                                    if ($null -ne $percent -and $percent -ge 1) { $mode = 'transferring' }
                                    elseif ($msgType -eq 'summary') { $mode = 'done' }
                                    else { $mode = 'scanning' }

                                    $parts = New-Object System.Collections.Generic.List[string]
                                    if ($mode -eq 'scanning') {
                                        if ($null -ne $displayTotal -and $displayTotal -gt 0) {
                                            try { [void]$parts.Add(('Scanning source... {0} found so far' -f (Format-SyncMeBytes $displayTotal))) } catch { [void]$parts.Add('Scanning source...') }
                                        } else {
                                            [void]$parts.Add('Scanning source...')
                                        }
                                    } elseif ($null -ne $bytesDone -and $null -ne $displayTotal -and $displayTotal -gt 0) {
                                        try { [void]$parts.Add(('{0} of {1}' -f (Format-SyncMeBytes $bytesDone), (Format-SyncMeBytes $displayTotal))) } catch { }
                                    } elseif ($null -ne $bytesDone) {
                                        try { [void]$parts.Add((Format-SyncMeBytes $bytesDone)) } catch { }
                                    }
                                    if ($null -ne $percent -and $mode -ne 'scanning') { [void]$parts.Add(('{0}%' -f $percent)) }
                                    if ($null -ne $filesDone) {
                                        try {
                                            if ($null -ne $totalFiles) {
                                                [void]$parts.Add(('{0:N0} / {1:N0} files' -f [long]$filesDone, [long]$totalFiles))
                                            } else {
                                                [void]$parts.Add(('{0:N0} files' -f [long]$filesDone))
                                            }
                                        } catch { }
                                    }
                                    $detail = ($parts -join ' · ')
                                    $uiPercent = if ($mode -eq 'scanning') { $null } else { $percent }

                                    try {
                                        Write-SyncMeLiveProgress `
                                            -ScriptRoot $ScriptRoot `
                                            -SetId $ActiveSetId `
                                            -Phase $ProgressPhase `
                                            -Message $(if ($mode -eq 'scanning') { 'Scanning source...' } elseif ($mode -eq 'done') { 'Backup step finishing...' } else { 'Backing up...' }) `
                                            -RunId $runId `
                                            -JsonLog '' `
                                            -Percent $uiPercent `
                                            -BytesDone $bytesDone `
                                            -TotalBytes $displayTotal `
                                            -FilesDone $filesDone `
                                            -TotalFiles $totalFiles `
                                            -Detail $detail `
                                            -ProgressMode $mode
                                    } catch { }
                                } catch {
                                    # Progress UI must never abort the restic pipeline
                                }
                            }
                        }
                    }
                }
            } | Out-Null

            $lec = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
            if ($null -ne $lec -and $null -ne $lec.Value) { $exit = [int]$lec.Value }
        } catch {
            $lec = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
            if ($null -ne $lec -and $null -ne $lec.Value) { $exit = [int]$lec.Value }
            if ($exit -lt 0) { $exit = 1 }
            try { Write-Log "restic pipeline handler error (continuing with exit=$exit): $($_.Exception.Message)" $LogPath 'WARN' } catch { }
        }
    } finally {
        $ErrorActionPreference = $prevEap
        try { if ($jsonWriter) { $jsonWriter.Dispose() } } catch { }
        try { if ($jsonFs) { $jsonFs.Dispose() } } catch { }
        try { if ($logWriter) { $logWriter.Dispose() } } catch { }
        try { if ($logFs) { $logFs.Dispose() } } catch { }
        Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
    }

    # Fallback: recover summary from JSONL if live parse missed it
    if (-not $summaryObj -and $JsonLogPath -and (Test-Path -LiteralPath $JsonLogPath)) {
        try {
            $lines = @(Get-Content -LiteralPath $JsonLogPath -ErrorAction SilentlyContinue)
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                $line = [string]$lines[$i]
                $jsonText = $null
                if ($line -match '^\s*\{') { $jsonText = $line.Trim() }
                elseif ($line -match '(\{.*\})\s*$') { $jsonText = $Matches[1] }
                if (-not $jsonText) { continue }
                $obj = $null
                try { $obj = $jsonText | ConvertFrom-Json } catch { continue }
                if ((Get-ResticJsonProp $obj 'message_type') -eq 'summary') {
                    $summaryObj = $obj
                    break
                }
            }
        } catch { }
    }

    if ($summaryObj) {
        $jsonObjects.Clear()
        [void]$jsonObjects.Add($summaryObj)
        # Pipeline can leave LASTEXITCODE unset (-1) even when restic wrote a summary (success).
        if ($exit -lt 0) { $exit = 0 }
    } elseif ($lastStatusObj) {
        [void]$jsonObjects.Add($lastStatusObj)
    }
    if ($exit -lt 0) { $exit = 1 }

    # Unary comma: always return a single hashtable (never an Object[] from prior pipeline noise).
    return ,@{
        ExitCode    = $exit
        Output      = @()
        JsonObjects = @($jsonObjects)
    }
}

function Test-SyncMeResticLockError {
    param(
        [string]$Text,
        [int]$ExitCode = 1
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    # Explicit lock-acquire messages only - do not treat timeouts / rclone HTTP errors as locks.
    return [bool]($Text -match '(?i)unable to create lock|repository is already locked|repository is locked|lock file.*(locked|exclusively)|could not.*lock')
}

function Test-SyncMeOtherResticProcessRunning {
    $myPid = $PID
    $hits = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $myPid -and
        $_.CommandLine -and (
            $_.Name -match '(?i)^restic(\.exe)?$' -or
            $_.CommandLine -match '(?i)restic\.exe' -or
            $_.CommandLine -match '(?i)SyncMe-Backup\.ps1' -or
            $_.CommandLine -match '(?i)SyncMe-Restore\.ps1'
        )
    })
    return ($hits.Count -gt 0)
}

function Unlock-SyncMeStaleResticLock {
    param(
        [string]$ResticExe,
        [string]$Repo,
        [string]$Password,
        [string]$LogPath
    )
    if (Test-SyncMeOtherResticProcessRunning) {
        Write-Log 'Repository appears locked and another restic/SyncMe process is still running - not unlocking.' $LogPath 'ERROR'
        return $false
    }
    Write-Log 'Stale restic lock detected from previous crashed run. Executing automatic restic unlock...' $LogPath 'WARN'
    $env:RESTIC_REPOSITORY = $Repo
    $env:RESTIC_PASSWORD = $Password
    try {
        $out = & $ResticExe unlock 2>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Log ("restic unlock exit={0}: {1}" -f $code, $out.Trim()) $LogPath
        return ($code -eq 0)
    } finally {
        Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
    }
}

function Invoke-ResticWithLockRetry {
    param(
        [string]$ResticExe,
        [string]$Repo,
        [string]$Password,
        [string[]]$Arguments,
        [string]$LogPath,
        [string]$JsonLogPath,
        [string]$ProgressPhase = 'backup'
    )
    $result = Invoke-Restic `
        -ResticExe $ResticExe `
        -Repo $Repo `
        -Password $Password `
        -Arguments $Arguments `
        -LogPath $LogPath `
        -JsonLogPath $JsonLogPath `
        -ProgressPhase $ProgressPhase
    if ($result -is [System.Array]) {
        $result = @($result) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('ExitCode') } | Select-Object -Last 1
    }
    if (-not $result) { return ,@{ ExitCode = 1; Output = @(); JsonObjects = @() } }
    if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 3) { return ,$result }

    $logTail = ''
    if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
        try { $logTail = @(Get-Content -LiteralPath $LogPath -Tail 100 -ErrorAction SilentlyContinue) -join "`n" } catch { $logTail = '' }
    }
    if (-not (Test-SyncMeResticLockError -Text $logTail -ExitCode ([int]$result.ExitCode))) {
        return ,$result
    }
    if (-not (Unlock-SyncMeStaleResticLock -ResticExe $ResticExe -Repo $Repo -Password $Password -LogPath $LogPath)) {
        return ,$result
    }
    Write-Log 'Retrying restic operation once after unlock...' $LogPath 'WARN'
    $retry = Invoke-Restic `
        -ResticExe $ResticExe `
        -Repo $Repo `
        -Password $Password `
        -Arguments $Arguments `
        -LogPath $LogPath `
        -JsonLogPath $JsonLogPath `
        -ProgressPhase $ProgressPhase
    if ($retry -is [System.Array]) {
        $retry = @($retry) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('ExitCode') } | Select-Object -Last 1
    }
    if (-not $retry) { return ,@{ ExitCode = 1; Output = @(); JsonObjects = @() } }
    return ,$retry
}

function Invoke-SyncMeBackupHook {
    <#
      Non-interactive script hook with timeout (Task Scheduler safe).
      Returns @{ Ok = $true/$false; Message = '...' }
    #>
    param(
        [string]$ScriptPath,
        [string]$Label,
        [string]$LogPath,
        [int]$TimeoutSeconds = 900
    )
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        return ,@{ Ok = $true; Message = "$Label skipped (not configured)." }
    }
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        return ,@{ Ok = $false; Message = "$Label path not found: $ScriptPath" }
    }
    Write-Log ("Running {0}: {1} (timeout {2}s, NonInteractive)" -f $Label, $ScriptPath, $TimeoutSeconds) $LogPath
    $argList = @(
        '-NoProfile'
        '-NonInteractive'
        '-ExecutionPolicy', 'Bypass'
        '-File', $ScriptPath
    )
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden
        $finished = $p.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
            $msg = "$Label timed out after ${TimeoutSeconds}s and was killed."
            Write-Log $msg $LogPath 'ERROR'
            return ,@{ Ok = $false; Message = $msg }
        }
        $code = [int]$p.ExitCode
        if ($code -ne 0) {
            $msg = "$Label exited with code $code."
            Write-Log $msg $LogPath 'ERROR'
            return ,@{ Ok = $false; Message = $msg }
        }
        Write-Log "$Label completed successfully." $LogPath
        return ,@{ Ok = $true; Message = "$Label OK." }
    } catch {
        $msg = "$Label failed: $($_.Exception.Message)"
        Write-Log $msg $LogPath 'ERROR'
        return ,@{ Ok = $false; Message = $msg }
    }
}

function Get-ResticSummaryMessage {
    param($JsonObjects)
    $summary = @($JsonObjects) | Where-Object { (Get-ResticJsonProp $_ 'message_type') -eq 'summary' } | Select-Object -Last 1
    return $summary
}

function Get-ResticSummaryFromJsonl {
    param([string]$JsonLogPath)
    if ([string]::IsNullOrWhiteSpace($JsonLogPath) -or -not (Test-Path -LiteralPath $JsonLogPath)) { return $null }
    try {
        $lines = @(Get-Content -LiteralPath $JsonLogPath -ErrorAction SilentlyContinue)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = [string]$lines[$i]
            $jsonText = $null
            if ($line -match '^\s*\{') { $jsonText = $line.Trim() }
            elseif ($line -match '(\{.*\})\s*$') { $jsonText = $Matches[1] }
            if (-not $jsonText) { continue }
            $obj = $null
            try { $obj = $jsonText | ConvertFrom-Json } catch { continue }
            if ((Get-ResticJsonProp $obj 'message_type') -eq 'summary') { return $obj }
        }
    } catch { }
    return $null
}

function Set-RunInfoFromResticSummary {
    param(
        [hashtable]$RunInfo,
        $SummaryMsg
    )
    if (-not $SummaryMsg) { return $false }
    $sid = Get-ResticJsonProp $SummaryMsg 'snapshot_id'
    if ($null -ne $sid -and -not [string]::IsNullOrWhiteSpace([string]$sid)) {
        $RunInfo.SnapshotId = [string]$sid
    }
    $fn = Get-ResticJsonProp $SummaryMsg 'files_new'
    if ($null -ne $fn) { $RunInfo.FilesNew = [string]$fn }
    $fc = Get-ResticJsonProp $SummaryMsg 'files_changed'
    if ($null -ne $fc) { $RunInfo.FilesChanged = [string]$fc }
    $fu = Get-ResticJsonProp $SummaryMsg 'files_unmodified'
    if ($null -ne $fu) { $RunInfo.FilesUnmodified = [string]$fu }
    $dn = Get-ResticJsonProp $SummaryMsg 'dirs_new'
    if ($null -ne $dn) { $RunInfo.DirsNew = [string]$dn }
    $dc = Get-ResticJsonProp $SummaryMsg 'dirs_changed'
    if ($null -ne $dc) { $RunInfo.DirsChanged = [string]$dc }
    $dataAdded = Get-ResticJsonProp $SummaryMsg 'data_added'
    if ($null -ne $dataAdded) {
        try { $RunInfo.DataAdded = Format-ByteSize ([long]$dataAdded) } catch { $RunInfo.DataAdded = [string]$dataAdded }
    }
    $tbp = Get-ResticJsonProp $SummaryMsg 'total_bytes_processed'
    if ($null -ne $tbp) {
        try { $RunInfo.TotalBytesProcessed = Format-ByteSize ([long]$tbp) } catch { $RunInfo.TotalBytesProcessed = [string]$tbp }
    }
    # restic only emits message_type=summary when the backup command finished with a snapshot.
    if (-not [string]::IsNullOrWhiteSpace([string]$RunInfo.SnapshotId) -and [string]::IsNullOrWhiteSpace([string]$RunInfo.BackupExitCode)) {
        $RunInfo.BackupExitCode = '0'
    }
    return $true
}

function Recover-ResticBackupStats {
    param(
        [hashtable]$RunInfo,
        [string]$JsonLogPath,
        [string]$ResticExe,
        [string]$Repo,
        [string]$Password,
        [string]$LogPath
    )
    $summary = Get-ResticSummaryFromJsonl -JsonLogPath $JsonLogPath
    if ($summary) {
        [void](Set-RunInfoFromResticSummary -RunInfo $RunInfo -SummaryMsg $summary)
        try { Write-Log 'Recovered restic summary from backup JSONL.' $LogPath 'WARN' } catch { }
    }
    if ([string]::IsNullOrWhiteSpace([string]$RunInfo.SnapshotId) -and $ResticExe -and $Repo -and $Password) {
        try {
            $env:RESTIC_REPOSITORY = $Repo
            $env:RESTIC_PASSWORD = $Password
            $snapJson = & $ResticExe snapshots --latest --json 2>$null | Out-String
            $lec = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
            $code = if ($null -ne $lec -and $null -ne $lec.Value) { [int]$lec.Value } else { 1 }
            if ($code -eq 0 -and -not [string]::IsNullOrWhiteSpace($snapJson)) {
                $snaps = $snapJson | ConvertFrom-Json
                $latest = @($snaps) | Select-Object -First 1
                if ($latest -and $latest.short_id) {
                    $RunInfo.SnapshotId = [string]$latest.id
                    try { Write-Log "Recovered snapshot id from restic snapshots --latest: $($RunInfo.SnapshotId)" $LogPath 'WARN' } catch { }
                } elseif ($latest -and $latest.id) {
                    $RunInfo.SnapshotId = [string]$latest.id
                    try { Write-Log "Recovered snapshot id from restic snapshots --latest: $($RunInfo.SnapshotId)" $LogPath 'WARN' } catch { }
                }
            }
        } catch {
            try { Write-Log "Snapshot recovery failed: $($_.Exception.Message)" $LogPath 'WARN' } catch { }
        } finally {
            Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
            Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
        }
    }
}

function Test-ArchiveDue {
    param(
        [string]$StampFile,
        [int]$EveryDays,
        [switch]$Force
    )
    if ($Force) { return $true }
    if (-not (Test-Path -LiteralPath $StampFile)) { return $true }
    $raw = (Get-Content -LiteralPath $StampFile -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    try {
        $last = [datetime]::Parse($raw.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $true
    }
    return ((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalDays -ge $EveryDays
}

function Clear-ArchiveTarget {
    param(
        [string]$ArchivePath,
        [string]$LogPath
    )
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        New-Item -ItemType Directory -Path $ArchivePath -Force | Out-Null
        return
    }
    Write-Log "Clearing archive target: $ArchivePath" $LogPath
    if ($WhatIf) { return }
    Get-ChildItem -LiteralPath $ArchivePath -Force | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
    }
}

function Set-ArchiveStamp {
    param([string]$StampFile)
    $dir = Split-Path -Parent $StampFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not $WhatIf) {
        Set-Content -LiteralPath $StampFile -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
    }
}

# --- Prepare paths / logging ---
$reportsDir = Resolve-ConfigPath $Config.ReportsDir
$logsDir    = Resolve-ConfigPath $Config.LogsDir
$stampFile  = Resolve-ConfigPath $Config.ArchiveStampFile

foreach ($d in @($reportsDir, $logsDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

$runId     = Get-Date -Format 'yyyyMMdd-HHmmss'
$startTime = Get-Date
$logPath   = Join-Path $logsDir "backup-$runId.log"
$jsonLog   = Join-Path $logsDir "restic-backup-$runId.jsonl"
$pruneJsonLog = Join-Path $logsDir "restic-prune-$runId.jsonl"
$reportPath = Join-Path $reportsDir "backup-$runId.html"

$errors = New-Object System.Collections.Generic.List[string]
$overallSuccess = $true
$mappedShares = New-Object System.Collections.Generic.List[string]
$lockPath = Resolve-ConfigPath $(if ($Config.PSObject.Properties.Name -contains 'BackupLockFile') { $Config.BackupLockFile } else { 'Logs\backup.lock' })
$lockHeld = $false
$skippedDueToLock = $false

$runInfo = @{
    RunId               = $runId
    Success             = $false
    StartTime           = $startTime.ToString('yyyy-MM-dd HH:mm:ss')
    EndTime             = ''
    ComputerName        = $env:COMPUTERNAME
    Summary             = ''
    SourcePaths         = @($Config.SourcePaths)
    EffectiveSourcePaths = @()
    SourceMode          = ''
    ShadowPointer       = ''
    SourceDetail        = ''
    OpenFileRisk        = ''
    ExcludePatterns     = @($Config.ExcludePatterns)
    ResticRepo          = $Config.ResticRepo
    SnapshotId          = ''
    FilesNew            = ''
    FilesChanged        = ''
    FilesUnmodified     = ''
    DirsNew             = ''
    DirsChanged         = ''
    DataAdded           = ''
    TotalBytesProcessed = ''
    BackupExitCode      = ''
    PruneRan            = 'No'
    PruneExitCode       = ''
    PruneDetail         = ''
    RetentionPolicy     = "keep-last $($Config.KeepLast); daily $($Config.KeepDaily); weekly $($Config.KeepWeekly); monthly $($Config.KeepMonthly)"
    ArchiveRan          = 'No'
    ArchivePath         = $Config.ArchivePath
    ArchiveStatus       = 'Skipped'
    ArchiveDetail       = ''
    RepoCheckRan        = 'No'
    RepoCheckDetail     = ''
    RepoStatus          = 'NotChecked'
    DataCheckRan        = 'No'
    DataCheckDetail     = ''
    LastRestoreDrillSuccess = $null
    LastRestoreDrillDate    = ''
    LastRestoreDrillDetail  = ''
    LogPath             = $logPath
    ResticJsonLog       = $jsonLog
    Errors              = @()
}

Write-Log "=== SyncMe backup run $runId ===" $logPath
Write-Log "Copyright (c) 2026 Bradford Lotriet (brad@web-zilla.co.za)" $logPath
Write-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $ActiveSetId -Phase 'starting' -Message 'Starting backup job...' -RunId $runId -JsonLog ''
if ($Config.PSObject.Properties.Name -contains 'EnableWakeOnLan' -and $Config.EnableWakeOnLan -and $Config.WakeMacAddress) {
    try {
        . (Join-Path $ScriptRoot 'Modules\Sets.ps1')
        # WoL also available from SyncMe-Host; duplicate minimal send here for scheduled runs
        $mac = ([string]$Config.WakeMacAddress -replace '[^0-9A-Fa-f]', '')
        if ($mac.Length -eq 12) {
            Write-Log "Sending Wake-on-LAN to $($Config.WakeMacAddress)" $logPath
            $macBytes = New-Object byte[] 6
            for ($i = 0; $i -lt 6; $i++) { $macBytes[$i] = [Convert]::ToByte($mac.Substring($i * 2, 2), 16) }
            $packet = New-Object byte[] (6 + 16 * 6)
            for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
            for ($i = 0; $i -lt 16; $i++) { [Array]::Copy($macBytes, 0, $packet, 6 + ($i * 6), 6) }
            $udp = New-Object System.Net.Sockets.UdpClient
            try {
                $udp.EnableBroadcast = $true
                $udp.Send($packet, $packet.Length, (New-Object System.Net.IPEndPoint([Net.IPAddress]::Broadcast, 9))) | Out-Null
            } finally { $udp.Close() }
            Start-Sleep -Seconds 15
        }
    } catch {
        Write-Log "Wake-on-LAN failed: $($_.Exception.Message)" $logPath 'WARN'
    }
}
Write-Log "Computer: $env:COMPUTERNAME" $logPath

$staleHours = 36
if ($Config.PSObject.Properties.Name -contains 'LockStaleHours') { $staleHours = [double]$Config.LockStaleHours }
$lockResult = Enter-BackupRunLock -LockPath $lockPath -StaleHours $staleHours -LogPath $logPath
if (-not $lockResult.Acquired) {
    $skippedDueToLock = $true
    $overallSuccess = $true
    $msg = $lockResult.Message
    Write-Log $msg $logPath 'WARN'
    $errors.Add($msg)
    $runInfo.Summary = "SKIPPED | already running"
    $runInfo.Success = $true
    $runInfo.EndTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $runInfo.Errors = @($errors)
    try { New-BackupHtmlReport -RunInfo $runInfo -OutputPath $reportPath | Out-Null } catch { }
    if (-not $NoNotify -and $Config.EnableEmailNotifications) {
        [void](Send-BackupEmailFromConfig -Config $Config -Subject "[Backup] SKIPPED (already running) on $env:COMPUTERNAME" -Body $msg -LogPath $logPath)
    }
    Write-Log "=== Finished (skipped lock) ===" $logPath
    exit 0
}
$lockHeld = $true
Write-Log $lockResult.Message $logPath

$resticExe = ''
$resticPassword = ''

try {
    # Resolve restic (tools\restic.exe, PATH, or configured path)
    $resticExe = Get-SyncMeResticExePath -Config $Config -ScriptRoot $ScriptRoot
    Write-Log "Using restic: $resticExe" $logPath

    Initialize-SyncMeRcloneEnvironment -Config $Config -ScriptRoot $ScriptRoot -LogPath $logPath

    # Free space: repo (skipped for rclone:)
    $minRepo = 50
    if ($Config.PSObject.Properties.Name -contains 'MinFreeRepoGb') { $minRepo = [double]$Config.MinFreeRepoGb }
    Test-MonarchFreeSpace -Path $Config.ResticRepo -MinGb $minRepo -Label 'Disk1/repo' -LogPath $logPath | Out-Null

    # Password from Credential Manager
    $resticPassword = Get-GenericCredentialPassword -TargetName $Config.ResticCredentialName

    $isRcloneRepo = ([string]$Config.ResticRepo -match '^rclone:')
    if (-not $isRcloneRepo -and -not (Test-Path -LiteralPath $Config.ResticRepo)) {
        throw "restic repository path does not exist: $($Config.ResticRepo). Create the folder and run 'restic init' first."
    }
    if ($isRcloneRepo) {
        Write-Log "Cloud restic repository: $($Config.ResticRepo)" $logPath
    }

    # Tailscale advisory - never fail local/LAN backups over a missing Tailscale install.
    $netMode = 'both'
    if ($Config.PSObject.Properties.Name -contains 'NetworkMode' -and $Config.NetworkMode) {
        $netMode = [string]$Config.NetworkMode
    }
    $sourcesLookLocal = $true
    foreach ($sp in @($Config.SourcePaths)) {
        $s = [string]$sp
        if ($s.StartsWith('\\') -or $s -match '^rclone:') { $sourcesLookLocal = $false; break }
    }
    if ($netMode -eq 'lan' -or $sourcesLookLocal) {
        Write-Log ("Skipping Tailscale check (NetworkMode={0}; localSources={1})." -f $netMode, $sourcesLookLocal) $logPath
    } else {
        $ts = Test-MonarchTailscale
        if ($ts.Ok) {
            Write-Log "Tailscale: $($ts.Message) ($($ts.Detail))" $logPath
        } else {
            Write-Log "Tailscale WARNING: $($ts.Message) ($($ts.Detail))" $logPath 'WARN'
            # Only hard-error when Tailscale is required for this set.
            if ($netMode -eq 'tailscale') {
                $errors.Add("Tailscale: $($ts.Message)")
                $overallSuccess = $false
            }
        }
    }

    $toastEnabled = $Config.EnableToastNotifications -and -not $NoNotify
    $emailConfig = $null
    if (-not $NoNotify) { $emailConfig = $Config }

    # --- Check-only / prune-only modes ---
    $skipBackupPipeline = $CheckOnly -or $PruneOnly
    if ($CheckOnly) {
        Write-Log "CheckOnly mode: skipping backup/prune/archive." $logPath
        $runInfo.SourceMode = 'N/A'
        $runInfo.OpenFileRisk = 'N/A'
        $runInfo.SourceDetail = 'CheckOnly'
        $runInfo.BackupExitCode = 'skipped'
        $runInfo.PruneDetail = 'Skipped (CheckOnly).'
        $runInfo.ArchiveDetail = 'Skipped (CheckOnly).'
        $runInfo.ArchiveStatus = 'Skipped'
    }
    if ($PruneOnly) {
        Write-Log "PruneOnly mode: forget --prune only (no backup/archive)." $logPath
        $runInfo.SourceMode = 'N/A'
        $runInfo.OpenFileRisk = 'N/A'
        $runInfo.SourceDetail = 'PruneOnly'
        $runInfo.BackupExitCode = 'skipped'
        $runInfo.ArchiveDetail = 'Skipped (PruneOnly).'
        $runInfo.ArchiveStatus = 'Skipped'
        $appendOnly = $false
        if ($Config.PSObject.Properties.Name -contains 'AppendOnly') { $appendOnly = [bool]$Config.AppendOnly }
        if ($appendOnly) {
            $runInfo.PruneRan = 'No'
            $runInfo.PruneDetail = 'AppendOnly enabled: Skipping prune operation.'
            Write-Log $runInfo.PruneDetail $logPath 'WARN'
        } else {
        Write-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $ActiveSetId -Phase 'prune' -Message 'Pruning old snapshots...' -RunId $runId -JsonLog ''
        $runInfo.PruneRan = 'Yes'
        $forgetArgs = @(
            'forget'
            '--prune'
            '--json'
            '--keep-last',    [string]$Config.KeepLast
            '--keep-daily',   [string]$Config.KeepDaily
            '--keep-weekly',  [string]$Config.KeepWeekly
            '--keep-monthly', [string]$Config.KeepMonthly
        )
        foreach ($tag in $Config.SnapshotTags) {
            $forgetArgs += @('--tag', $tag)
        }
        $pruneResult = Invoke-ResticWithLockRetry `
            -ResticExe $resticExe `
            -Repo $Config.ResticRepo `
            -Password $resticPassword `
            -Arguments $forgetArgs `
            -LogPath $logPath `
            -JsonLogPath $pruneJsonLog `
            -ProgressPhase 'prune'
        if ($pruneResult -is [System.Array]) {
            $pruneResult = @($pruneResult) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('ExitCode') } | Select-Object -Last 1
        }
        if (-not $pruneResult) { $pruneResult = @{ ExitCode = 1 } }
        $runInfo.PruneExitCode = [string]$pruneResult.ExitCode
        if ($pruneResult.ExitCode -eq 0) {
            $runInfo.PruneDetail = 'Forget/prune completed successfully.'
            Write-Log $runInfo.PruneDetail $logPath
        } else {
            $overallSuccess = $false
            $runInfo.PruneDetail = "Forget/prune failed (exit $($pruneResult.ExitCode))."
            Write-Log $runInfo.PruneDetail $logPath 'ERROR'
            $errors.Add($runInfo.PruneDetail)
        }
        }
    }

    if (-not $skipBackupPipeline) {
    # Optional SMB connect (credentials)
    $mappedShare = Connect-BackupShare `
        -CredentialName $Config.ShareCredentialName `
        -DriveLetter $Config.ShareDriveLetter `
        -SourcePaths $Config.SourcePaths `
        -LogPath $logPath
    if ($mappedShare) { [void]$mappedShares.Add([string]$mappedShare) }

    # Preflight: host + configured sources
    if ($Config.SourceHost) {
        $ping = Test-Connection -ComputerName $Config.SourceHost -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $ping) {
            $msg = "Cannot reach source host '$($Config.SourceHost)' over the network (Tailscale up?)."
            if ($Config.RequireSourceReachable) { throw $msg }
            Write-Log $msg $logPath 'WARN'
            $errors.Add($msg)
        } else {
            Write-Log "Source host reachable: $($Config.SourceHost)" $logPath
        }
    }

    foreach ($src in $Config.SourcePaths) {
        if (-not (Test-Path -LiteralPath $src)) {
            $msg = "Configured source path not reachable: $src"
            if ($Config.RequireSourceReachable) { throw $msg }
            Write-Log $msg $logPath 'WARN'
            $errors.Add($msg)
        } else {
            Write-Log "Configured source OK: $src" $logPath
        }
    }

    $resolved = Resolve-BackupSourcePaths -ConfiguredPaths $Config.SourcePaths -Config $Config -LogPath $logPath
    $effectiveSources = @($resolved.EffectivePaths)

    # Rewrite UNC -> drive letters so restic stores restorable paths on Windows
    $uncRewrite = Convert-BackupSourcesToDriveLetters `
        -SourcePaths $effectiveSources `
        -PreferredLetter $(if ($Config.ShareDriveLetter) { [string]$Config.ShareDriveLetter } else { '' }) `
        -CredentialName $(if ($Config.ShareCredentialName) { [string]$Config.ShareCredentialName } else { '' }) `
        -LogPath $logPath
    $effectiveSources = @($uncRewrite.EffectivePaths)
    foreach ($letter in @($uncRewrite.MappedLetters)) {
        if ($letter -and ($mappedShares -notcontains $letter)) {
            [void]$mappedShares.Add([string]$letter)
        }
    }

    $runInfo.EffectiveSourcePaths = $effectiveSources
    $runInfo.SourceMode = $resolved.SourceMode
    $runInfo.ShadowPointer = $resolved.PointerValue
    $runInfo.SourceDetail = $resolved.Detail
    $runInfo.OpenFileRisk = $resolved.OpenFileRisk
    Write-Log "SourceMode=$($resolved.SourceMode); OpenFileRisk=$($resolved.OpenFileRisk); $($resolved.Detail)" $logPath

    foreach ($src in $effectiveSources) {
        if (-not (Test-Path -LiteralPath $src)) {
            $msg = "Effective source path not reachable: $src"
            if ($Config.RequireSourceReachable) { throw $msg }
            Write-Log $msg $logPath 'WARN'
            $errors.Add($msg)
        }
    }

    $sourceSummary = ($effectiveSources -join ', ')
    try {
        Send-BackupStartNotification `
            -SourceSummary $sourceSummary `
            -AppId $Config.ToastAppId `
            -Enabled:$toastEnabled `
            -Config $emailConfig `
            -LogPath $logPath
    } catch {
        Write-Log "Start notification failed (ignored): $($_.Exception.Message)" $logPath 'WARN'
    }

    # --- PreBackupScript (NonInteractive + timeout) then restic backup ---
    $runBackup = $true
    $prePath = ''
    if ($Config.PSObject.Properties.Name -contains 'PreBackupScript') { $prePath = [string]$Config.PreBackupScript }
    if (-not [string]::IsNullOrWhiteSpace($prePath)) {
        $preHook = Invoke-SyncMeBackupHook -ScriptPath $prePath -Label 'PreBackupScript' -LogPath $logPath -TimeoutSeconds 900
        if ($preHook -is [System.Array]) {
            $preHook = @($preHook) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Ok') } | Select-Object -Last 1
        }
        if (-not $preHook -or -not $preHook.Ok) {
            $runBackup = $false
            $overallSuccess = $false
            $msg = if ($preHook) { [string]$preHook.Message } else { 'PreBackupScript failed.' }
            $errors.Add($msg)
            $runInfo.BackupExitCode = 'pre-failed'
            $runInfo.Summary = $msg
            Write-Log 'Aborting restic backup because PreBackupScript failed.' $logPath 'ERROR'
        }
    }

    if ($runBackup) {
    Write-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $ActiveSetId -Phase 'backup' -Message 'Backing up sources into Disk 1...' -RunId $runId -JsonLog ''
    $backupArgs = @(
        'backup'
        '--json'
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.SourceHost)) {
        $backupArgs += @('--host', [string]$Config.SourceHost)
    }
    foreach ($tag in $Config.SnapshotTags) {
        $backupArgs += @('--tag', $tag)
    }
    foreach ($ex in @(Merge-SyncMeExcludePatterns -Existing @($Config.ExcludePatterns))) {
        $backupArgs += @('--exclude', $ex)
    }
    $limitUp = 0
    if ($Config.PSObject.Properties.Name -contains 'ResticLimitUploadKByte') {
        $limitUp = [int]$Config.ResticLimitUploadKByte
    }
    if ($limitUp -gt 0) {
        $backupArgs += @('--limit-upload', [string]$limitUp)
    }
    $backupArgs += $effectiveSources

    $backupResult = Invoke-ResticWithLockRetry `
        -ResticExe $resticExe `
        -Repo $Config.ResticRepo `
        -Password $resticPassword `
        -Arguments $backupArgs `
        -LogPath $logPath `
        -JsonLogPath $jsonLog

    # Normalize in case any caller pollution still returned an array.
    if ($backupResult -is [System.Array]) {
        $backupResult = @($backupResult) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('ExitCode') } | Select-Object -Last 1
    }
    if (-not $backupResult) {
        $backupResult = @{ ExitCode = 1; JsonObjects = @() }
        Write-Log 'Invoke-Restic returned no usable result object.' $logPath 'ERROR'
    }

    $runInfo.BackupExitCode = [string]$backupResult.ExitCode
    $summaryMsg = Get-ResticSummaryMessage -JsonObjects $backupResult.JsonObjects
    if (-not $summaryMsg) {
        $summaryMsg = Get-ResticSummaryFromJsonl -JsonLogPath $jsonLog
    }
    if (-not (Set-RunInfoFromResticSummary -RunInfo $runInfo -SummaryMsg $summaryMsg)) {
        if ($backupResult.ExitCode -eq 0 -or $backupResult.ExitCode -eq 3) {
            Write-Log 'restic returned success but no JSON summary was parsed - attempting recovery.' $logPath 'WARN'
            Recover-ResticBackupStats `
                -RunInfo $runInfo `
                -JsonLogPath $jsonLog `
                -ResticExe $resticExe `
                -Repo $Config.ResticRepo `
                -Password $resticPassword `
                -LogPath $logPath
        }
    }

    # restic exit 3 = incomplete (some files unread); treat as warning but continue
    if ($backupResult.ExitCode -eq 0) {
        Write-Log "Backup completed. Snapshot=$($runInfo.SnapshotId) Added=$($runInfo.DataAdded)" $logPath
    } elseif ($backupResult.ExitCode -eq 3) {
        $msg = "restic exit 3: some files could not be read (often open Office/PST on a LIVE share). SourceMode=$($runInfo.SourceMode); OpenFileRisk=$($runInfo.OpenFileRisk). Snapshot may still be usable - review log for skipped paths. Prefer Shadow Copies (@GMT) via OfficeAgent."
        Write-Log $msg $logPath 'WARN'
        $errors.Add($msg)
        if ($runInfo.SourceMode -ne 'ShadowCopy') {
            $runInfo.OpenFileRisk = 'High'
        }
    } else {
        $overallSuccess = $false
        $msg = "restic backup failed with exit code $($backupResult.ExitCode)."
        Write-Log $msg $logPath 'ERROR'
        $errors.Add($msg)
    }

    # --- forget --prune ---
    $appendOnly = $false
    if ($Config.PSObject.Properties.Name -contains 'AppendOnly') { $appendOnly = [bool]$Config.AppendOnly }
    if ($appendOnly) {
        $runInfo.PruneRan = 'No'
        $runInfo.PruneDetail = 'AppendOnly enabled: Skipping prune operation.'
        Write-Log $runInfo.PruneDetail $logPath 'WARN'
    } elseif (-not $SkipPrune -and $overallSuccess) {
        Write-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $ActiveSetId -Phase 'prune' -Message 'Pruning old snapshots...' -RunId $runId -JsonLog ''
        $runInfo.PruneRan = 'Yes'
        $forgetArgs = @(
            'forget'
            '--prune'
            '--json'
            '--keep-last',    [string]$Config.KeepLast
            '--keep-daily',   [string]$Config.KeepDaily
            '--keep-weekly',  [string]$Config.KeepWeekly
            '--keep-monthly', [string]$Config.KeepMonthly
        )
        foreach ($tag in $Config.SnapshotTags) {
            $forgetArgs += @('--tag', $tag)
        }

        $pruneResult = Invoke-ResticWithLockRetry `
            -ResticExe $resticExe `
            -Repo $Config.ResticRepo `
            -Password $resticPassword `
            -Arguments $forgetArgs `
            -LogPath $logPath `
            -JsonLogPath $pruneJsonLog `
            -ProgressPhase 'prune'

        if ($pruneResult -is [System.Array]) {
            $pruneResult = @($pruneResult) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('ExitCode') } | Select-Object -Last 1
        }
        if (-not $pruneResult) { $pruneResult = @{ ExitCode = 1 } }

        $runInfo.PruneExitCode = [string]$pruneResult.ExitCode
        if ($pruneResult.ExitCode -eq 0) {
            $runInfo.PruneDetail = 'Forget/prune completed successfully.'
            Write-Log $runInfo.PruneDetail $logPath
        } else {
            $overallSuccess = $false
            $runInfo.PruneDetail = "Forget/prune failed (exit $($pruneResult.ExitCode))."
            Write-Log $runInfo.PruneDetail $logPath 'ERROR'
            $errors.Add($runInfo.PruneDetail)
        }
    } else {
        $runInfo.PruneDetail = if ($SkipPrune) { 'Skipped via -SkipPrune.' } else { 'Skipped because backup did not succeed.' }
        Write-Log $runInfo.PruneDetail $logPath 'WARN'
    }

    # --- biweekly archive ---
    $archiveDue = $false
    if ($ForceArchive) {
        $archiveDue = $true
    } elseif (-not $SkipArchive) {
        $archiveDue = Test-ArchiveDue -StampFile $stampFile -EveryDays $Config.ArchiveEveryDays
    }

    if ($archiveDue -and $overallSuccess) {
        if ([string]::IsNullOrWhiteSpace([string]$Config.ArchivePath)) {
            $runInfo.ArchiveStatus = 'Skipped'
            $runInfo.ArchiveDetail = 'Skipped - ArchivePath is empty (typical for cloud-only Disk 1).'
            Write-Log $runInfo.ArchiveDetail $logPath
        } else {
        $runInfo.ArchiveRan = 'Yes'
        Write-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $ActiveSetId -Phase 'archive' -Message 'Refreshing Disk 2 plain archive...' -RunId $runId -JsonLog ''
        Write-Log "Biweekly archive is due - restoring latest snapshot to $($Config.ArchivePath)" $logPath
        $safeArch = Test-SyncMeArchivePathSafe -ArchivePath ([string]$Config.ArchivePath)
        if (-not $safeArch.Ok) {
            throw $safeArch.Message
        }
        $minArch = 100
        if ($Config.PSObject.Properties.Name -contains 'MinFreeArchiveGb') { $minArch = [double]$Config.MinFreeArchiveGb }
        Test-MonarchFreeSpace -Path $Config.ArchivePath -MinGb $minArch -Label 'Disk2/archive' -LogPath $logPath -RequireMounted | Out-Null

        try {
            if ($Config.ClearArchiveBeforeRestore) {
                Clear-ArchiveTarget -ArchivePath $Config.ArchivePath -LogPath $logPath
            } elseif (-not (Test-Path -LiteralPath $Config.ArchivePath)) {
                New-Item -ItemType Directory -Path $Config.ArchivePath -Force | Out-Null
            }

            $restoreArgs = @(
                'restore'
                'latest'
                '--target', $Config.ArchivePath
            )
            foreach ($tag in $Config.SnapshotTags) {
                $restoreArgs += @('--tag', $tag)
            }

            $restoreResult = Invoke-Restic `
                -ResticExe $resticExe `
                -Repo $Config.ResticRepo `
                -Password $resticPassword `
                -Arguments $restoreArgs `
                -LogPath $logPath `
                -JsonLogPath $null

            if ($restoreResult.ExitCode -eq 0) {
                Set-ArchiveStamp -StampFile $stampFile
                $runInfo.ArchiveStatus = 'Success'
                $runInfo.ArchiveDetail = "Restored latest snapshot to $($Config.ArchivePath)."
                Write-Log $runInfo.ArchiveDetail $logPath
            } else {
                $overallSuccess = $false
                $runInfo.ArchiveStatus = 'Failed'
                $runInfo.ArchiveDetail = "restic restore failed (exit $($restoreResult.ExitCode))."
                Write-Log $runInfo.ArchiveDetail $logPath 'ERROR'
                $errors.Add($runInfo.ArchiveDetail)
            }
        } catch {
            $overallSuccess = $false
            $runInfo.ArchiveStatus = 'Failed'
            $runInfo.ArchiveDetail = $_.Exception.Message
            Write-Log "Archive step error: $_" $logPath 'ERROR'
            $errors.Add($runInfo.ArchiveDetail)
        }
        } # end ArchivePath non-empty
    } elseif ($SkipArchive) {
        $runInfo.ArchiveStatus = 'Skipped'
        $runInfo.ArchiveDetail = 'Skipped via -SkipArchive.'
        Write-Log $runInfo.ArchiveDetail $logPath
    } elseif (-not $overallSuccess) {
        $runInfo.ArchiveStatus = 'Skipped'
        $runInfo.ArchiveDetail = 'Skipped because earlier steps failed.'
        Write-Log $runInfo.ArchiveDetail $logPath 'WARN'
    } else {
        $runInfo.ArchiveStatus = 'Skipped'
        $runInfo.ArchiveDetail = "Not due yet (every $($Config.ArchiveEveryDays) days). Stamp: $stampFile"
        Write-Log $runInfo.ArchiveDetail $logPath
    }

    } # end if ($runBackup)

    # PostBackupScript always runs when configured (even if Pre failed / backup skipped)
    $postPath = ''
    if ($Config.PSObject.Properties.Name -contains 'PostBackupScript') { $postPath = [string]$Config.PostBackupScript }
    if (-not [string]::IsNullOrWhiteSpace($postPath)) {
        $postHook = Invoke-SyncMeBackupHook -ScriptPath $postPath -Label 'PostBackupScript' -LogPath $logPath -TimeoutSeconds 900
        if ($postHook -is [System.Array]) {
            $postHook = @($postHook) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Ok') } | Select-Object -Last 1
        }
        if (-not $postHook -or -not $postHook.Ok) {
            $msg = if ($postHook) { [string]$postHook.Message } else { 'PostBackupScript failed.' }
            Write-Log $msg $logPath 'WARN'
            $errors.Add($msg)
        }
    }

    } # end if (-not $skipBackupPipeline)

    # --- restic repository integrity check ---
    $enableCheck = $true
    if ($Config.PSObject.Properties.Name -contains 'EnableRepoCheck') {
        $enableCheck = [bool]$Config.EnableRepoCheck
    }
    if ($SkipCheck) { $enableCheck = $false }

    if ($enableCheck) {
        $runInfo.RepoCheckRan = 'Yes'
        Write-Log "Running structural restic check..." $logPath
        $checkResult = Invoke-ResticWithLockRetry `
            -ResticExe $resticExe `
            -Repo $Config.ResticRepo `
            -Password $resticPassword `
            -Arguments @('check') `
            -LogPath $logPath `
            -JsonLogPath $null `
            -ProgressPhase 'check'
        if ($checkResult -is [System.Array]) {
            $checkResult = @($checkResult) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('ExitCode') } | Select-Object -Last 1
        }
        if (-not $checkResult) { $checkResult = @{ ExitCode = 1 } }
        if ($checkResult.ExitCode -eq 0) {
            $runInfo.RepoStatus = 'OK'
            $runInfo.RepoCheckDetail = 'Structural check passed.'
            Write-Log $runInfo.RepoCheckDetail $logPath
        } else {
            $overallSuccess = $false
            $runInfo.RepoStatus = 'CHECK_FAILED'
            $runInfo.RepoCheckDetail = "Structural check FAILED (exit $($checkResult.ExitCode))."
            Write-Log $runInfo.RepoCheckDetail $logPath 'ERROR'
            $errors.Add($runInfo.RepoCheckDetail)
        }

        $weeklyDay = 'Sunday'
        if ($Config.PSObject.Properties.Name -contains 'WeeklyDataCheckDay' -and $Config.WeeklyDataCheckDay) {
            $weeklyDay = [string]$Config.WeeklyDataCheckDay
        }
        $todayName = (Get-Date).DayOfWeek.ToString()
        $doData = $RunDataCheck -or ($todayName -eq $weeklyDay)
        if ($doData -and $runInfo.RepoStatus -ne 'CHECK_FAILED') {
            $n = Get-WeeklyDataSubsetIndex
            $runInfo.DataCheckRan = 'Yes'
            Write-Log "Running weekly data subset check --read-data-subset=$n/7 ..." $logPath
            $dataResult = Invoke-ResticWithLockRetry `
                -ResticExe $resticExe `
                -Repo $Config.ResticRepo `
                -Password $resticPassword `
                -Arguments @('check', '--read-data-subset', "$n/7") `
                -LogPath $logPath `
                -JsonLogPath $null `
                -ProgressPhase 'check'
            if ($dataResult.ExitCode -eq 0) {
                $runInfo.DataCheckDetail = "Data subset $n/7 OK."
                Write-Log $runInfo.DataCheckDetail $logPath

                Write-Log 'Running advisory restore drill (restic dump of random file(s))...' $logPath
                $drill = Test-SyncMeRestoreDrill -Config $Config -SetId $ActiveSetId -LogPath $logPath
                if ($drill -is [System.Array]) {
                    $drill = @($drill) | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Ok') } | Select-Object -Last 1
                }
                $runInfo.LastRestoreDrillDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                if ($drill -and $drill.Ok -and $drill.ContainsKey('Skipped') -and $drill.Skipped) {
                    # Soft skip (no snapshots / no files): leave Success null so report shows SKIP
                    $runInfo.LastRestoreDrillSuccess = $null
                    $runInfo.LastRestoreDrillDetail = [string]$drill.Message
                    Write-Log $runInfo.LastRestoreDrillDetail $logPath
                } elseif ($drill -and $drill.Ok) {
                    $runInfo.LastRestoreDrillSuccess = $true
                    $runInfo.LastRestoreDrillDetail = [string]$drill.Message
                    Write-Log $runInfo.LastRestoreDrillDetail $logPath
                } else {
                    # Advisory only: record FAIL but do not fail the overall job or Errors list
                    $runInfo.LastRestoreDrillSuccess = $false
                    $runInfo.LastRestoreDrillDetail = if ($drill) { [string]$drill.Message } else { 'Restore drill returned no result.' }
                    Write-Log ("Restore drill FAIL (advisory, job not failed): " + $runInfo.LastRestoreDrillDetail) $logPath 'WARN'
                }
            } else {
                $overallSuccess = $false
                $runInfo.RepoStatus = 'CORRUPTED'
                $runInfo.DataCheckDetail = "Data subset $n/7 FAILED (exit $($dataResult.ExitCode))."
                Write-Log $runInfo.DataCheckDetail $logPath 'ERROR'
                $errors.Add($runInfo.DataCheckDetail)
            }
        } elseif (-not $doData) {
            $runInfo.DataCheckDetail = "Skipped (not $weeklyDay and -RunDataCheck not set)."
        }
    } else {
        $runInfo.RepoCheckDetail = 'Skipped (-SkipCheck or EnableRepoCheck=false).'
        $runInfo.RepoStatus = 'Skipped'
        Write-Log $runInfo.RepoCheckDetail $logPath
    }

} catch {
    $fatalMsg = [string]$_.Exception.Message
    if (Test-SyncMeNotifyNoiseMessage $fatalMsg) {
        Write-Log "Ignored notify noise (not a backup failure): $fatalMsg" $logPath 'WARN'
        # Do not keep SUCCESS unless restic exit + snapshot prove the backup finished.
        if ($runInfo.BackupExitCode -notin @('0', '3') -or [string]::IsNullOrWhiteSpace([string]$runInfo.SnapshotId)) {
            # Attempt recovery before deciding - restic may have finished before the noise threw.
            try {
                if ([string]::IsNullOrWhiteSpace([string]$runInfo.BackupExitCode) -or [string]::IsNullOrWhiteSpace([string]$runInfo.SnapshotId)) {
                    Recover-ResticBackupStats `
                        -RunInfo $runInfo `
                        -JsonLogPath $jsonLog `
                        -ResticExe $(if ($resticExe) { $resticExe } else { '' }) `
                        -Repo $Config.ResticRepo `
                        -Password $(if ($resticPassword) { $resticPassword } else { '' }) `
                        -LogPath $logPath
                }
            } catch { }
            if ($runInfo.BackupExitCode -notin @('0', '3') -or [string]::IsNullOrWhiteSpace([string]$runInfo.SnapshotId)) {
                $overallSuccess = $false
                Write-Log 'Notify noise occurred before restic stats were captured - marking run unsuccessful until exit/snapshot are known.' $logPath 'WARN'
            }
        }
    } else {
        $overallSuccess = $false
        $errors.Add($fatalMsg)
        Write-Log "Fatal: $fatalMsg" $logPath 'ERROR'
        try {
            if ([string]::IsNullOrWhiteSpace([string]$runInfo.BackupExitCode) -or [string]::IsNullOrWhiteSpace([string]$runInfo.SnapshotId)) {
                Recover-ResticBackupStats `
                    -RunInfo $runInfo `
                    -JsonLogPath $jsonLog `
                    -ResticExe $(if ($resticExe) { $resticExe } else { '' }) `
                    -Repo $Config.ResticRepo `
                    -Password $(if ($resticPassword) { $resticPassword } else { '' }) `
                    -LogPath $logPath
            }
        } catch { }
    }
} finally {
    foreach ($m in @($mappedShares)) {
        Disconnect-BackupShare -Mapped $m -LogPath $logPath
    }
    if ($lockHeld) { Exit-BackupRunLock -LockPath $lockPath }
    Clear-SyncMeRcloneEnvironment
    Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:RESTIC_REPOSITORY -ErrorAction SilentlyContinue
}

$endTime = Get-Date
$runInfo.EndTime = $endTime.ToString('yyyy-MM-dd HH:mm:ss')

# Last-chance recovery if backup was attempted but stats are still blank.
if (-not $CheckOnly -and -not $PruneOnly -and -not $skippedDueToLock) {
    if ([string]::IsNullOrWhiteSpace([string]$runInfo.BackupExitCode) -or (
            ($runInfo.BackupExitCode -in @('0', '3')) -and [string]::IsNullOrWhiteSpace([string]$runInfo.SnapshotId)
        )) {
        try {
            Recover-ResticBackupStats `
                -RunInfo $runInfo `
                -JsonLogPath $jsonLog `
                -ResticExe $(if ($resticExe) { $resticExe } else { '' }) `
                -Repo $Config.ResticRepo `
                -Password $(if ($resticPassword) { $resticPassword } else { '' }) `
                -LogPath $logPath
        } catch { }
    }
}

# Toast / NotifyIcon binder noise must never appear as backup Errors
$rawErrorList = @($errors)
$realErrors = @(Get-SyncMeRealErrors -Errors $rawErrorList)
$scrubbedNoise = ($rawErrorList.Count -gt $realErrors.Count)
$errors.Clear()
foreach ($re in $realErrors) { [void]$errors.Add($re) }
if ($scrubbedNoise -and $errors.Count -eq 0 -and $runInfo.BackupExitCode -in @('0', '3') -and -not [string]::IsNullOrWhiteSpace([string]$runInfo.SnapshotId)) {
    if (-not $overallSuccess) {
        Write-Log 'Restored overallSuccess after scrubbing notify noise (restic snapshot present).' $logPath 'WARN'
        $overallSuccess = $true
    }
}

# Exit-code gate: fail only when we have neither exit code nor a recovered snapshot.
if (-not $CheckOnly -and -not $PruneOnly -and -not $skippedDueToLock) {
    if ([string]::IsNullOrWhiteSpace([string]$runInfo.BackupExitCode) -and -not [string]::IsNullOrWhiteSpace([string]$runInfo.SnapshotId)) {
        $runInfo.BackupExitCode = '0'
        Write-Log 'Inferred BackupExitCode=0 from recovered restic summary/snapshot.' $logPath 'WARN'
    }
    if ([string]::IsNullOrWhiteSpace([string]$runInfo.BackupExitCode) -and [string]::IsNullOrWhiteSpace([string]$runInfo.SnapshotId)) {
        $overallSuccess = $false
        $msg = 'Backup finished without a captured restic exit code or snapshot - report stats may be incomplete. Check Logs\restic-backup-*.jsonl.'
        if ($errors -notcontains $msg) { [void]$errors.Add($msg) }
        Write-Log $msg $logPath 'ERROR'
    } elseif ($runInfo.BackupExitCode -in @('0', '3') -and -not [string]::IsNullOrWhiteSpace([string]$runInfo.SnapshotId)) {
        # Drop the obsolete "blank exit" error if recovery filled stats after the fact.
        $drop = 'Backup finished without a captured restic exit code - report stats may be incomplete. Check Logs\restic-backup-*.jsonl.'
        for ($i = $errors.Count - 1; $i -ge 0; $i--) {
            if ([string]$errors[$i] -eq $drop) { $errors.RemoveAt($i) }
        }
        # Tailscale advisory must not keep a good backup marked failed.
        for ($i = $errors.Count - 1; $i -ge 0; $i--) {
            if ([string]$errors[$i] -match '(?i)^Tailscale:') { $errors.RemoveAt($i) }
        }
        if ($errors.Count -eq 0 -and -not $overallSuccess) {
            Write-Log 'Restored overallSuccess: snapshot present and only advisory/noise errors remained.' $logPath 'WARN'
            $overallSuccess = $true
        }
    }
}

$runInfo.Success = $overallSuccess
$runInfo.Errors = @($errors)

$parts = @()
if ($runInfo.DataAdded) { $parts += "Added $($runInfo.DataAdded)" }
if ($runInfo.SnapshotId) { $parts += "Snapshot $($runInfo.SnapshotId.Substring(0, [Math]::Min(8, $runInfo.SnapshotId.Length)))" }
if (-not [string]::IsNullOrWhiteSpace([string]$runInfo.ArchivePath)) {
    $parts += "Archive $($runInfo.ArchiveStatus)"
}
if ($runInfo.SourceMode) { $parts += "Src $($runInfo.SourceMode)" }
if ($runInfo.RepoStatus) { $parts += "Repo $($runInfo.RepoStatus)" }
if ($runInfo.BackupExitCode -eq '3') { $parts += 'EXIT3' }
if (-not $overallSuccess) { $parts += 'ERRORS' }
$runInfo.Summary = ($parts -join ' | ')

try {
    New-BackupHtmlReport -RunInfo $runInfo -OutputPath $reportPath | Out-Null
    Write-Log "HTML report: $reportPath" $logPath
} catch {
    Write-Log "Failed to write HTML report: $_" $logPath 'ERROR'
    $errors.Add("HTML report: $($_.Exception.Message)")
    $overallSuccess = $false
    $runInfo.Success = $false
}

if ($overallSuccess -and -not $CheckOnly -and -not $skippedDueToLock) {
    $stampRel = 'Logs\last-success-utc.txt'
    if ($Config.PSObject.Properties.Name -contains 'LastSuccessStampFile') { $stampRel = $Config.LastSuccessStampFile }
    Set-LastSuccessStamp -StampPath (Resolve-ConfigPath $stampRel)
    Write-Log "Updated last-success stamp." $logPath
    $retDays = 90
    if ($Config.PSObject.Properties.Name -contains 'LogRetentionDays') { $retDays = [int]$Config.LogRetentionDays }
    Clear-OldMonarchArtifacts -LogsDir $logsDir -ReportsDir $reportsDir -RetentionDays $retDays -LogPath $logPath
}

$toastEnabled = $Config.EnableToastNotifications -and -not $NoNotify
$emailConfig = $null
if (-not $NoNotify) { $emailConfig = $Config }
Send-BackupCompleteNotification `
    -Success:$overallSuccess `
    -Summary $runInfo.Summary `
    -ReportPath $reportPath `
    -AppId $Config.ToastAppId `
    -Enabled:$toastEnabled `
    -Config $emailConfig `
    -LogPath $logPath

Write-Log "=== Finished ($($runInfo.Summary)) ===" $logPath
Write-SyncMeLiveProgress -ScriptRoot $ScriptRoot -SetId $ActiveSetId -Phase $(if ($overallSuccess) { 'done' } else { 'error' }) -Message $runInfo.Summary -RunId $runId -JsonLog $jsonLog
try {
    Write-SyncMeLastRun -ScriptRoot $ScriptRoot -SetId $ActiveSetId -RunInfo $runInfo
} catch {
    Write-Log "Failed to write last-run.json: $($_.Exception.Message)" $logPath 'WARN'
}

try {
    if (-not $CheckOnly -and -not $WhatIf) {
        $hbRun = $runInfo | Select-Object *
        $hbRun | Add-Member -NotePropertyName DisplayName -NotePropertyValue $(
            if ($Config.DisplayName) { [string]$Config.DisplayName } else { $ActiveSetId }
        ) -Force
        Send-SyncMeMonitorHeartbeat -ScriptRoot $ScriptRoot -SetId $ActiveSetId -RunInfo $hbRun -LogPath $logPath
        Send-SyncMeLocalOpsRegister -ScriptRoot $ScriptRoot -SetId $ActiveSetId -RunInfo $hbRun -LogPath $logPath
    }
} catch {
    Write-Log "Fleet register/heartbeat failed (non-fatal): $($_.Exception.Message)" $logPath 'WARN'
}

if (-not $overallSuccess) {
    exit 1
}
exit 0
