# SyncMe OfficeAgent (source PC)

Run these scripts **elevated on the source / office PC**, not on the Backup PC.

## Setup

```powershell
cd OfficeAgent
.\Enable-SyncMeShadowCopies.ps1
```

Creates shadow storage, a daily `SyncMe-OfficeShadowPointer` task, and writes
`.syncme-latest-shadow.txt` under the share root (legacy `.monarch-latest-shadow.txt`
is still read by the Backup PC if present).

## Scripts

| Script | Role |
|--------|------|
| `Enable-SyncMeShadowCopies.ps1` | Shadow storage + daily SYSTEM task + first pointer |
| `Update-SyncMeShadowPointer.ps1` | Create shadow + write `.syncme-latest-shadow.txt` |
| `Enable-MonarchShadowCopies.ps1` | Compatibility stub → SyncMe script |
| `Update-MonarchShadowPointer.ps1` | Compatibility stub → SyncMe script |

Also enable **Shadow Copies for Shared Folders** in the Windows GUI on the volume
so the Backup PC can open `\\server\share\@GMT-...` over SMB.

Schedule SyncMe backups on the Backup PC **after** the office pointer task time.
