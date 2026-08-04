#Requires -Version 5.1
<#
.SYNOPSIS
  HTML report generator for SyncMe backup runs.
#>

function ConvertTo-HtmlEncoded {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Format-ByteSize {
    param([Nullable[long]]$Bytes)
    if ($null -eq $Bytes) { return 'n/a' }
    $b = [double]$Bytes
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($b -ge 1024 -and $i -lt $units.Length - 1) {
        $b /= 1024
        $i++
    }
    return ('{0:N2} {1}' -f $b, $units[$i])
}

function New-BackupHtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$RunInfo,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$PackageVersion = ''
    )

    if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
        try {
            $candidates = @()
            if ($PSScriptRoot) {
                $candidates += (Join-Path $PSScriptRoot 'VERSION.txt')
                $candidates += (Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION.txt')
            }
            foreach ($verFile in $candidates) {
                if ($verFile -and (Test-Path -LiteralPath $verFile)) {
                    $PackageVersion = (Get-Content -LiteralPath $verFile -TotalCount 1 -ErrorAction Stop).Trim()
                    if ($PackageVersion) { break }
                }
            }
        } catch {
            $PackageVersion = ''
        }
    }

    $success = [bool]$RunInfo.Success
    $statusLabel = if ($success) { 'SUCCESS' } else { 'FAILED' }
    $statusClass = if ($success) { 'ok' } else { 'fail' }

    $errorsHtml = ''
    $reportErrors = @()
    if (Get-Command Get-SyncMeRealErrors -ErrorAction SilentlyContinue) {
        $reportErrors = @(Get-SyncMeRealErrors -Errors $RunInfo.Errors)
    } else {
        $reportErrors = @(@($RunInfo.Errors) | ForEach-Object { [string]$_ } | Where-Object {
            $_ -and
            ($_ -notmatch '(?i)Argument types do not match') -and
            ($_ -notmatch '(?i)arguments do not match') -and
            ($_ -notmatch '(?i)ShowBalloonTip') -and
            ($_ -notmatch '(?i)NotifyIcon') -and
            ($_ -notmatch '(?i)BurntToast') -and
            ($_ -notmatch '(?i)Cannot overwrite variable Host') -and
            ($_ -notmatch '(?i)Email send failed') -and
            ($_ -notmatch '(?i)Email (error|failed)') -and
            ($_ -notmatch '(?i)remote certificate is invalid') -and
            ($_ -notmatch '(?i)Authentication or Security error') -and
            ($_ -notmatch '(?i)The remote certificate is invalid')
        })
    }
    if ($reportErrors.Count -gt 0) {
        $items = ($reportErrors | ForEach-Object {
            '<li><code>{0}</code></li>' -f (ConvertTo-HtmlEncoded $_)
        }) -join "`n"
        $errorsHtml = @"
<section>
  <h2>Errors</h2>
  <ul class="errors">
    $items
  </ul>
</section>
"@
    }

    $excludeRows = ''
    if ($RunInfo.ExcludePatterns) {
        $excludeRows = ($RunInfo.ExcludePatterns | ForEach-Object {
            '<li><code>{0}</code></li>' -f (ConvertTo-HtmlEncoded $_)
        }) -join "`n"
    }

    $duration = 'n/a'
    if ($RunInfo.StartTime -and $RunInfo.EndTime) {
        $span = [datetime]$RunInfo.EndTime - [datetime]$RunInfo.StartTime
        $duration = '{0:hh\:mm\:ss}' -f $span
        if ($span.TotalHours -ge 24) {
            $duration = '{0}d {1:hh\:mm\:ss}' -f [int]$span.TotalDays, $span
        }
    }

    $archiveSection = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$RunInfo.ArchivePath)) {
        $archiveSection = @"
<section>
  <h2>Disk 2 - plain archive</h2>
  <table>
    <tr><th>Ran this cycle</th><td>{0}</td></tr>
    <tr><th>Archive path</th><td><code>{1}</code></td></tr>
    <tr><th>Result</th><td>{2}</td></tr>
    <tr><th>Detail</th><td>{3}</td></tr>
  </table>
</section>
"@ -f `
            (ConvertTo-HtmlEncoded ([string]$RunInfo.ArchiveRan)), `
            (ConvertTo-HtmlEncoded $RunInfo.ArchivePath), `
            (ConvertTo-HtmlEncoded $RunInfo.ArchiveStatus), `
            (ConvertTo-HtmlEncoded $RunInfo.ArchiveDetail)
    }

    $configuredSources = (($RunInfo.SourcePaths | ForEach-Object { '<li><code>{0}</code></li>' -f (ConvertTo-HtmlEncoded $_) }) -join "`n")
    $effectiveSources = ((@($RunInfo.EffectiveSourcePaths) | ForEach-Object { '<li><code>{0}</code></li>' -f (ConvertTo-HtmlEncoded $_) }) -join "`n")

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>SyncMe backup report - $(ConvertTo-HtmlEncoded $RunInfo.RunId)</title>
  <style>
    :root {
      --ink: #1c2430;
      --muted: #667484;
      --line: #d3dae3;
      --bg: #eef1f5;
      --card: #ffffff;
      --accent: #6ea8d9;
      --rail: #2c3644;
      --ok: #2d7a4a;
      --ok-bg: #e8f6ee;
      --fail: #b42318;
      --fail-bg: #fef3f2;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Source Sans 3", "Segoe UI", system-ui, sans-serif;
      color: var(--ink);
      background: var(--bg);
      line-height: 1.5;
      font-size: 15px;
    }
    header {
      padding: 1.75rem 2rem 1.5rem;
      border-bottom: 4px solid var(--accent);
      background: linear-gradient(180deg, #323c4a 0%, var(--rail) 100%);
      color: #fff;
    }
    header.ok { border-bottom-color: var(--ok); }
    header.fail { border-bottom-color: var(--fail); }
    .brand {
      font-size: 0.75rem;
      font-weight: 700;
      letter-spacing: 0.12em;
      text-transform: uppercase;
      color: var(--accent);
      margin: 0 0 0.5rem;
    }
    header h1 {
      margin: 0 0 0.65rem;
      font-size: 1.55rem;
      font-weight: 700;
      letter-spacing: -0.02em;
      color: #fff;
    }
    .status {
      display: inline-block;
      font-weight: 700;
      letter-spacing: 0.06em;
      font-size: 0.8rem;
      padding: 0.3rem 0.65rem;
      border-radius: 999px;
    }
    header.ok .status { color: var(--ok); background: var(--ok-bg); }
    header.fail .status { color: var(--fail); background: var(--fail-bg); }
    .run-id {
      margin-top: 0.65rem;
      color: #c5d0dc;
      font-size: 0.92rem;
    }
    .run-id code {
      background: rgba(255,255,255,0.12);
      color: #fff;
    }
    main { padding: 1.5rem 2rem 2rem; max-width: 880px; margin: 0 auto; }
    section {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 1.15rem 1.35rem;
      margin-bottom: 0.9rem;
    }
    h2 {
      margin: 0 0 0.85rem;
      font-size: 0.95rem;
      font-weight: 700;
      color: var(--rail);
      letter-spacing: 0.02em;
    }
    table { width: 100%; border-collapse: collapse; }
    th, td {
      text-align: left;
      padding: 0.45rem 0.35rem;
      border-bottom: 1px solid var(--line);
      vertical-align: top;
    }
    tr:last-child th, tr:last-child td { border-bottom: none; }
    th { width: 34%; color: var(--muted); font-weight: 600; font-size: 0.88rem; }
    code {
      font-family: Consolas, "Cascadia Mono", monospace;
      font-size: 0.86em;
      word-break: break-all;
      background: var(--bg);
      padding: 0.1rem 0.3rem;
      border-radius: 3px;
    }
    .label {
      color: var(--muted);
      margin: 0.85rem 0 0.3rem;
      font-size: 0.82rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    ul { margin: 0.25rem 0 0; padding-left: 1.2rem; }
    ul.errors { color: var(--fail); }
    footer {
      max-width: 880px;
      margin: 0 auto;
      padding: 0.5rem 2rem 2.5rem;
      color: var(--muted);
      font-size: 0.9rem;
      text-align: center;
    }
    footer strong { color: var(--rail); font-weight: 700; }
  </style>
</head>
<body>
  <header class="$statusClass">
    <p class="brand">SyncMe</p>
    <h1>Backup report</h1>
    <div class="status">$statusLabel</div>
    <div class="run-id">Run ID: <code>$(ConvertTo-HtmlEncoded $RunInfo.RunId)</code></div>
  </header>
  <main>
    <section>
      <h2>Summary</h2>
      <table>
        <tr><th>Started</th><td>$(ConvertTo-HtmlEncoded $RunInfo.StartTime)</td></tr>
        <tr><th>Finished</th><td>$(ConvertTo-HtmlEncoded $RunInfo.EndTime)</td></tr>
        <tr><th>Duration</th><td>$duration</td></tr>
        <tr><th>Computer</th><td>$(ConvertTo-HtmlEncoded $RunInfo.ComputerName)</td></tr>
        <tr><th>Summary</th><td>$(ConvertTo-HtmlEncoded $RunInfo.Summary)</td></tr>
      </table>
    </section>

    <section>
      <h2>Sources</h2>
      <table>
        <tr><th>Source mode</th><td>$(ConvertTo-HtmlEncoded $RunInfo.SourceMode)</td></tr>
        <tr><th>Open-file risk</th><td>$(ConvertTo-HtmlEncoded $RunInfo.OpenFileRisk)</td></tr>
        <tr><th>Shadow pointer</th><td><code>$(ConvertTo-HtmlEncoded $RunInfo.ShadowPointer)</code></td></tr>
        <tr><th>Source detail</th><td>$(ConvertTo-HtmlEncoded $RunInfo.SourceDetail)</td></tr>
      </table>
      <p class="label">Configured sources</p>
      <ul>$configuredSources</ul>
      <p class="label">Effective paths backed up</p>
      <ul>$effectiveSources</ul>
      <p class="label">Excludes</p>
      <ul>$excludeRows</ul>
    </section>

    <section>
      <h2>restic backup</h2>
      <table>
        <tr><th>Repository</th><td><code>$(ConvertTo-HtmlEncoded $RunInfo.ResticRepo)</code></td></tr>
        <tr><th>Snapshot ID</th><td><code>$(ConvertTo-HtmlEncoded $RunInfo.SnapshotId)</code></td></tr>
        <tr><th>Files new</th><td>$(ConvertTo-HtmlEncoded $RunInfo.FilesNew)</td></tr>
        <tr><th>Files changed</th><td>$(ConvertTo-HtmlEncoded $RunInfo.FilesChanged)</td></tr>
        <tr><th>Files unmodified</th><td>$(ConvertTo-HtmlEncoded $RunInfo.FilesUnmodified)</td></tr>
        <tr><th>Dirs new / changed</th><td>$(if ([string]::IsNullOrWhiteSpace([string]$RunInfo.DirsNew) -and [string]::IsNullOrWhiteSpace([string]$RunInfo.DirsChanged)) { '-' } else { (ConvertTo-HtmlEncoded $RunInfo.DirsNew) + ' / ' + (ConvertTo-HtmlEncoded $RunInfo.DirsChanged) })</td></tr>
        <tr><th>Data added</th><td>$(ConvertTo-HtmlEncoded $RunInfo.DataAdded)</td></tr>
        <tr><th>Total bytes processed</th><td>$(ConvertTo-HtmlEncoded $RunInfo.TotalBytesProcessed)</td></tr>
        <tr><th>Backup exit code</th><td>$(ConvertTo-HtmlEncoded $RunInfo.BackupExitCode)</td></tr>
      </table>
    </section>

    <section>
      <h2>Retention (forget - prune)</h2>
      <table>
        <tr><th>Ran</th><td>$(ConvertTo-HtmlEncoded $RunInfo.PruneRan)</td></tr>
        <tr><th>Exit code</th><td>$(ConvertTo-HtmlEncoded $RunInfo.PruneExitCode)</td></tr>
        <tr><th>Policy</th><td>$(ConvertTo-HtmlEncoded $RunInfo.RetentionPolicy)</td></tr>
        <tr><th>Detail</th><td>$(ConvertTo-HtmlEncoded $RunInfo.PruneDetail)</td></tr>
      </table>
    </section>

    $archiveSection

    <section>
      <h2>Repository integrity</h2>
      <table>
        <tr><th>Structural check</th><td>$(ConvertTo-HtmlEncoded $RunInfo.RepoCheckRan) - $(ConvertTo-HtmlEncoded $RunInfo.RepoCheckDetail)</td></tr>
        <tr><th>Repo status</th><td>$(ConvertTo-HtmlEncoded $RunInfo.RepoStatus)</td></tr>
        <tr><th>Data subset check</th><td>$(ConvertTo-HtmlEncoded $RunInfo.DataCheckRan) - $(ConvertTo-HtmlEncoded $RunInfo.DataCheckDetail)</td></tr>
        <tr><th>Restore drill</th><td>$(if ($null -ne $RunInfo.LastRestoreDrillSuccess) { if ($RunInfo.LastRestoreDrillSuccess) { 'PASS' } else { 'FAIL (advisory)' } } elseif ($RunInfo.LastRestoreDrillDetail -and ([string]$RunInfo.LastRestoreDrillDetail).StartsWith('Skipped:')) { 'SKIP' } elseif ($RunInfo.LastRestoreDrillDetail) { 'SKIP' } else { '-' }) - $(ConvertTo-HtmlEncoded $RunInfo.LastRestoreDrillDetail)$(if ($RunInfo.LastRestoreDrillDate) { ' (' + (ConvertTo-HtmlEncoded $RunInfo.LastRestoreDrillDate) + ')' } else { '' })</td></tr>
      </table>
    </section>

    $errorsHtml

    <section>
      <h2>Artifacts</h2>
      <table>
        <tr><th>HTML report</th><td><code>$(ConvertTo-HtmlEncoded $OutputPath)</code></td></tr>
        <tr><th>Log file</th><td><code>$(ConvertTo-HtmlEncoded $RunInfo.LogPath)</code></td></tr>
        <tr><th>restic JSON log</th><td><code>$(ConvertTo-HtmlEncoded $RunInfo.ResticJsonLog)</code></td></tr>
      </table>
    </section>
  </main>
  <footer><strong>Backup by SyncMe</strong> · © 2026 Bradford Lotriet (brad@web-zilla.co.za)$(if ($PackageVersion) { ' · build ' + (ConvertTo-HtmlEncoded $PackageVersion) })</footer>
</body>
</html>
"@

    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8
    return $OutputPath
}

function Export-SyncMeRescueKit {
    <#
      Printable HTML rescue kit for one backup set. Never embeds the restic password.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$ScriptRoot = '',
        [string]$OutputPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        if ($PSScriptRoot) { $ScriptRoot = Split-Path -Parent $PSScriptRoot }
        else { $ScriptRoot = (Get-Location).Path }
    }

    $setId = if ($Config.Id) { [string]$Config.Id } else { 'set1' }
    $stamp = Get-Date -Format 'yyyyMMdd'
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $reports = Join-Path $ScriptRoot 'Reports'
        if (-not (Test-Path -LiteralPath $reports)) {
            New-Item -ItemType Directory -Path $reports -Force | Out-Null
        }
        $OutputPath = Join-Path $reports ("RescueKit-{0}-{1}.html" -f $setId, $stamp)
    }

    $pkgVer = ''
    $verFile = Join-Path $ScriptRoot 'VERSION.txt'
    if (Test-Path -LiteralPath $verFile) {
        try { $pkgVer = (Get-Content -LiteralPath $verFile -TotalCount 1).Trim() } catch { }
    }

    $credName = [string]$Config.ResticCredentialName
    if ([string]::IsNullOrWhiteSpace($credName)) {
        $credName = if ($setId -ne 'set1') { "SyncMeRestic-$setId" } else { 'SyncMeRestic' }
    }

    $repo = [string]$Config.ResticRepo
    $rcloneRemote = ''
    $rclonePath = ''
    if ($repo -match '^rclone:([^:]+):(.*)$') {
        $rcloneRemote = $Matches[1]
        $rclonePath = $Matches[2]
    }

    $sourcesHtml = (@($Config.SourcePaths) | ForEach-Object {
        '<li><code>{0}</code></li>' -f (ConvertTo-HtmlEncoded ([string]$_))
    }) -join "`n"
    if (-not $sourcesHtml) { $sourcesHtml = '<li>(none configured)</li>' }

    $displayName = if ($Config.DisplayName) { [string]$Config.DisplayName } else { $setId }
    $destType = if ($Config.DestinationType) { [string]$Config.DestinationType } else { 'local' }
    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $checklist = Join-Path $ScriptRoot 'RecoveryChecklist.txt'

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>SyncMe Rescue Kit - $(ConvertTo-HtmlEncoded $setId)</title>
  <style>
    body { font-family: "Segoe UI", system-ui, sans-serif; margin: 0; color: #1c2430; background: #eef1f5; line-height: 1.5; }
    header { background: #2c3644; color: #fff; padding: 1.5rem 2rem; border-bottom: 4px solid #6ea8d9; }
    header h1 { margin: 0.35rem 0 0; font-size: 1.45rem; }
    .brand { font-size: 0.75rem; letter-spacing: 0.1em; text-transform: uppercase; color: #6ea8d9; font-weight: 700; }
    main { max-width: 820px; margin: 0 auto; padding: 1.25rem 1.5rem 2rem; }
    section { background: #fff; border: 1px solid #d3dae3; border-radius: 12px; padding: 1rem 1.2rem; margin-bottom: 0.85rem; }
    h2 { margin: 0 0 0.75rem; font-size: 1rem; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 0.4rem 0.3rem; border-bottom: 1px solid #d3dae3; vertical-align: top; }
    th { width: 32%; color: #667484; font-weight: 600; font-size: 0.88rem; }
    code { font-family: Consolas, monospace; font-size: 0.86em; word-break: break-all; background: #eef1f5; padding: 0.1rem 0.25rem; border-radius: 3px; }
    .warn { background: #fff8e6; border-color: #e6c86a; }
    .blank { border: 1px dashed #99a3ad; min-height: 2.2rem; margin-top: 0.4rem; border-radius: 6px; }
    ol { padding-left: 1.25rem; }
    footer { text-align: center; color: #667484; font-size: 0.9rem; padding-bottom: 2rem; }
    @media print { body { background: #fff; } header { -webkit-print-color-adjust: exact; print-color-adjust: exact; } }
  </style>
</head>
<body>
  <header>
    <p class="brand">SyncMe Rescue Kit</p>
    <h1>$(ConvertTo-HtmlEncoded $displayName) <small style="opacity:.75;font-weight:500">($([System.Net.WebUtility]::HtmlEncode($setId)))</small></h1>
  </header>
  <main>
    <section class="warn">
      <h2>Password vault (write by hand - never auto-filled)</h2>
      <p>The restic repository password is <strong>not</strong> stored in this file. Retrieve it from Windows Credential Manager target <code>$(ConvertTo-HtmlEncoded $credName)</code> on the Backup PC, or from your offline password manager.</p>
      <p><strong>Hand-written password (print &amp; store offline):</strong></p>
      <div class="blank"></div>
    </section>
    <section>
      <h2>Set identity</h2>
      <table>
        <tr><th>Generated</th><td>$(ConvertTo-HtmlEncoded $generated)</td></tr>
        <tr><th>SyncMe build</th><td>$(ConvertTo-HtmlEncoded $pkgVer)</td></tr>
        <tr><th>Set Id</th><td><code>$(ConvertTo-HtmlEncoded $setId)</code></td></tr>
        <tr><th>Display name</th><td>$(ConvertTo-HtmlEncoded $displayName)</td></tr>
        <tr><th>Computer (export host)</th><td>$(ConvertTo-HtmlEncoded $env:COMPUTERNAME)</td></tr>
      </table>
    </section>
    <section>
      <h2>Repository</h2>
      <table>
        <tr><th>Destination type</th><td>$(ConvertTo-HtmlEncoded $destType)</td></tr>
        <tr><th>ResticRepo</th><td><code>$(ConvertTo-HtmlEncoded $repo)</code></td></tr>
        <tr><th>Credential Manager target</th><td><code>$(ConvertTo-HtmlEncoded $credName)</code></td></tr>
        <tr><th>rclone remote</th><td>$(if ($rcloneRemote) { '<code>' + (ConvertTo-HtmlEncoded $rcloneRemote) + '</code>' } else { '-' })</td></tr>
        <tr><th>rclone path</th><td>$(if ($rclonePath) { '<code>' + (ConvertTo-HtmlEncoded $rclonePath) + '</code>' } else { '-' })</td></tr>
        <tr><th>Rclone config</th><td><code>$(ConvertTo-HtmlEncoded $(if ($Config.RcloneConfigPath) { [string]$Config.RcloneConfigPath } else { (Join-Path $ScriptRoot 'Config\rclone.conf') }))</code></td></tr>
        <tr><th>Append-only policy</th><td>$(if ($Config.AppendOnly) { 'Yes (SyncMe skips prune / blocks delete)' } else { 'No' })</td></tr>
      </table>
    </section>
    <section>
      <h2>Sources</h2>
      <ul>$sourcesHtml</ul>
    </section>
    <section>
      <h2>Manual recovery with restic CLI</h2>
      <ol>
        <li>Install restic (and rclone if the repo is <code>rclone:...</code>). Set <code>RCLONE_CONFIG</code> to the path above when using cloud.</li>
        <li>Set environment variables <code>RESTIC_REPOSITORY</code> to the repo path above and <code>RESTIC_PASSWORD</code> from your vault (never store the password in this file).</li>
        <li>List snapshots: <code>restic snapshots</code></li>
        <li>Restore to an empty folder: <code>restic restore latest --target C:\SyncMe-Restore\manual</code> (or a specific snapshot ID).</li>
        <li>Optional include: <code>restic restore &lt;id&gt; --target ... --include "exact\snapshot\path"</code></li>
      </ol>
      <p>Also see <code>$(ConvertTo-HtmlEncoded $checklist)</code> on the Backup PC.</p>
    </section>
  </main>
  <footer><strong>SyncMe Rescue Kit</strong> · © 2026 Bradford Lotriet · Print and store offline with the password vault entry</footer>
</body>
</html>
"@

    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8
    return $OutputPath
}
