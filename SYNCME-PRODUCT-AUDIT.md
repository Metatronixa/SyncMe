# SyncMe Product & Source-Code Audit

**Repository:** `Metatronixa/SyncMe`  
**Branch:** `main`  
**Audited commit:** `dd87fc16c03148ab8db71468d272ca82d4b2584b`  
**Version declared by `VERSION.txt`:** `1.5.0`  
**Audit type:** Read-only source and documentation review  
**Date:** 3 November 2026

> This is a source-code audit, not a runtime penetration test or a production-readiness certification. I inspected the repository at the commit above. I did not execute the product on Windows, run restic/rclone against a live repository, install the package, or modify the GitHub repository. Findings that depend on Windows, browser, SMB, Task Scheduler, or restic behaviour are explicitly marked for validation.

---

## 1. Executive assessment

SyncMe is a substantial Windows-first backup orchestration product, not a small proof of concept. It has a working product shape: multi-set configuration, restic backup orchestration, restore and snapshot browsing, Task Scheduler integration, Credential Manager integration, cloud repositories through rclone, source-side VSS support, reports, recovery tooling, update packaging, and optional fleet integrations.

The central product decision is sound: **SyncMe should remain a Windows-native, recovery-first orchestration layer around restic and rclone**, rather than trying to become another general-purpose backup engine or clone a container-oriented product.

The biggest risks are not missing features. They are a handful of trust-boundary, recovery-safety, update-integrity, and operational-state issues that should be closed before describing SyncMe as production-ready for customers.

### Overall assessment

| Area | Assessment | Summary |
|---|---|---|
| Product scope | Good | Clear Windows-first product identity and documented non-goals |
| Core architecture | Good foundation; needs modularisation | Host and engine scripts are large, but shared modules already exist |
| Backup workflow | Promising; needs runtime proof | Thoughtful restic pipeline, progress handling, exit-code recovery and integrity checks |
| Restore safety | Needs correction | Backend detects non-empty targets but does not enforce emptiness |
| Security | Needs hardening | Local API trust boundary is documented, but CSRF protections are absent; Monitor ships with a usable placeholder token |
| Updates | Needs hardening | SHA-256 is checked, but publisher authenticity and rollback are not established |
| Installer/deployment | Good foundation | Config preservation and package-content checks are present |
| Monitoring | Useful, but status semantics need work | Partial backups can appear healthy in the Monitor |
| Testing/release process | Major gap | No automated test suite or CI workflow was present in the inspected repository tree |

### Recommended release strategy

Do not begin with a full V2 rewrite. First stabilise and harden the 1.5.x code, add repeatable Windows test coverage, and then refactor the host/engine incrementally while preserving the current UI and customer configuration.

---

## 2. Scope, evidence and limitations

### Files and components reviewed

- `README.md`, `TECHNICAL.md`, `SECURITY.md`, `V2.md`, `UserGuide.html`, `START-HERE.txt`, `RecoveryChecklist.txt`
- `SyncMe-Host.ps1`, `SyncMe-Backup.ps1`, `SyncMe-Restore.ps1`, `SyncMe-Watchdog.ps1`
- `Modules/Common.ps1`, `Sets.ps1`, `Notify.ps1`, `Restore.ps1`, `Update.ps1`, `InstallMerge.ps1`, `MonitorClient.ps1`, `LocalOpsClient.ps1`
- `Register-BackupTask.ps1`, `Build-SyncMeSetup.ps1`, `Build-SyncMePackage.ps1`, `Deploy-SyncMe.ps1`
- `Monitor/SyncMe-Monitor-Host.ps1`, Monitor UI and default config
- OfficeAgent setup and shadow-pointer scripts
- Repository tree, declared version and current `main` commit

### Not verified at runtime

The following still require a real Windows test environment:

- PowerShell 5.1 behaviour on supported Windows 10/11 and Windows Server builds
- Browser-origin / CSRF behaviour against the localhost `HttpListener`
- Task Scheduler registration and unattended execution under the intended service account
- Credential Manager access under the scheduled-task identity
- SMB/Tailscale interruptions and reconnects
- VSS creation, client-accessible shadow paths and retention behaviour
- Restic exit-code and restore semantics for representative repositories
- Update interruption, rollback and recovery
- Installer upgrades over real customer installations
- Cancellation of restic/rclone child processes

A source review can identify unsafe or incomplete logic; it cannot prove the product works reliably on every supported Windows configuration.

---

## 3. Product and feature inventory

### Core product capabilities found

1. **Backup sets:** multiple configured sets, each with source paths, destination, schedule, retention and related options.
2. **Sources:** local paths and UNC shares, with LAN/Tailscale network modes.
3. **Destinations:** local folders, NAS/UNC paths and cloud-backed restic repositories through rclone.
4. **Backup engine:** restic snapshots, JSON progress parsing, retention/prune, repository checks and reports.
5. **Source preparation:** optional SMB credential mapping, Wake-on-LAN and OfficeAgent shadow-copy pointer resolution.
6. **Scheduling:** Windows Task Scheduler with once/daily/weekly schedules and optional watchdog.
7. **Recovery:** snapshot listing, lazy folder browsing, selected/latest restore, include-path restore, Rescue Kit and migration package.
8. **Integrity:** structural `restic check`, weekly `--read-data-subset`, and a sampled restore drill.
9. **Notifications:** optional SMTP/email and toast notifications.
10. **Fleet integrations:** optional SyncMe Monitor heartbeat and LocalOps Console registration.
11. **Updates:** HTTPS feed lookup, package download and SHA-256 comparison, then in-place merge update.
12. **Packaging:** customer setup package, full package, Monitor package and technician deployment script.

### Deliberate product boundaries

The documentation is clear that SyncMe is not:

- Bare-metal imaging
- Antivirus or a ransomware protection product
- A replacement for restic or rclone
- A LAN-facing multi-user backup server
- A cloud-hosted multi-tenant SaaS
- A Linux or Docker product
- An rclone bisync/folder-mirroring product
- A Windows restic mount/FUSE drive browser

Keep these boundaries. They protect the product from uncontrolled scope growth.

### Competitive direction

SyncMe should differentiate through Windows-native orchestration and recovery, rather than trying to match every generic source/destination or multi-tenant capability in other products. Its best differentiators are Task Scheduler, Windows Credential Manager, UNC/Tailscale workflows, VSS-assisted source capture, Rescue Kit, restore drills, and a guided Windows recovery experience.

---

## 4. Findings: prioritised defects and risks

Severity is based on potential impact and how directly the source supports the finding:

- **P1 – High:** fix before broad customer deployment or before claiming production-ready recovery/security.
- **P2 – Medium:** address in the next hardening release.
- **P3 – Low:** improve as part of maintainability, usability or documentation work.

### P1 — Restore target emptiness is detected but not enforced

**Evidence:** `Modules/Restore.ps1`, `Test-SyncMeRestoreTargetSafe()` and `Invoke-SyncMeRestore()`; `SyncMe-Host.ps1`, `Start-SyncMeRestoreJob()`.

The safety function calculates and returns `NonEmpty`, but the caller checks only `Ok`. The host also checks only `Ok` before starting the detached restore. The restore runner then creates the target if it does not exist and invokes `restic restore`.

The product guide tells operators to restore into an empty folder, but the backend does not enforce that rule. A direct API call or operator mistake can therefore restore into an existing populated directory. Depending on restic's overwrite behaviour and file collisions, this can overwrite existing files or create a mixed recovery tree.

**Required correction:**
- Reject non-empty targets by default in the backend, not just in the UI.
- If an overwrite/merge mode is ever supported, make it a separate explicit operation with a strong confirmation.
- Reject drive roots and other unsafe generic targets.
- Prevent restoring into configured source paths, the repository, the archive target, or SyncMe's own install/data directories unless a carefully defined exception exists.
- Repeat all checks in the detached restore runner immediately before invoking restic to reduce time-of-check/time-of-use risk.

**Acceptance test:** an existing target containing sentinel files must be rejected and left byte-for-byte unchanged.

### P1 — Monitor accepts the shipped placeholder token

**Evidence:** `Monitor/Config/Monitor.json`; `Monitor/SyncMe-Monitor-Host.ps1`, `Test-MonitorAuth()` and listener startup.

The committed default Monitor config uses `Token: "change-me"`. The authentication function rejects an empty token, but it does not reject the literal placeholder. A Monitor started without changing the default therefore accepts the known token for heartbeat ingestion.

The Monitor first attempts to bind to `http://+:<port>/`, which exposes it on network interfaces if the HTTP URL reservation permits it. It falls back to loopback only if the wildcard bind fails. The source prints a warning that the token is still default, but does not prevent startup.

**Required correction:**
- Generate a cryptographically random token on first start, or refuse to start until the placeholder is replaced.
- Do not treat a console warning as an adequate security control.
- Require a sufficiently long token and compare it safely.
- Document the network exposure and firewall requirements prominently.
- Consider binding loopback by default and requiring an explicit network-exposure setting.
- Keep the read-only dashboard's unauthenticated status endpoint only if the operator knowingly accepts that it exposes hostnames, site/set names, versions, last-run times, summaries and snapshot identifiers.

**Acceptance test:** the Monitor must refuse heartbeat ingestion when configured with `change-me`, an empty token, or a token below the defined minimum strength.

### P1 — Core localhost API has no CSRF/origin defence

**Evidence:** `SyncMe-Host.ps1`, `Read-SyncMeBody()` and the main `HttpListener` request loop/API handlers; `SECURITY.md` describes the localhost trust model.

The host binds to `127.0.0.1`, which is a useful boundary, and the security policy correctly says not to expose it through a reverse proxy. However, the API accepts state-changing POST requests without validating `Origin`/`Host`, requiring a CSRF token, or applying another browser-request defence. The body reader parses JSON but does not require a JSON content type.

This creates a **potential browser-based CSRF path** from a malicious website visited in a browser on the Backup PC. Modern browser loopback/private-network protections may affect exploitability, so this is a source-level risk that needs a controlled browser test rather than a claim of a confirmed exploit.

The affected actions are powerful: configuration changes, credential writes, backup/restore operations, snapshot deletion, update installation, migration import, and shutdown.

**Required correction:**
- Validate the request host and expected origin for all state-changing endpoints.
- Add a per-session CSRF token or an equivalent browser-safe defence.
- Require `application/json` for JSON API requests and reject unexpected content types.
- Add request-size limits and method allow-lists.
- Keep the host loopback-only; do not solve this by exposing it to the LAN.

**Acceptance test:** a page hosted on a separate origin must not be able to trigger any state-changing SyncMe API operation.

### P2 — Backup lock acquisition is a check-then-write race

**Evidence:** `SyncMe-Backup.ps1`, `Enter-BackupRunLock()`.

The lock algorithm checks whether a file exists, reads its PID/timestamp, removes it if stale, and then writes a new file. The create operation is not atomic/exclusive. Two simultaneous launches can both observe no lock and both write one. Restic's own repository lock is a secondary defence, but it does not replace correct SyncMe job coordination or protect all progress/report state.

The stale-lock logic also removes a lock when its age exceeds the configured threshold even if the recorded PID is still alive. The default threshold is 36 hours. A legitimately long-running backup can therefore have its lock removed and permit another SyncMe run to start.

**Required correction:**
- Acquire locks using an exclusive file create (`CreateNew`/exclusive handle) or a named mutex with a documented cross-session strategy.
- Record process start time and verify PID plus process identity, not PID alone.
- Never remove a lock solely because a live process has exceeded an age threshold.
- Add a deliberate stale-lock recovery command that checks process/repository state and logs the operator decision.

### P2 — `cmdkey` exposes the repository password as a process argument

**Evidence:** `SyncMe-Host.ps1`, `Set-CmdKeyGeneric()` and `Set-SyncMeResticPassword()`.

The password is passed to `cmdkey` as `/pass:<password>`. Process command lines can be visible to sufficiently privileged local inspection tools and may be captured by endpoint monitoring or diagnostic software. The exposure window is short, but this is avoidable.

**Required correction:** use the Windows Credential Manager API (CredWrite) through a small, well-contained PowerShell/.NET interop helper rather than placing the secret in a child process command line. Do not replace it with plaintext config or a persistent plaintext file.

### P2 — Scheduled-task elevation uses a temporary plaintext password file

**Evidence:** `Register-BackupTask.ps1`, elevation path near the beginning of the script.

When elevation is needed, the script writes the Windows account password to a temporary file, attempts to restrict the ACL, and silently continues if ACL protection fails. It later deletes the file, but a crash, forced termination or failed cleanup can leave it behind.

**Required correction:**
- Prefer a secure credential handoff that avoids a plaintext temporary file.
- If a temporary file remains unavoidable, fail closed if ACL restriction fails, use a protected directory, minimise lifetime, and guarantee cleanup through a robust recovery path.
- Avoid passing secrets through command-line arguments.
- Test interrupted elevation and process termination.

### P2 — Update integrity is checksum-only, with no rollback of application files

**Evidence:** `Modules/Update.ps1`, `Get-SyncMeUpdateInfo()` and `Start-SyncMeUpdateApply()`.

The updater downloads a package and compares its SHA-256 to the value supplied by the update feed. This detects corruption or an inconsistent download, but it does not independently authenticate the publisher. If the feed or its hosting account is compromised, an attacker could replace both the package and the checksum.

The apply script backs up `Config.ps1`, then merges new application files over the live installation. If an error occurs after some files have been copied, the catch block logs the error but does not restore the previous application tree. This is not a transactional update with rollback.

The code also does not enforce that the feed and package URLs use HTTPS, even though the documented default is HTTPS.

**Required correction:**
- Enforce HTTPS for feed and package URLs.
- Sign release manifests or packages with a publisher-controlled signing key and verify the signature locally. SHA-256 should remain as an additional integrity check.
- Stage the full update separately, validate required files and version, then switch to it.
- Keep a versioned previous application tree and implement tested rollback.
- Record update state so an interrupted update can be resumed or rolled back safely.
- Test preservation of `Config.ps1`, `Config/rclone.conf`, per-set JSON, Credential Manager entries and customer logs.

### P2 — Partial backup status can appear healthy in fleet monitoring

**Evidence:** `SyncMe-Backup.ps1` exit-code handling; `Modules/MonitorClient.ps1`; `Monitor/ui/js/app.js`, `classify()`.

The backup engine intentionally treats restic exit code `3` as a usable but incomplete snapshot and records a warning/skipped-files state. The main SyncMe console has a persistent skipped-files banner, which is good.

However, the heartbeat sends `success = RunInfo.Success`, and the Monitor classifies records primarily from `success` and `phase`. It does not interpret exit code `3` or a summary containing `EXIT3` as a degraded state. A partial backup can therefore appear as `OK` in the fleet dashboard even though files were skipped.

**Required correction:**
- Introduce a distinct outcome model: `success`, `degraded/partial`, `failed`, `running`, `stale`.
- Send an explicit severity/status field in the heartbeat.
- Make the Monitor show exit-code-3 runs as degraded, not healthy.
- Ensure watchdog and last-success policy clearly distinguish a complete backup from a partial snapshot.

### P2 — Monitor static-file path containment is weaker than the core host

**Evidence:** `Monitor/SyncMe-Monitor-Host.ps1`, `Send-Static()`.

The main host canonicalises the requested static path and checks that it remains beneath the UI root. The Monitor handler joins the requested relative path to its UI root and checks whether it exists, but does not perform an equivalent canonical full-path containment check.

This is a path-traversal risk that should be tested against the actual `HttpListener` path normalisation and URL-encoding behaviour. It is not reported here as a confirmed arbitrary-file disclosure.

**Required correction:** canonicalise both root and target, verify the target remains inside the root using a separator-aware comparison, reject encoded traversal and alternate path forms, and serve only a fixed asset allow-list if practical.

### P2 — Monitor token in query strings

**Evidence:** `Monitor/SyncMe-Monitor-Host.ps1`, `Test-MonitorAuth()`.

Heartbeat authentication accepts both a Bearer header and a `?token=` query parameter. Query-string credentials are more likely to appear in browser history, proxy logs, diagnostics and copied URLs.

**Required correction:** remove query-string token authentication and require the Authorization header. Rotate existing Monitor tokens when this change ships.

### P2 — Restore and backup operations need stronger shared-resource coordination

**Evidence:** `SyncMe-Host.ps1`, backup/restore job functions; `Modules/Restore.ps1`; per-set lock handling in `SyncMe-Backup.ps1`.

The UI tracks one active restore process globally, while backup locks are per set. The code blocks a restore when the selected set's backup is running, but the model does not establish a global repository/job coordinator. Two sets can be configured to use the same repository path, and there is no clear validation preventing that configuration.

Restic's own repository lock helps prevent concurrent repository writers, but SyncMe should detect repository collisions itself and report a clear error before launching jobs.

**Required correction:**
- Validate that each active backup set maps to a unique repository path unless shared-repository operation is explicitly supported.
- Coordinate backup, restore, prune, snapshot deletion and repository checks by canonical repository identity.
- Make job state per job, with explicit repository ownership and cancellation state.

### P2 — No automated tests or CI workflow were present

**Evidence:** inspected recursive repository tree at the audited commit; no test/spec/Pester directory or `.github/workflows` files were found.

For a backup product, this is a material release risk. The most important behaviour is destructive or difficult to reproduce manually: pruning, restore path validation, update merge, credential access, scheduling, lock recovery and interrupted operations.

**Required correction:**
- Add Pester tests for pure PowerShell functions and validation logic.
- Add static checks for PowerShell 5.1 syntax and forbidden encoding/BOM regressions in `.bat`/`.cmd`.
- Add package-content tests and manifest/version consistency checks.
- Add a Windows integration test matrix with disposable source/repository/restore directories.
- Add a release checklist with a signed artifact, SHA-256, upgrade test and restore proof.

### P3 — Main host is a large synchronous request router

**Evidence:** `SyncMe-Host.ps1`, main listener loop and API handlers.

The host performs request handling sequentially in one loop. Many operations are short or launch detached processes, but snapshot listing, browse calls and some configuration or setup work can be synchronous. A slow restic/rclone call can delay other API requests and UI polling.

**Recommendation:** preserve the lightweight PowerShell host, but extract route handlers/controllers and move potentially long repository operations into tracked background jobs. A full service conversion is not required to solve this.

### P3 — Request body and input validation should be standardised

**Evidence:** `Read-SyncMeBody()` and multiple API handlers.

The common body reader reads the full request body without an explicit size limit or content-type validation. Validation is inconsistent between endpoints because each handler performs its own casts and checks.

**Recommendation:** add a common request-validation layer with body-size limits, required-field validation, string-length limits, enumerated values, path validation and consistent HTTP status responses.

### P3 — Documentation and version support statements drift

**Evidence:** `VERSION.txt` declares 1.5.0; `V2.md` still names 1.4.2 as the supported legacy release; `SECURITY.md` includes historical references to earlier versions.

**Recommendation:** establish one release metadata source and update the README, SECURITY, V2, User Guide, release notes and package manifests together. Clearly state which release lines receive security fixes.

---

## 5. Backup-engine review

### Strengths

- Restic is invoked as an external, established backup engine rather than reimplemented.
- Passwords are loaded from Windows Credential Manager and placed in process environment variables only for the job.
- The engine parses restic JSON progress and streams logs/JSONL rather than buffering the entire backup output.
- It handles restic exit code `3` as a partial backup rather than silently treating it as a complete run.
- It attempts to recover a missing summary from JSONL and snapshot state before deciding success.
- It supports optional source reachability checks, SMB mapping, Tailscale checks, VSS pointer resolution and UNC-to-drive-letter rewriting.
- Retention/prune is conditional on a successful backup and respects the SyncMe append-only policy.
- Structural checks and weekly data-subset checks are integrated.
- The restore drill samples files from a recent snapshot and verifies data through `restic dump`.
- Reports, last-run state and heartbeat data are written separately.

### Areas to test

1. Source share disappears after preflight but during backup.
2. One source folder is unavailable while other configured folders remain available.
3. Tailscale is connected at start and drops mid-run.
4. SMB credentials expire or the scheduled task runs under the wrong account.
5. Restic exits `3`, with and without a summary object.
6. Restic process is killed during backup, prune, check and archive.
7. Disk fills during backup, prune, report generation and archive.
8. Repository lock is stale, active, or belongs to another restic process.
9. The same repository path is assigned to two sets.
10. VSS pointer is missing, stale, malformed or points to an inaccessible shadow.
11. A restore drill fails while the main backup succeeded.
12. Notification and Monitor failures occur after a valid snapshot was created.

### Exit code 3 policy

The current approach is understandable: a snapshot may still be useful when some files are unreadable. However, the product should present it as **partial/degraded**, not indistinguishably as success. Keep the snapshot, surface skipped files, and make fleet health reflect the degraded result.

---

## 6. Restore and disaster-recovery review

Restore is the most important workflow in a backup product. SyncMe already has useful recovery features: snapshot selection, lazy browse, include-path restore, a separate restore process, restore status, cancellation, Rescue Kit and an optional sampled restore drill.

The main correction is to make restore safety enforceable in the backend.

### Required restore safeguards

- Empty target enforced by default.
- No drive-root target.
- No target inside the live repository.
- No target that resolves to the source path or a protected SyncMe path.
- Canonical path resolution, including UNC and reparse-point/symlink considerations.
- Clear warning and explicit opt-in for any future merge/overwrite restore mode.
- Verify the target before and after restore; report files restored and errors.
- Cancellation test must confirm restic and its child processes are actually stopped.
- A failed or interrupted restore must leave a clear status record and must not be mistaken for a successful recovery.

### Disaster-recovery test

Perform a full recovery exercise on a clean Windows machine:

1. Install SyncMe from the released customer package.
2. Restore the repository credentials from the offline vault.
3. Configure access to the repository.
4. Run repository check.
5. Browse a snapshot.
6. Restore a representative directory and a representative large file to an empty alternate location.
7. Compare hashes and ACL/metadata expectations where supported.
8. Repeat with cloud-backed repository access.
9. Record elapsed time, operator steps, missing prerequisites and documentation gaps.

Do not call a backup product production-ready until this exercise is repeatable.

---

## 7. Security and trust-boundary review

### Positive controls already present

- Main console binds to `127.0.0.1`.
- Security policy clearly prohibits exposing the core host through a reverse proxy without an additional security layer.
- Core secrets are not intentionally stored in `Config.ps1`.
- SMTP uses TLS 1.2 with certificate validation; the code does not disable certificate validation.
- LocalOps integration restricts the configured URL to loopback.
- Main static-file serving performs canonical path containment.
- Customer package build excludes marketing website content, UI mockups and third-party installer binaries.
- Rescue Kit is designed not to contain the repository password.
- Monitor heartbeat uses a Bearer header when configured.

### Required security work

1. Fix CSRF/origin protections on the core host.
2. Remove `cmdkey` command-line secret exposure.
3. Harden scheduled-task password elevation.
4. Enforce Monitor token generation/rotation and remove query-string authentication.
5. Fix Monitor static path containment.
6. Enforce HTTPS and signed update authenticity.
7. Standardise input validation and request-size limits.
8. Review log/report/rescue/migration contents for secrets and sensitive paths.
9. Define a least-privilege Windows account model and test it on Windows Server.
10. Add an explicit security review to every release.

### Monitor exposure model

The Monitor is different from the core console: it intentionally attempts a wildcard listener so other machines can view the fleet dashboard. Its `/api/sites` endpoint is unauthenticated and reveals operational metadata. This can be acceptable on a tightly controlled management LAN or tailnet, but it should be an explicit deployment decision with firewall rules, strong heartbeat authentication and clear disclosure of the data exposed.

---

## 8. Architecture and maintainability

### Current architecture

- PowerShell 5.1 `HttpListener` host on loopback.
- Static HTML/CSS/vanilla JavaScript UI.
- Main host routes API requests and starts detached backup/restore PowerShell processes.
- Backup engine invokes restic; rclone is configured as a restic backend.
- Task Scheduler starts the backup engine independently of the UI host.
- File-based config, per-set JSON, locks, logs, reports and status files.
- Windows Credential Manager for restic, SMB and SMTP credentials.
- Optional Monitor and LocalOps clients.

### What is already good

- No unnecessary PHP, IIS, Node or front-end framework dependency.
- No database requirement for the current product scale.
- Backup work can continue after the UI closes.
- The code is already partly separated into shared modules.
- Configuration migration and legacy single-set compatibility have been considered.
- The UI design is established and should be preserved.

### What should evolve

- Split `SyncMe-Host.ps1` into router, request validation and controllers.
- Split backup orchestration into clear stages with a shared job context.
- Introduce a common process runner for restic/rclone with consistent quoting, environment handling, cancellation, exit code and output capture.
- Replace PID/timestamp lock files with atomic ownership.
- Use a versioned configuration schema and explicit migrations.
- Define one job-state contract for backup, restore, prune, check and update.
- Make repository identity a first-class object shared by all operations.
- Keep Monitor optional and separate; LocalOps can become the fleet view after a proven dual-write/cutover period.
- Keep the current dark slate + cyan UI and migrate its data/API contracts rather than redesigning it.

### Database decision

The current file-based design is reasonable for a single Backup PC and modest fleet integration. Do not add SQLite merely for architectural appearance. Revisit a database only if measured requirements demonstrate transactional multi-user scheduling, concurrent queue processing, query-heavy fleet history or durable job orchestration that JSON files cannot handle safely.

---

## 9. Installer, update and release review

### Existing strengths

- Customer package has an explicit include list.
- `website/` and UI mockups are excluded.
- Tool installers/binaries are not bundled.
- Package contents are inspected after ZIP creation.
- Setup preserves existing `Config.ps1`.
- `InstallMerge.ps1` uses robocopy and handles nested-folder cleanup.
- Technician deployment preserves the main config and per-set JSON.
- Update manifest includes version, file, URL, notes and SHA-256.

### Gaps to close

- No signed package or signed manifest verification.
- Update application is in-place and does not roll back application files.
- Build-time checks are not a substitute for a clean-install and upgrade test.
- Version and documentation support statements can drift.
- Release artifacts need a repeatable Windows build and smoke-test process.
- A failed update must leave the previous working product available.

### Minimum release gate

A release should not ship unless it passes:

1. Clean install on supported Windows versions.
2. Upgrade from the previous supported version.
3. Preservation of configuration, OAuth config, credentials and logs.
4. Backup to local repository.
5. Backup to UNC/NAS repository.
6. Backup to rclone-backed cloud repository.
7. Restore to an alternate empty directory.
8. Repository check and data-subset check.
9. Interrupted backup and stale-lock recovery.
10. Update interruption and rollback.
11. Package-content and version consistency checks.
12. Recovery documentation review.

---

## 10. Test plan to create

### Unit / static tests

- PowerShell 5.1 parser checks for all `.ps1` files.
- No BOM and ASCII-only requirements for `.bat`/`.cmd` files.
- Configuration schema/default migration tests.
- Set ID, path, retention and schedule validation.
- Canonical path containment tests.
- Restore target safety tests.
- Monitor token and site ID validation tests.
- Update manifest URL/version/hash validation tests.
- Package allow-list/deny-list tests.
- HTML report and UI escaping tests.

### Windows integration tests

| Test ID | Scenario | Expected result |
|---|---|---|
| BAK-01 | First local backup | Snapshot created, report and last-run state correct |
| BAK-02 | Incremental backup with unchanged files | No unnecessary duplicate data; summary correct |
| BAK-03 | One source path unavailable | Job fails or is clearly degraded according to explicit policy; never silently healthy |
| BAK-04 | SMB credentials unavailable | Clear failure; no misleading success |
| BAK-05 | Tailscale unavailable in required mode | Backup fails before claiming success |
| BAK-06 | Restic exit 3 | Snapshot retained; degraded state visible in UI and Monitor |
| BAK-07 | Concurrent same-set starts | Exactly one SyncMe job owns the set |
| BAK-08 | Concurrent sets sharing one repo | Configuration rejected or safely serialised |
| BAK-09 | Process killed during backup | Lock recovery safe; no false success |
| BAK-10 | Prune failure | Job reports failure and retains diagnostic evidence |
| RST-01 | Restore to new empty folder | Restore succeeds and files verify |
| RST-02 | Restore to non-empty folder | Rejected by default |
| RST-03 | Restore to drive root | Rejected |
| RST-04 | Restore into repo/source/install path | Rejected |
| RST-05 | Cancel restore | Restic and child processes stop; status is accurate |
| RST-06 | Restore legacy UNC snapshot | Clear documented limitation |
| SEC-01 | Cross-origin POST to localhost API | Rejected |
| SEC-02 | Monitor default token | Startup or authentication rejected |
| SEC-03 | Monitor traversal paths | No file outside UI root can be read |
| UPD-01 | Valid signed update | Installs and restarts cleanly |
| UPD-02 | Invalid signature/hash | Update rejected |
| UPD-03 | Interrupted update | Previous version restored or remains runnable |
| UPD-04 | Config and OAuth preservation | All customer settings remain intact |
| PKG-01 | Clean setup package | Only intended customer files included |
| PKG-02 | Upgrade over prior install | No nested directories or lost customer data |

---

## 11. Recommended roadmap

### Phase 0 — Freeze and baseline

- Tag the audited source commit.
- Build a clean 1.5.0 package from that commit.
- Capture a test repository and sample source data.
- Record the current supported Windows and PowerShell matrix.
- Do not introduce a broad refactor during this phase.

**Exit:** repeatable baseline install, backup, check and restore.

### Phase 1 — Critical hardening

1. Enforce safe restore targets. **Done in 1.5.3**
2. Fix Monitor placeholder token handling and deployment defaults. **Done in 1.5.3**
3. Add core localhost API CSRF/origin protection. **Done in 1.5.3**
4. Replace non-atomic lock handling. **Done in 1.5.3**
5. Remove command-line credential exposure. **Done in 1.5.3** (CredWrite)
6. Harden scheduled-task password handoff. **Done in 1.5.4** (DPAPI elev handoff, fail-closed ACL)
7. Correct degraded/partial fleet status. **Done in 1.5.3**

**Exit:** P1 issues closed and regression tests passing. **Met in 1.5.4** (`Tests/` + GitHub Actions Pester workflow).

### Phase 2 — Reliability and update hardening

1. Add atomic job/repository coordination. **Done in 1.5.4** (`Modules/Jobs.ps1`)
2. Enforce HTTPS and signed update verification. **Done in 1.5.4** (RSA manifest signature + HTTPS URL assert)
3. Stage updates and implement rollback. **Done in 1.5.4** (stage validate, `update-state.json`, merge-error rollback)
4. Add request validation and size limits. **Done in 1.5.4** (method/query/path limits + prior CSRF/CT)
5. Fix Monitor static path containment and token transport. **Done in 1.5.3**
6. Add Pester/static tests and Windows integration tests. **Done in 1.5.4** (unit/security Pester; full Windows integration still expandable)
7. Align version and support documentation. **Done in 1.5.4**

**Exit:** repeatable clean install, upgrade, backup, restore and rollback. **Code exit met in 1.5.4**; operators should still run a clean-machine DR smoke before calling Phase 2 “customer-proven.”

### Phase 3 — Incremental V2 foundation

Only after the product is stable:

- Router/request/response separation. **Done in 1.6.0** (`Modules/Router.ps1`, `Modules/Http.ps1`)
- Controllers for setup, backup, restore, snapshots, schedules and updates. **Done in 1.6.0** (`Modules/Controllers/ApiDispatch.ps1` + route registration)
- Shared ProcessRunner. **Done in 1.6.0** (`Modules/ProcessRunner.ps1`)
- Shared JobState/RepositoryLock services. **Done in 1.6.0** (`Modules/Jobs.ps1` JobState + repo idle/lock surface)
- Versioned configuration migration. **Done in 1.6.0** (`Modules/ConfigMigrate.ps1`, schema v2)
- Structured logs and health probes. **Done in 1.6.0** (`Modules/Logging.ps1`, `Modules/Health.ps1`, `/api/health`)
- Preserve Task Scheduler support and current UI. **Preserved**

Do not add a database, service wrapper, broad fleet platform or additional backup providers unless a tested requirement justifies them.

**Exit (1.6.0):** Host is a thin listener; API is dispatched through Router + controllers; foundation modules ship with Pester coverage.

### Phase 4 — Product completion

- Finalise installer and update UX. **Done in 1.7.0**
- Finalise recovery documentation and Rescue Kit. **Done in 1.7.0**
- Signed releases and checksums. **Done in 1.7.0** (`SHA256SUMS.txt` + signed `latest.json`)
- Supported Windows matrix. **Done in 1.7.0** (`docs/SUPPORTED-WINDOWS.md`)
- Regression suite and release checklist. **Done in 1.7.0** (`docs/RELEASE-CHECKLIST.md` + Pester)
- Public release notes and support policy. **Done in 1.7.0** (`RELEASE-NOTES.md`, `docs/SUPPORT.md`)
- Prove disaster recovery on a clean machine. **Done in 1.7.0** (`docs/DISASTER-RECOVERY.md`, `Scripts/Prove-SyncMeDisasterRecovery.ps1`)

**Exit (1.7.0):** customer release folder includes checksums, notes, checklist; operator can follow DR docs and run the prove script.

---

## 12. Final recommendation

**Finish SyncMe as a reliable Windows backup and recovery product before expanding its architecture.**

The current codebase already contains a meaningful amount of functionality. A rewrite would introduce risk without first solving the product's most important gaps.

The order matters:

1. Make restore difficult to misuse.
2. Make backup state truthful, especially partial backups.
3. Harden local API, credentials and Monitor trust boundaries.
4. Make updates recoverable.
5. Add automated Windows testing.
6. Refactor incrementally without changing the established UI or customer configuration.

The measure of completion is not the number of modules or version number. It is whether an operator can install SyncMe, run scheduled backups unattended, recognise incomplete backups, recover from failures, and restore the required files on a rebuilt machine with confidence.

---

## Source references

All references below point to the audited repository's `main` branch. For a reproducible review, use commit `dd87fc16c03148ab8db71468d272ca82d4b2584b`.

- [README.md](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/README.md)
- [TECHNICAL.md](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/TECHNICAL.md)
- [SECURITY.md](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/SECURITY.md)
- [V2.md](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/V2.md)
- [SyncMe-Host.ps1](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/SyncMe-Host.ps1)
- [SyncMe-Backup.ps1](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/SyncMe-Backup.ps1)
- [Modules/Restore.ps1](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/Modules/Restore.ps1)
- [Modules/Update.ps1](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/Modules/Update.ps1)
- [Register-BackupTask.ps1](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/Register-BackupTask.ps1)
- [Monitor host](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/Monitor/SyncMe-Monitor-Host.ps1)
- [Monitor default config](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/Monitor/Config/Monitor.json)
- [OfficeAgent setup](https://github.com/Metatronixa/SyncMe/blob/dd87fc16c03148ab8db71468d272ca82d4b2584b/OfficeAgent/Enable-SyncMeShadowCopies.ps1)
