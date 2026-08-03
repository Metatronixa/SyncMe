# Security Policy

**Website:** [www.syncme.co.za](https://www.syncme.co.za)  
**SyncMe** Copyright © 2026 Bradford Lotriet (`brad@web-zilla.co.za`)

Free to use — keep this credit. See [`LICENSE.txt`](LICENSE.txt).

This document explains how SyncMe handles security, what trust boundaries exist, how secrets are stored, what the product does and does not protect against, and how to report a vulnerability. It is written for operators, auditors, and researchers reviewing the GitHub Security tab.

## Supported versions

| Version | Supported for security fixes |
|---|---|
| 1.3.x (current) | Yes |
| 1.2.x | Critical issues only, while practical |
| 1.1.x and older | No (please upgrade) |
| Unreleased / custom forks | Not supported unless agreed in writing |

Security fixes ship in the latest release line first. Older tags may not receive backports.

## Reporting a vulnerability

**Do not** open a public GitHub issue, discussion, or pull request for a security vulnerability. Public reports can put operators at risk before a fix is available.

**Preferred contact:** email `brad@web-zilla.co.za` with subject line starting with `[SyncMe Security]`.

If GitHub private vulnerability reporting is enabled for this repository, you may also use that private channel from the Security tab. Email remains the reliable fallback.

Please include as much of the following as you can:

1. SyncMe version (`VERSION.txt`) and Windows edition (client or Server).
2. Affected component (host API, backup engine, UI, packaging, docs that mislead operators, third-party tool integration).
3. Description of the issue and why it is security-sensitive.
4. Steps to reproduce, or a minimal proof of concept.
5. Expected vs actual behaviour.
6. Impact (confidentiality, integrity, availability, privilege escalation, secret exposure).
7. Any suggested mitigation or fix.
8. Whether you need coordinated disclosure timing or credit.

### What we ask of reporters

- Act in good faith. Do not access data that is not yours.
- Do not destroy backups, wipe repositories, or disrupt production systems beyond what is needed to demonstrate the issue in a lab.
- Give a reasonable window to investigate and ship a fix before public disclosure.
- Do not demand payment as a condition of disclosure. SyncMe is a free personal project; we appreciate responsible reports and will credit you if you want credit.

### What you can expect from us

- Acknowledgement when the report is received (goal: a few business days; this is a single-maintainer project).
- An assessment of severity and whether the issue is in SyncMe, in operator configuration, or in an upstream tool (restic, rclone, Windows, Tailscale, cloud providers).
- A fix, mitigation guidance, or a clear explanation if we believe the behaviour is intentional and already documented as a trust-boundary limitation.
- Public disclosure via release notes and, when appropriate, a GitHub security advisory once a fix or guidance is ready.

## Product security model (overview)

SyncMe is a **file-level backup orchestrator** for a Windows Backup PC. It wraps [restic](https://restic.net/) (encrypted, deduplicated repositories) and optionally [rclone](https://rclone.org/) as a restic cloud backend. It is **not**:

- antivirus or endpoint detection
- ransomware protection or immutable storage by itself
- bare-metal imaging or full disaster recovery appliance
- a multi-user, internet-facing web application
- a replacement for restic’s or rclone’s own security guarantees

The security posture is **orchestration on a trusted Backup PC**, with strong encryption of backup data provided by **restic repository passwords**, and secret storage in **Windows Credential Manager** (not in `Config.ps1`).

Operators remain responsible for verifying backups, protecting credentials, hardening the Backup PC, and keeping offline copies of the restic password.

## Trust boundary: localhost console

The HTML console and JSON API are served by `SyncMe-Host.ps1` using .NET `HttpListener` bound to:

`http://127.0.0.1:17845`

Important consequences:

1. **Local-only by design.** The host is not intended as a LAN or internet web server. Anyone who can run code or open a browser **as a user on that Backup PC** while SyncMe is running can call the same APIs the UI uses (start backups, restore, change config, store credentials, run checks). Treat console access as equivalent to local admin-level backup control for that machine’s SyncMe install.
2. **No built-in login wall.** There is no SyncMe username/password for the UI. Authentication is “you are already on the Backup PC.”
3. **Do not reverse-proxy or port-forward** SyncMe to the internet or to untrusted networks. If you expose `:17845`, you are expanding the trust boundary beyond what SyncMe was designed for.
4. **Firewall / remote desktop.** Protect interactive and remote access to the Backup PC with normal Windows hardening (least privilege accounts, RDP restrictions, patching, disk encryption where appropriate).

Reports that SyncMe “has no web login” on localhost are generally **out of scope** as vulnerabilities unless you also show a way to reach the API from outside the local machine contrary to the bind address, or a clear privilege escalation beyond the local-user trust model.

## Secrets and credentials

### What must never go in `Config.ps1`

`Config.ps1` holds paths, schedules, retention, and set metadata. It must **not** hold:

- restic repository passwords
- SMTP passwords
- SMB share passwords
- rclone OAuth tokens (those live in `Config\rclone.conf`)

If a change causes SyncMe to write plaintext restic passwords into config, logs that are routinely shared, or the Rescue Kit HTML, treat that as a **high-priority** security bug.

### Windows Credential Manager

SyncMe uses Generic Credential Manager targets such as:

| Target pattern | Purpose |
|---|---|
| `SyncMeRestic` / `SyncMeRestic-<setId>` | Restic repository password |
| `SyncMeSmtp` | SMTP password for optional email |
| `SyncMeShare` / `SyncMeShare-<setId>` | Optional SMB credentials |

Operational rules that matter for security:

1. Credential Manager secrets belong to a **Windows user profile**. The scheduled task account that runs backups must be the **same** account that owns those secrets, or unattended jobs fail and operators may be tempted to weaken security (for example by storing secrets poorly).
2. Credential Manager protects secrets at rest under the Windows user / DPAPI model. It does **not** replace an offline password vault. If the Backup PC is destroyed, stolen, or the profile is lost, Credential Manager alone cannot recover the restic password for you.
3. Anyone with sufficient rights on that Windows account (or SYSTEM/admin abuse of that account) can typically read those secrets. Harden the Backup PC accordingly.

### Restic repository password

The restic password **encrypts the repository**. Without it there is no restore and no forensic recovery of file contents from the repo. SyncMe cannot invent a forgotten password.

**Required practice:** when the wizard creates or you set a password, save it in a password manager or other safe offline place. Do not rely only on the Backup PC.

Wrong password behaviour surfaces as restic exit codes (for example exit 12). Operations → Store password (or Edit set → Passwords) updates Credential Manager; it does not change an already-initialized repository’s password by itself.

### rclone / cloud OAuth

For OneDrive / Google Drive destinations, rclone OAuth tokens are stored in `Config\rclone.conf` under the SyncMe install. That file is local configuration, not something to commit to git or include in customer support zip dumps without review.

Cloud login alone cannot decrypt restic data. The restic password remains mandatory.

### Rescue Kit

Operations can export a printable **Rescue Kit** HTML sheet for disaster recovery handoff. By design it includes recovery guidance such as repository paths and Credential Manager target names. It must **not** include the restic password. Keep the password in your vault and attach it to the kit only by your own secure process.

If a Rescue Kit export ever embeds a live password or OAuth token, report that immediately.

### Packaging and distribution

Customer setup packages (`Build-SyncMeSetup.ps1` / `Build-SyncMePackage.ps1`) are intended to ship SyncMe scripts, UI, and docs only. They must **not** bundle:

- `website/` (marketing site source)
- `ui/mockups/`
- restic / rclone / WinSCP / WinFsp installers or binaries

Tools are downloaded or resolved on the host. If a release asset contains unexpected executables or marketing-site trees, report it as a packaging integrity issue.

## Backup integrity and destructive controls

SyncMe adds operator-facing controls that affect integrity and recoverability:

### Append-only policy (optional per set)

When enabled, SyncMe skips prune and blocks snapshot delete from the console for that set. This reduces accidental or hostile deletion of snapshots **through SyncMe’s UI/API paths**. It is **not** a full WORM / object-lock guarantee on every storage backend. Cloud buckets, NAS ACLs, and disk access outside SyncMe can still delete or encrypt data if those layers are compromised.

### Stale lock handling

Restic repository locks can block jobs after a crash. SyncMe may unlock only after an intended restic operation fails with lock-related errors and after checking that other SyncMe/restic processes do not appear to be running. Aggressive unlock of a live repository can corrupt concurrent writers. Reports should distinguish “unlock helped recovery” from “unlock raced a live backup.”

### Pre / post backup scripts

Optional hooks run as NonInteractive scripts with a timeout. They run in the security context of the backup process / scheduled task user. Treat script paths as privileged configuration: a malicious or writable script path is equivalent to code execution for that account. Prefer scripts only administrators can modify.

### Cancel / restore / prune

Console actions that cancel backups, restore into folders, prune, or delete snapshots are powerful. On localhost they are intentional operator tools. Do not expose them remotely.

### Verify culture (not optional)

Encrypted backups that nobody verifies are a false sense of safety. Operators should:

1. Run dry run, then a real backup.
2. Read Reports and Logs (restic exit 3 often means some files were locked/unread).
3. Use Operations Check (structural and weekly data subset). Structural check and data-subset failures fail the job.
4. Restore to an empty test folder and spot-check critical paths.
5. Review the weekly restore drill line in the HTML report (PASS / FAIL / SKIP). From **1.3.1** the drill is advisory only: it uses `restic dump` with retries, soft-skips when no snapshots/files exist, and never fails the overall job by itself. Treat a repeated FAIL as a signal to investigate restore health, not as a backup outage.

## What is in scope

We welcome reports such as:

- Secret leakage (passwords, tokens, or private keys written to config, Rescue Kit, HTML reports, world-readable logs, or release packages).
- Ways to reach the SyncMe API from a remote host despite the `127.0.0.1` bind, without the operator deliberately rebinding or proxying.
- Path traversal or unintended file write/delete outside documented restore/prune behaviour when using the console as a normal local user.
- Command injection via set names, paths, or API fields that leads to unexpected process execution.
- Privilege escalation from a low-privilege local user to another user’s Credential Manager secrets or SYSTEM without already having equivalent Windows rights.
- Supply-chain issues in SyncMe’s own download/install helpers (for example installing restic/rclone from an unexpected source, skipping integrity checks SyncMe claims to perform, or shipping trojaned binaries in official GitHub Release assets).
- Misleading security documentation that would cause a reasonable operator to store passwords unsafely.

## What is generally out of scope

Please do not expect these to be treated as SyncMe vulnerabilities by themselves:

- “No login on the localhost UI” (documented trust model).
- Loss of data because the restic password was not vaulted offline.
- Ransomware encrypting the Backup PC, source shares, or repository storage SyncMe can still see.
- Cloud provider throttling, account bans, or token expiry.
- Weak Windows account passwords, shared admin sessions, or RDP left open to the internet.
- Issues solely in upstream restic, rclone, WinFsp, Tailscale, or Windows that SyncMe merely invokes, unless SyncMe’s integration uniquely worsens them.
- Social engineering of operators.
- Denial of service by filling disk, killing processes, or holding repository locks while already having local admin on the Backup PC.
- Missing features (immutable cloud object lock, MFA for the UI, centralized SIEM) unless they contradict a specific security claim we make.

## Operator hardening checklist

Use this as a practical baseline, not a certification:

1. Install SyncMe only on a dedicated or well-controlled Backup PC.
2. Use a dedicated Windows account for scheduled backups; align Task Scheduler and Credential Manager to that account.
3. Keep the restic password in a password manager or offline vault; export a Rescue Kit and store it with that vault entry.
4. Prefer local disk or trusted NAS for primary repositories when possible; treat consumer cloud as capacity with throttling and account-risk caveats.
5. Enable Append-Only Mode for sets where prune/delete should be rare.
6. Restrict who can log on interactively to the Backup PC.
7. Do not publish port 17845 or reverse-proxy the console without an additional authenticated gateway you fully control and accept responsibility for.
8. Keep Windows, restic, and rclone reasonably up to date.
9. Verify restores on a schedule, not only after a disaster.
10. After a Backup PC rebuild, restore secrets deliberately; do not invent a new restic password against an existing repository.

## Third-party software

SyncMe orchestrates separate open-source programs. SyncMe is not affiliated with or endorsed by their authors. See [`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt).

Security issues in those projects should usually be reported upstream. Tell us as well if SyncMe’s wrappers make a dangerous default easy to hit.

## License, warranty, and liability

SyncMe is free to use under [`LICENSE.txt`](LICENSE.txt). It is provided **AS IS**, without warranty. The author is not liable for data loss, ransomware, misconfiguration, failed restores, or unauthorized access affecting systems SyncMe reads or writes. You are responsible for verifying backups, securing credentials and destinations, and maintaining additional recovery plans.

## Contact

- Security and general contact: `brad@web-zilla.co.za`
- Product site: [www.syncme.co.za](https://www.syncme.co.za)
- Releases: [GitHub Releases](https://github.com/Metatronixa/SyncMe/releases)

Thank you for helping keep SyncMe operators safe.
