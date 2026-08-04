#Requires -Version 5.1
<#
.SYNOPSIS
  Toast and SMTP email notifications for SyncMe.
#>

function Test-BurntToastAvailable {
    return [bool](Get-Module -ListAvailable -Name BurntToast)
}

function Ensure-BurntToast {
    if (Test-BurntToastAvailable) {
        Import-Module BurntToast -ErrorAction Stop
        return $true
    }
    return $false
}

function Initialize-BackupCredNative {
    if ('BackupCredNative' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class BackupCredNative {
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

function Get-BackupStoredCredential {
    param(
        [Parameter(Mandatory)]
        [string]$TargetName
    )
    Initialize-BackupCredNative
    $user = [BackupCredNative]::ReadUserName($TargetName)
    $pass = [BackupCredNative]::ReadPassword($TargetName)
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrEmpty($pass)) {
        if ($TargetName -match 'Smtp') {
            throw "Email credentials not stored ('$TargetName'). In SyncMe, edit the set and enter the SMTP password."
        }
        if ($TargetName -match 'Share') {
            throw "Share credentials not stored ('$TargetName'). In SyncMe, edit the set and store share credentials under Passwords."
        }
        throw "Repository password not stored ('$TargetName'). In SyncMe, open Operations → Store password (or Edit set → Passwords)."
    }
    $secure = ConvertTo-SecureString $pass -AsPlainText -Force
    return (New-Object System.Management.Automation.PSCredential ($user, $secure))
}

function Test-SyncMeNotifyNoiseMessage {
    <#
      True for toast / SMTP / Host-automatic-variable noise that must never fail a backup report.
    #>
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return (
        ($Message -match '(?i)Argument types do not match') -or
        ($Message -match '(?i)arguments do not match') -or
        ($Message -match '(?i)ShowBalloonTip') -or
        ($Message -match '(?i)NotifyIcon') -or
        ($Message -match '(?i)BurntToast') -or
        ($Message -match '(?i)Cannot overwrite variable Host') -or
        ($Message -match '(?i)Email send failed') -or
        ($Message -match '(?i)Email (error|failed)') -or
        ($Message -match '(?i)remote certificate is invalid') -or
        ($Message -match '(?i)Authentication or Security error') -or
        ($Message -match '(?i)The remote certificate is invalid')
    )
}

function Get-SyncMeRealErrors {
    param([AllowNull()]$Errors)
    return @(
        @($Errors) | ForEach-Object { [string]$_ } | Where-Object {
            $_ -and -not (Test-SyncMeNotifyNoiseMessage $_)
        }
    )
}

function Test-SyncMeDesktopToastSupported {
    <#
      Balloon / BurntToast need an interactive desktop session.
      Skip non-interactive / Service sessions (Task Scheduler with no desktop).
      Allow interactive Server and Domain Controller sessions (e.g. RDP on PHAMBILIPDC).
    #>
    try {
        if ([Environment]::UserInteractive -eq $false) { return $false }
    } catch { }
    $session = [string]$env:SESSIONNAME
    if ($session -match '(?i)^Service') { return $false }
    return $true
}

function Send-BackupToast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Text,

        [ValidateSet('Info', 'Success', 'Failure')]
        [string]$Status = 'Info',

        [string]$AppId = 'SyncMe',

        [switch]$Silent
    )

    # Toasts must never fail a backup — swallow all errors.
    try {
        if ($Silent) { return }

        $rawTitle = [string]$Title
        $rawText = [string]$Text
        # Keep toast/balloon text short — long multi-line strings break NotifyIcon ("Argument types do not match")
        $safeTitle = if ($rawTitle.Length -gt 63) { $rawTitle.Substring(0, 60) + '...' } else { $rawTitle }
        $oneLine = ($rawText -replace '[\r\n]+', ' ').Trim()
        if ($oneLine.Length -gt 200) { $oneLine = $oneLine.Substring(0, 197) + '...' }
        if ([string]::IsNullOrWhiteSpace($safeTitle)) { $safeTitle = 'SyncMe' }
        if ([string]::IsNullOrWhiteSpace($oneLine)) { $oneLine = 'Backup notification' }

        if (-not (Test-SyncMeDesktopToastSupported)) {
            Write-Host "[$Status] $safeTitle - $oneLine"
            return
        }

        $hasBurntToast = $false
        try {
            $hasBurntToast = Ensure-BurntToast
        } catch {
            $hasBurntToast = $false
        }

        if ($hasBurntToast) {
            try {
                New-BurntToastNotification -Text @($safeTitle, $oneLine) -ErrorAction Stop | Out-Null
                return
            } catch {
                try {
                    New-BurntToastNotification -Text $safeTitle, $oneLine -ErrorAction Stop | Out-Null
                    return
                } catch {
                    # Fall through to balloon
                }
            }
        }

        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $notify = New-Object System.Windows.Forms.NotifyIcon
            $notify.Icon = [System.Drawing.SystemIcons]::Information
            if ($Status -eq 'Failure') {
                $notify.Icon = [System.Drawing.SystemIcons]::Error
            } elseif ($Status -eq 'Success') {
                $notify.Icon = [System.Drawing.SystemIcons]::Application
            }
            $notify.Visible = $true
            $tipType = [System.Windows.Forms.ToolTipIcon]::Info
            if ($Status -eq 'Failure') { $tipType = [System.Windows.Forms.ToolTipIcon]::Error }
            elseif ($Status -eq 'Success') { $tipType = [System.Windows.Forms.ToolTipIcon]::Info }
            # Explicit [string] / [int] / enum to avoid "Argument types do not match" overloads
            $notify.ShowBalloonTip([int]8000, [string]$safeTitle, [string]$oneLine, $tipType)
            Start-Sleep -Seconds 2
            $notify.Visible = $false
            $notify.Dispose()
        } catch {
            Write-Host "[$Status] $safeTitle - $oneLine"
        }
    } catch {
        try { Write-Host "[Notify] Toast failed (ignored): $($_.Exception.Message)" } catch { }
    }
}

function Send-BackupMailMessage {
    <#
      Sends email via System.Net.Mail. Returns $true on success, $false on failure.
      Does not throw by default (backup must not fail because mail failed).
      Enables TLS 1.2; keeps full certificate validation (no bypass).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SmtpServer,

        [int]$SmtpPort = 587,

        [bool]$UseSsl = $true,

        [Parameter(Mandatory)]
        [string]$From,

        [Parameter(Mandatory)]
        [string[]]$To,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$Body,

        [string]$AttachmentPath,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [switch]$BodyAsHtml,

        [switch]$ThrowOnError,

        [string]$LogPath = ''
    )

    $message = $null
    $client = $null
    try {
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }

        $message = New-Object System.Net.Mail.MailMessage
        $message.From = New-Object System.Net.Mail.MailAddress($From)
        foreach ($addr in $To) {
            if (-not [string]::IsNullOrWhiteSpace($addr)) {
                $message.To.Add($addr.Trim())
            }
        }
        if ($message.To.Count -lt 1) {
            throw 'No valid MailTo recipients.'
        }
        $message.Subject = $Subject
        $message.Body = $Body
        $message.IsBodyHtml = [bool]$BodyAsHtml

        if ($AttachmentPath -and (Test-Path -LiteralPath $AttachmentPath)) {
            $attachment = New-Object System.Net.Mail.Attachment($AttachmentPath)
            $message.Attachments.Add($attachment)
        }

        $client = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
        $client.EnableSsl = $UseSsl
        $client.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $client.Credentials = $Credential.GetNetworkCredential()
        $client.Send($message)
        return $true
    } catch {
        if ($ThrowOnError) { throw }
        $exMsg = [string]$_.Exception.Message
        if ($_.Exception.InnerException -and $_.Exception.InnerException.Message) {
            $exMsg = $exMsg + ' | ' + [string]$_.Exception.InnerException.Message
        }
        $hint = 'Check SmtpServer hostname matches the certificate, Windows trusted roots, TLS 1.2, and provider auth. SyncMe does not bypass invalid certificates. Disable email notifications until SMTP is correct, or fix trust on this Backup PC.'
        if ($exMsg -match '(?i)certificate|Authentication or Security') {
            $hint = 'Remote certificate / TLS failed. Verify SmtpServer name, port, SmtpUseSsl, and that this PC trusts the SMTP cert CA. SyncMe never ignores invalid certificates.'
        }
        $failMsg = "Email send failed (smtp=$SmtpServer port=$SmtpPort ssl=$UseSsl): $exMsg. $hint"
        Write-Warning $failMsg
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            try {
                Add-Content -LiteralPath $LogPath -Value ("[{0}] [WARN] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $failMsg) -Encoding UTF8
            } catch { }
        }
        return $false
    } finally {
        if ($message) { $message.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Send-BackupEmailFromConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$Body,

        [string]$AttachmentPath,

        [string]$LogPath,

        [switch]$BodyAsHtml
    )

    if (-not $Config.EnableEmailNotifications) { return $false }

    try {
        $cred = Get-BackupStoredCredential -TargetName $Config.SmtpCredentialName
        $to = @($Config.MailTo | ForEach-Object { $_ })
        $ok = Send-BackupMailMessage `
            -SmtpServer $Config.SmtpServer `
            -SmtpPort ([int]$Config.SmtpPort) `
            -UseSsl ([bool]$Config.SmtpUseSsl) `
            -From $Config.MailFrom `
            -To $to `
            -Subject $Subject `
            -Body $Body `
            -AttachmentPath $AttachmentPath `
            -Credential $cred `
            -BodyAsHtml:$BodyAsHtml `
            -LogPath $LogPath

        if ($LogPath -and $ok) {
            Add-Content -LiteralPath $LogPath -Value ("[{0}] [INFO] Email sent: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Subject) -Encoding UTF8
        }
        return $ok
    } catch {
        $msg = "Email error: $($_.Exception.Message). Email is non-fatal; backup is not failed for mail issues."
        Write-Warning $msg
        if ($LogPath) {
            Add-Content -LiteralPath $LogPath -Value ("[{0}] [WARN] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
        }
        return $false
    }
}

function Get-SyncMeEmailShellHtml {
    param(
        [string]$Title,
        [string]$StatusLabel,
        [bool]$Success,
        [string]$InnerHtml
    )
    $statusColor = if ($Success) { '#2d7a4a' } else { '#b42318' }
    $statusBg = if ($Success) { '#e8f6ee' } else { '#fef3f2' }
    $encTitle = [System.Net.WebUtility]::HtmlEncode($Title)
    $encStatus = [System.Net.WebUtility]::HtmlEncode($StatusLabel)
    return @"
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /></head>
<body style="margin:0;padding:0;background:#eef1f5;font-family:'Source Sans 3','Segoe UI',system-ui,sans-serif;color:#1c2430;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef1f5;padding:24px 12px;">
    <tr><td align="center">
      <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border:1px solid #d3dae3;border-radius:14px;overflow:hidden;">
        <tr><td style="padding:20px 24px;background:linear-gradient(180deg,#323c4a 0%,#2c3644 100%);border-bottom:4px solid $statusColor;">
          <div style="font-size:11px;font-weight:700;letter-spacing:0.12em;text-transform:uppercase;color:#6ea8d9;">SyncMe</div>
          <div style="font-size:22px;font-weight:700;margin:6px 0 10px;letter-spacing:-0.02em;color:#ffffff;">$encTitle</div>
          <span style="display:inline-block;font-size:12px;font-weight:700;letter-spacing:0.06em;color:$statusColor;background:$statusBg;padding:4px 10px;border-radius:999px;">$encStatus</span>
        </td></tr>
        <tr><td style="padding:20px 24px;font-size:15px;line-height:1.5;">
          $InnerHtml
        </td></tr>
        <tr><td style="padding:16px 24px 22px;text-align:center;color:#667484;font-size:13px;border-top:1px solid #d3dae3;">
          <strong style="color:#2c3644;">Backup by SyncMe</strong>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>
"@
}

function Send-BackupStartNotification {
    param(
        [string]$SourceSummary,
        [string]$AppId = 'SyncMe',
        [switch]$Enabled,
        $Config,
        [string]$LogPath
    )
    if ($Enabled) {
        try {
            Send-BackupToast -Title 'SyncMe backup started' -Text "Pulling from: $SourceSummary" -Status Info -AppId $AppId
        } catch {
            try { Write-Host "[Notify] Start toast failed (ignored): $($_.Exception.Message)" } catch { }
        }
    }
    if ($Config -and $Config.EnableEmailNotifications -and $Config.EmailOnStart) {
        $encSrc = [System.Net.WebUtility]::HtmlEncode($SourceSummary)
        $encComputer = [System.Net.WebUtility]::HtmlEncode($env:COMPUTERNAME)
        $started = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $inner = @"
<p style="margin:0 0 12px;">A SyncMe backup has started on <strong>$encComputer</strong>.</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;">
  <tr><td style="color:#5a6b64;padding:4px 0;width:120px;">Started</td><td style="padding:4px 0;">$started</td></tr>
  <tr><td style="color:#5a6b64;padding:4px 0;">Sources</td><td style="padding:4px 0;word-break:break-all;"><code style="font-size:12px;">$encSrc</code></td></tr>
</table>
"@
        $body = Get-SyncMeEmailShellHtml -Title 'Backup started' -StatusLabel 'STARTED' -Success $true -InnerHtml $inner
        [void](Send-BackupEmailFromConfig -Config $Config -Subject "[SyncMe] STARTED on $env:COMPUTERNAME" -Body $body -BodyAsHtml -LogPath $LogPath)
    }
}

function Send-BackupCompleteNotification {
    param(
        [bool]$Success,
        [string]$Summary,
        [string]$ReportPath,
        [string]$AppId = 'SyncMe',
        [switch]$Enabled,
        $Config,
        [string]$LogPath
    )
    if ($Enabled) {
        try {
            $ok = [bool]$Success
            $title = if ($ok) { 'SyncMe backup completed' } else { 'SyncMe backup FAILED' }
            $status = if ($ok) { 'Success' } else { 'Failure' }
            # Do not append report path — long paths / newlines break Windows balloon toasts
            $text = if ([string]::IsNullOrWhiteSpace($Summary)) {
                if ($ok) { 'Backup finished successfully.' } else { 'Backup finished with errors.' }
            } else {
                [string]$Summary
            }
            Send-BackupToast -Title $title -Text $text -Status $status -AppId $AppId
        } catch {
            try { Write-Host "[Notify] Complete toast failed (ignored): $($_.Exception.Message)" } catch { }
        }
    }
    if ($Config -and $Config.EnableEmailNotifications -and $Config.EmailOnComplete) {
        $statusWord = if ($Success) { 'SUCCESS' } else { 'FAILED' }
        if ($Summary -match 'CORRUPTED|CHECK_FAILED') {
            $statusWord = 'CRITICAL'
        }
        $subjectPrefix = if ($statusWord -eq 'CRITICAL') { '[SyncMe] CRITICAL' } else { "[SyncMe] $statusWord" }
        $encSummary = [System.Net.WebUtility]::HtmlEncode($Summary)
        $encComputer = [System.Net.WebUtility]::HtmlEncode($env:COMPUTERNAME)
        $encReport = [System.Net.WebUtility]::HtmlEncode($ReportPath)
        $finished = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $exit3Note = ''
        if ($Summary -match 'EXIT3') {
            $exit3Note = '<p style="margin:14px 0 0;padding:10px 12px;background:#f8f1e4;border-radius:6px;font-size:13px;color:#6b5a3a;">Some source files were unread (EXIT3) — often open Office files on a live share. Prefer Shadow Copies via OfficeAgent on the source PC.</p>'
        }
        $attachNote = if ($ReportPath -and (Test-Path -LiteralPath $ReportPath)) {
            '<p style="margin:14px 0 0;color:#5a6b64;font-size:13px;">Full HTML report is attached.</p>'
        } else {
            ''
        }
        $inner = @"
<p style="margin:0 0 12px;">Backup finished on <strong>$encComputer</strong>.</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;">
  <tr><td style="color:#5a6b64;padding:4px 0;width:120px;">Finished</td><td style="padding:4px 0;">$finished</td></tr>
  <tr><td style="color:#5a6b64;padding:4px 0;">Summary</td><td style="padding:4px 0;">$encSummary</td></tr>
  <tr><td style="color:#5a6b64;padding:4px 0;">Report</td><td style="padding:4px 0;word-break:break-all;"><code style="font-size:12px;">$encReport</code></td></tr>
</table>
$exit3Note
$attachNote
"@
        $body = Get-SyncMeEmailShellHtml -Title 'Backup report' -StatusLabel $statusWord -Success:($statusWord -eq 'SUCCESS') -InnerHtml $inner
        $attach = $null
        if ($ReportPath -and (Test-Path -LiteralPath $ReportPath)) {
            $attach = $ReportPath
        }
        [void](Send-BackupEmailFromConfig `
            -Config $Config `
            -Subject "$subjectPrefix on $env:COMPUTERNAME" `
            -Body $body `
            -BodyAsHtml `
            -AttachmentPath $attach `
            -LogPath $LogPath)
    }
}

