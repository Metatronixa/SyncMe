# Supported Windows matrix (SyncMe)

| Edition | Versions | Notes |
|---------|----------|--------|
| Windows 10 | 21H2 / 22H2 (x64) | Backup PC and optional Monitor PC |
| Windows 11 | 22H2+ (x64) | Preferred desktop Backup PC |
| Windows Server | 2019, 2022 (x64) | Use a dedicated SyncMe service account; Password logon tasks |

## Runtime

- **PowerShell:** 5.1 (Windows PowerShell). PowerShell 7 is not required and is not the supported host runtime.
- **Architecture:** x64 only.
- **Privileges:** Console binds `127.0.0.1` (no admin for day-to-day UI). Task registration and some prereq installs may need elevation.
- **Network:** Loopback console (`:17845`). Optional Tailscale/LAN for UNC sources. Do not publish SyncMe to the internet.

## Tools installed by SyncMe (optional)

| Tool | Purpose | Install path |
|------|---------|--------------|
| restic | Repository backups | Prerequisites → Install restic (or PATH) |
| rclone | Cloud destinations | Prerequisites → Install rclone + OAuth |
| WinFsp | Not required for restore (Windows has no restic mount UX) | Optional legacy |

## Explicitly unsupported

- Windows 7 / 8.1 / Server 2012 R2
- ARM64 as a first-class Backup PC (may work; not regression-tested)
- Running the SyncMe console as a LAN/internet website
- Non-Windows hosts

## Verification

Release builds run `Tests\Run-SyncMeTests.ps1` on Windows. Operators should still complete `docs/DISASTER-RECOVERY.md` on a spare PC before production cutover.
