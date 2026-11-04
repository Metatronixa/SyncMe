# Disaster recovery proof (clean machine)

Goal: prove an operator can rebuild a Backup PC and restore files **without** the original SyncMe UI process.

## Prerequisites (offline vault)

- restic repository password  
- Path to the restic repository (disk / NAS / rclone remote)  
- SyncMe Rescue Kit HTML (optional) + this document  
- A SyncMe setup zip (`SyncMe-Setup-<ver>.zip`) matching or newer than the repo era  

## Lab procedure (spare Windows PC)

1. **Install SyncMe** from the customer zip (`SyncMe-Setup.cmd` → default `C:\SyncMe`).
2. **Do not** invent a new restic password. Store the **existing** password via Operations → Passwords (or Credential Manager target `SyncMeRestic`).
3. **Point a set** at the existing repository path (same path the old Backup PC used). Skip “init” if the repo already exists — SyncMe will use the stored password against the existing repo.
4. **Refresh snapshots** → restore `latest` (or a known good id) to an **empty** folder outside the repo (e.g. `E:\SyncMe-Restore\proof`).
5. **Spot-check** critical files against known good copies / hashes.
6. **Re-register schedule** under the dedicated Windows account (Password logon).
7. **Run** `.\Scripts\Prove-SyncMeDisasterRecovery.ps1 -InstallRoot C:\SyncMe` for automated structure/health checks.
8. **Optional Rescue Kit path:** if an update broke the Host, run  
   `.\RescueKit\SyncMe-Rescue.ps1 -Action RestorePrevious` then `SafeMode`.

## Pass criteria

- [ ] Snapshots list successfully with the vault password  
- [ ] Restore to empty target succeeds  
- [ ] Non-empty / drive-root targets are rejected by SyncMe  
- [ ] Scheduled task exists for the set  
- [ ] Prove script exits 0  

## Fail / escalate

- Password unknown → repository is not recoverable (by design).  
- `restic check` fails → stop prune; copy repo offline; investigate packs.  
- UNC-path snapshots on Windows → restore a newer drive-letter snapshot instead.
