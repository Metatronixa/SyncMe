# SyncMe release checklist

Use before tagging / uploading a customer build.

## Pre-build

- [ ] `VERSION.txt` and `Monitor\VERSION.txt` match the intended release
- [ ] `Tools\syncme-update-private.xml` available (or `SYNCME_UPDATE_KEY_XML`) so `latest.json` is signed
- [ ] `Modules\UpdatePublicKey.xml` matches the private key in use
- [ ] No secrets in the tree (`.env`, plaintext passwords, private key not committed)

## Automated

- [ ] `.\Tests\Run-SyncMeTests.ps1` — all green
- [ ] `.\Build-SyncMeSetup.ps1` — succeeds
- [ ] `dist\updates\latest.json` contains `version`, `sha256`, `url`, `signature`
- [ ] `dist\SyncMe-Release-<ver>\SHA256SUMS.txt` present
- [ ] Payload zip has no `website/`, `ui/mockups/`, or bundled `.exe` tools

## Manual smoke (Backup PC or VM)

- [ ] Fresh unzip → `SyncMe-Setup.cmd` → wizard opens on `127.0.0.1:17845`
- [ ] Apply a minimal set (local folder → local repo subfolder)
- [ ] Dry run + real backup; Dashboard shows last success
- [ ] Restore to empty folder; non-empty target rejected
- [ ] Operations → Check for updates (feed reachable / signature OK when official)
- [ ] `GET /api/health` returns structured checks
- [ ] `RescueKit\SyncMe-Rescue.ps1 -Action Diagnostics` writes `Logs\rescue-*`

## Publish

- [ ] Upload `dist\updates\latest.json`, `SyncMe-Setup-<ver>.zip`, optional Monitor zip to https://www.syncme.co.za/updates/
- [ ] Attach `SHA256SUMS.txt` / release notes to GitHub Release if used
- [ ] Update site Downloads copy if separate from feed folder

## Post-release

- [ ] Spot-check in-app update from previous version on a lab PC
- [ ] Confirm Config.ps1 preserved across update
- [ ] File any Phase 4 / 2.1 follow-ups in the product audit tracker
