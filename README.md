# SyncMe

**Website:** [www.syncme.co.za](https://www.syncme.co.za)  
**SyncMe** — Copyright © 2026 Bradford Lotriet (`brad@web-zilla.co.za`)

Free to use — keep this credit. See [`LICENSE.txt`](LICENSE.txt).

Simple **file-level** backup from source PCs to a Backup PC using **restic**, managed from an **HTML5 console**. Sources over **LAN and/or Tailscale**. Destinations: **local disk**, **NAS (UNC)**, or **cloud via rclone** (OneDrive / Google Drive OAuth). No PHP. No database.

**Not** bare-metal imaging, antivirus, or ransomware protection — **save the restic password in a password manager**, verify backups and restores, and keep separate recovery copies.

## Documentation & how-to

| Doc | Purpose |
|---|---|
| **[www.syncme.co.za](https://www.syncme.co.za)** | Product site, FAQ, User Guide |
| [`START-HERE.txt`](START-HERE.txt) | First steps after install / unzip |
| [`UserGuide.html`](UserGuide.html) | Full how-to: wizard, sets, restore, verify, Tailscale, troubleshooting |
| [`RecoveryChecklist.txt`](RecoveryChecklist.txt) | Disaster recovery + password vault checklist |
| [`LICENSE.txt`](LICENSE.txt) | Free-to-use terms and liability |
| [`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt) | restic / rclone licenses |

**Quick start**

1. Share source folder(s); ensure UNC reachability (LAN and/or Tailscale).
2. Unzip SyncMe on the **Backup PC** only. Open **`START-HERE.txt`**, then **`SyncMe.bat`**.
3. Complete the wizard (restic can be auto-installed). Pick network mode, folders, destination, schedule.
4. **Save the restic password** in a password manager or other safe place when the wizard creates it (Credential Manager alone is not enough if the Backup PC dies).
5. **Verify** before trusting the schedule: Run dry run → real backup → read Reports/Logs → Operations Check → mount or restore to an empty test folder and spot-check critical paths against the source.
6. Use the dashboard for progress, schedule edits, restore, and **Add backup set**.

**Customer hand-off zip**

```powershell
.\Build-SyncMePackage.ps1
# or minimal setup package:
.\Build-SyncMeSetup.ps1
```

## Technology

| Layer | Tech |
|---|---|
| Host / API | PowerShell 5.1, `HttpListener` on `127.0.0.1:17845` (`SyncMe-Host.ps1`) |
| Backup engine | [restic](https://restic.net/) (encrypted, deduplicated snapshots) via `SyncMe-Backup.ps1` |
| Cloud backend | [rclone](https://rclone.org/) as restic remote only (OAuth for OneDrive / Google Drive) |
| Schedule | Windows Task Scheduler (+ SyncMe-Watchdog) |
| UI | Static HTML5 + CSS + vanilla JavaScript (`ui/`), Source Sans 3 |
| Config / secrets | `Config.ps1` (no database); Windows Credential Manager; `Config\rclone.conf` |
| Optional | [Tailscale](https://tailscale.com/) (offsite SMB), WinFsp (restic mount), OfficeAgent (VSS on source) |
| Platform | Windows 10/11 or Windows Server (Backup PC) |

SyncMe is an **orchestration frontend** — not a replacement for restic or rclone. Third-party notices: [`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt).

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

**Restic password:** encrypts the repository. Without it there is no restore, mount, or recovery. Keep a copy in a password manager or other safe place — do not put it in `Config.ps1`.

## Verify backups and restores

1. After Apply, **Run dry run**, then a real backup.
2. Open **Reports** / **Logs** (restic exit **3** = some files unread — often locked Office files).
3. Operations **Check** (structural + weekly data subset) for repository health.
4. **Mount** a snapshot and spot-check key folders next to the live share; or restore into an **empty test folder** and compare critical paths to the source.

## Destinations

- **restic repository** (required per set): full path on *this* Backup PC, NAS UNC, or `rclone:remote:path`.
- Use **Add backup set** for another source PC / schedule / destination.
- Config defaults ship empty so you can run SyncMe on any server without baked-in drive letters.

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
3. Pick remote + folder path → **Save cloud dest**. Destination becomes `rclone:remote:path`.
4. After setup apply, use **Run dry run** to verify before relying on the schedule.
5. Set bandwidth (e.g. `2M`) and retries to limit OneDrive uploads.

Sync/Bisync folder mirroring is planned later — this release uses rclone only as the restic cloud backend.

Consumer clouds may throttle large backups — prefer local disk or NAS for the primary repository when possible.

## Mount (browse snapshots)

**Operations** → **Install WinFsp** (if prompted; UAC appears) → **Mount repo** / **Unmount**.
If the repository password is missing, use **Store password** on Operations (or Edit set → Passwords).
Mount is for browsing; use Operations restore actions for permanent recovery.

### Console layout

- **Setup wizard** — configure sets (including schedule and optional dry run at the end).
- **Dashboard** — status cards (restic/rclone/disk), live activity, last-run details, Cloud & Retention modals.
- **Operations** — backup actions, set list (edit/delete), restore.

## Prerequisites

- Windows 10/11 or Windows Server Backup PC
- Source SMB share(s) reachable as UNC (LAN and/or [Tailscale](https://tailscale.com/))
- [restic](https://restic.net/) (wizard can install into `tools\`)
- Optional: rclone (console can install) + WinFsp (console can install) for mount

## Links

- Product site: [www.syncme.co.za](https://www.syncme.co.za)
- Contact: brad@web-zilla.co.za
