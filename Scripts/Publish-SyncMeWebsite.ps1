#Requires -Version 5.1
param(
  [string]$HostName = $env:SYNCME_FTP_HOST,
  [string]$User = $env:SYNCME_FTP_USER,
  [string]$Pass = $env:SYNCME_FTP_PASS,
  [string]$RemoteRoot = $(if ($env:SYNCME_FTP_REMOTE) { $env:SYNCME_FTP_REMOTE } else { '/' })
)
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$site = Join-Path $root 'website'
if (-not (Test-Path $site)) { throw "Missing website/ folder at $site" }
if ([string]::IsNullOrWhiteSpace($HostName) -or [string]::IsNullOrWhiteSpace($User) -or [string]::IsNullOrWhiteSpace($Pass)) {
  throw "Set SYNCME_FTP_HOST, SYNCME_FTP_USER, SYNCME_FTP_PASS (and optional SYNCME_FTP_REMOTE)."
}
$winscp = @(
  "${env:ProgramFiles(x86)}\WinSCP\WinSCP.com",
  "${env:ProgramFiles}\WinSCP\WinSCP.com"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $winscp) { throw "WinSCP.com not found. Install WinSCP or upload website/ manually." }
$script = @"
option batch abort
option confirm off
open ftpes://${User}:${Pass}@${HostName}/ -explicit -certificate=* -passive=on
cd $RemoteRoot
put -nopermissions -nopreservetime "$site\index.html"
put -nopermissions -nopreservetime "$site\guide.html"
put -nopermissions -nopreservetime "$site\roadmap.html"
put -nopermissions -nopreservetime "$site\.htaccess"
put -nopermissions -nopreservetime "$site\css\*" css/
put -nopermissions -nopreservetime "$site\js\*" js/
put -nopermissions -nopreservetime "$site\assets\*" assets/
put -nopermissions -nopreservetime "$site\updates\latest.json" updates/
put -nopermissions -nopreservetime "$site\updates\SHA256SUMS.txt" updates/
put -nopermissions -nopreservetime "$site\updates\SyncMe-Setup-1.9.1.zip" updates/
put -nopermissions -nopreservetime "$site\updates\SyncMe-Monitor-Setup-1.9.1.zip" updates/
put -nopermissions -nopreservetime "$site\assets\screenshots\*" assets/screenshots/
exit
"@
$tmp = Join-Path $env:TEMP 'syncme-ftp-upload.txt'
Set-Content -Path $tmp -Value $script -Encoding ASCII
& $winscp /ini=nul /script=$tmp
Remove-Item $tmp -Force
Write-Host 'FTP upload finished.' -ForegroundColor Green
