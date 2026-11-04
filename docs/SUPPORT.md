# SyncMe support policy

**Product:** SyncMe (Windows backup orchestration)  
**Site:** https://www.syncme.co.za  
**Contact:** brad@web-zilla.co.za  
**License:** See `LICENSE.txt` (free to use; keep copyright credit).

## What we support

- Install, configure, schedule, backup, restore, and update flows documented in `START-HERE.txt`, `UserGuide.html`, and this repo’s docs.
- Current stable line: version in root `VERSION.txt` / customer `SyncMe-Release-<ver>`.
- Security expectations in `SECURITY.md` and `docs/V2.1-SECURITY.md` §0 (shipped vs remaining).

## What we do not support as a product promise

- Bare-metal imaging, antivirus, or ransomware detection/mitigation.
- SyncMe exposed beyond loopback / reverse-proxied to untrusted networks.
- Recovery without the restic repository password.
- Guaranteeing every open Office/PST file on a live share (restic exit 3 = degraded/partial).

## How to get help

1. `UserGuide.html` and FAQ on https://www.syncme.co.za  
2. `RecoveryChecklist.txt` and `docs/DISASTER-RECOVERY.md`  
3. `RescueKit\SyncMe-Rescue.ps1 -Action Diagnostics` (no secrets in the export)  
4. Email brad@web-zilla.co.za with version (`VERSION.txt`), Windows edition, and `Logs\rescue-*` if generated

## Security reports

See `SECURITY.md`. Prefer clear reproduction that respects the localhost trust model.
