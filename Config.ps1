#Requires -Version 5.1
<#
.SYNOPSIS
  Configuration for SyncMe.
  Fill paths for THIS Backup PC - do not assume drive letters from another machine.
  Do not store the restic password here - use Windows Credential Manager (see README).
  Prefer the SyncMe setup wizard; this file is the on-disk result / advanced edit surface.
#>

$script:BackupConfig = [pscustomobject]@{
    # --- Sources (UNC over LAN and/or Tailscale; admin $ shares OK) ---
    # Example: '\\pc-name\C$\Users\You\Documents'
    SourcePaths = @(
    )

    # Optional: map SMB credentials before backup (TargetName in Credential Manager, type Generic)
    # Leave empty if the share allows the scheduled-task user without explicit net use.
    # Create with: cmdkey /generic:SyncMeShare /user:PC-NAME\User /pass:*
    ShareCredentialName = ''
    # Drive letter used only for the duration of the run (empty = use UNC directly)
    ShareDriveLetter    = ''

    # --- Destination (this Backup PC) - use YOUR drive letters ---
    # Versioned restic repository (required). Example: 'D:\Backups\repo'
    ResticRepo   = ''
    # Legacy optional plain-file archive path - leave empty (not used in current SyncMe UX)
    ArchivePath  = ''

    # Credential Manager generic target that holds the restic repository password
    # Create with: cmdkey /generic:SyncMeRestic /user:restic /pass:YOUR_PASSWORD
    # Prefer SyncMe Operations -> Store password.
    ResticCredentialName = 'SyncMeRestic'

    # Optional explicit path to restic.exe if not on PATH
    ResticPath = 'restic'

    # --- Retention (restic forget --prune) ---
    KeepLast    = 7
    KeepDaily   = 14
    KeepWeekly  = 8
    KeepMonthly = 6

    # --- Optional plain-file archive to Disk 2 (skipped when ArchivePath is empty) ---
    ArchiveEveryDays     = 14
    # Stamp file updated after a successful archive (relative to script root if not absolute)
    ArchiveStampFile     = 'Logs\last-archive-utc.txt'
    # Clear archive target before restore (recommended for a true overwritten full copy)
    ClearArchiveBeforeRestore = $true

    # --- Excludes (restic --exclude patterns) ---
    # Includes Windows system paths denied on drive-root / $ share backups.
    ExcludePatterns = @(
        '~$*'
        '*.tmp'
        '*.temp'
        'Thumbs.db'
        'desktop.ini'
        '~*'
        '*.partial'
        '.DS_Store'
        'System Volume Information'
        '$Recycle.Bin'
        'Recovery'
        'pagefile.sys'
        'hiberfil.sys'
        'swapfile.sys'
    )

    # --- Tags applied to each snapshot ---
    SnapshotTags = @('syncme', 'source-site')

    # --- Notifications (toast) ---
    EnableToastNotifications = $false
    ToastAppId               = 'SyncMe'

    # --- Email (SMTP). Password is NOT stored here - use Credential Manager.
    # Prefer the SyncMe wizard. Advanced: cmdkey /generic:SyncMeSmtp /user:... /pass:...
    EnableEmailNotifications = $false
    SmtpServer               = 'smtp.office365.com'
    SmtpPort                 = 587
    SmtpUseSsl               = $true
    MailFrom                 = ''
    MailTo                   = @()
    SmtpCredentialName       = 'SyncMeSmtp'
    EmailOnStart             = $true
    EmailOnComplete          = $true

    # --- Reporting / logs (relative paths resolve against script root) ---
    ReportsDir = 'Reports'
    LogsDir    = 'Logs'

    # Host used for preflight connectivity check (Tailscale MagicDNS or hostname)
    SourceHost = ''

    # Fail the run if source path is unreachable (recommended)
    RequireSourceReachable = $true

    # --- Shadow Copies for Shared Folders (open-file safe pull) ---
    # OfficeAgent on the source writes .monarch-latest-shadow.txt under the share root.
    UseShadowCopySources     = $true
    ShadowPointerRelativePath = '.monarch-latest-shadow.txt'
    ShadowCopyRequired       = $false

    EnableWakeOnLan = $false
    WakeMacAddress  = ''

    EnableRepoCheck      = $true
    WeeklyDataCheckDay   = 'Sunday'
}
