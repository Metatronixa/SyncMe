# SyncMe

**SyncMe** — Copyright © 2026 Bradford Lotriet (`brad@web-zilla.co.za`)

Free to use — keep this credit. See [`LICENSE.txt`](LICENSE.txt).

Simple **file-level** backup from source PCs to a Backup PC using **restic**, managed from an **HTML5 console**. Sources over **LAN and/or Tailscale**. Destinations: **local disk**, **NAS (UNC)**, or **cloud via rclone** (OneDrive / Google Drive OAuth). No PHP. No database.

**Not** bare-metal imaging, antivirus, or ransomware protection — verify backups and keep separate recovery copies.

## Where to install

Install SyncMe **only on the Backup PC** (Windows 10/11 or **Windows Server**). Source machines only need shared folders (and Tailscale when offsite). Scheduled backups default to **run whether logged on or not** — required for unattended Server; see **START-HERE.txt**.

## Customer path

1. Share source folder(s); ensure UNC reachability (LAN and/or Tailscale).
2. Unzip SyncMe on the Backup PC. Open **`START-HERE.txt`**, then **`SyncMe.bat`**.
3. Complete the wizard (restic can be auto-installed). Pick network mode, folders, destination, schedule.
4. Use the dashboard for progress, actions, schedule edits, restore, and **Add backup set**.

**Build a hand-off zip:**

```powershell
.\Build-SyncMePackage.ps1
```

## Features

| Feature | Notes |
|---|---|
| Multi backup sets | Switcher on dashboard/restore; add / edit (prefill) / delete |
| Multi-folder sets | Several UNC paths in one set |
| Network mode | LAN / Tailscale / Both |
| Destinations | Local, NAS UNC, rclone cloud (OAuth in console) |
| rclone bandwidth | `--bwlimit` + transfers/retries via env; restic upload limit |
| Retention & prune | Keep* editable in console; Prune now |
| Integrity check | Structural + weekly data subset; toggle in console |
| restic mount | Browse repo via WinFsp (Mount / Unmount) |
| Live progress + cancel | restic JSON %; cancel from console (with warning) |
| Schedule | Once / Daily / Weekly with start (and optional end) date → Task Scheduler |
| Wake-on-LAN | Optional MAC per set before backup / Wake button |
| Shadow copies | OfficeAgent scripts on source PC |
| Detached Run now | Manual backup survives closing SyncMe |

## Secrets

Windows Credential Manager: `SyncMeRestic` / `SyncMeRestic-<setId>`, `SyncMeSmtp`, optional `SyncMeShare` / `SyncMeShare-<setId>`.
rclone OAuth tokens live in `Config\rclone.conf` (not in git).

## Destinations

- **Disk 1** (required): versioned restic repository — full path on *this* Backup PC (any drive letter) or NAS UNC / rclone.
- **Disk 2** (optional): plain latest-file copy. Leave blank for restic-only. Not required for Tailscale `$`-share → single-repo setups.
- Config defaults ship empty so you can run SyncMe on any server without baked-in `D:\` / `E:\` / hostnames.

Sources are UNC (LAN or Tailscale), including admin shares such as `\\pc-name\C$\Users\…`.

## How it works

```
SyncMe.bat → SyncMe-Host.ps1 (localhost) → HTML UI
                              ↓
              restic + SyncMe-Backup.ps1 -SetId … + Task Scheduler
```

## Cloud (OneDrive / Google Drive)

1. Prerequisites → **Install rclone** (or use PATH).
2. Dashboard **Cloud settings** (modal) or wizard destination → **Add OneDrive / Add Google Drive** (browser OAuth; 5-minute timeout).
3. Pick remote + folder path → **Save cloud dest**. Disk 1 becomes `rclone:remote:path`.
4. After setup apply, use **Run dry run** to verify before relying on the schedule.
4. Set bandwidth (e.g. `2M`) and retries to limit OneDrive uploads.

Sync/Bisync folder mirroring is planned later — this release uses rclone only as the restic cloud backend.

Consumer clouds may throttle large backups — prefer local disk or NAS for primary Disk 1 when possible.

## Mount (browse snapshots)

**Operations** → **Install WinFsp** (if prompted; UAC appears) → **Mount repo** / **Unmount**.
If the repository password is missing, use **Store password** on Operations (or Edit set → Passwords).
Mount is for browsing; use Operations restore actions for permanent recovery.

### Console layout

- **Setup wizard** — configure sets (including schedule and optional dry run at the end).
- **Dashboard** — status cards (restic/rclone/disk), live activity, last-run details, Cloud & Retention modals.
- **Operations** — backup actions, set list (edit/delete), restore.

## Prerequisites

- Windows 10/11 Backup PC
- Source SMB share(s) reachable as UNC (LAN and/or [Tailscale](https://tailscale.com/))
- [restic](https://restic.net/) (wizard can install into `tools\`)
- Optional: rclone (console can install) + WinFsp (console can install) for mount

## Docs

`UserGuide.html`, `RecoveryChecklist.txt`, `technical.md`, UI mockup `ui/mockups/05-dashboard-console.html`
