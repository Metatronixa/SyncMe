# SyncMe release notes

## 1.8.0 — 2.1 restore verification slice

- Fix: host no longer exits after the first API call (PowerShell $true -eq 'shutdown' coercion)

- Restore drill records hash + read evidence (`Logs/sets/<id>/restore-verify-evidence.json`)
- Watchdog alerts when restore-verify evidence is missing or older than `WatchdogVerifyMaxAgeDays` (default 14)
- `/api/health` includes restoreVerification check
- Structured logs: SECRET class never persisted; secret-like fields scrubbed
- `Assert-SyncMeSafePath` rejects reparse points / junction parents

## 1.7.0 — Product completion (audit Phase 4)

- Installer / release packaging: SHA256SUMS, clearer START-HERE, signed update feed retained
- Recovery: expanded checklist, Rescue Kit actions, `docs/DISASTER-RECOVERY.md`
- Support matrix: `docs/SUPPORTED-WINDOWS.md`
- Support policy: `docs/SUPPORT.md`
- Release process: `docs/RELEASE-CHECKLIST.md`
- DR proof helper: `Scripts/Prove-SyncMeDisasterRecovery.ps1`
- Update UI: shows when the feed package is signature-verified

## 1.6.0 — V2 foundation (audit Phase 3)

- Dumb Host + Router / API controllers
- ProcessRunner, JobState, config schema migration (v2)
- Structured logs + `/api/health`

## 1.5.4 — Hardening (audit Phases 1–2)

- Empty restore enforcement, CSRF/Origin, CredWrite, atomic locks
- Monitor token/bind hardening, fleet degraded (restic exit 3)
- HTTPS + RSA-signed update manifests, staged update rollback
- DPAPI scheduled-task elevation handoff, Pester CI

## 1.5.2–1.5.3

- Path/restore guards, Rescue Kit baseline, update previous-release rollback
- CSRF and Monitor/restore Phase 1 items (1.5.3)

Older notes: see git tags and `SYNCME-PRODUCT-AUDIT.md`.
