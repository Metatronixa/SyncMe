# SyncMe ↔ LocalOps Console Integration

> **Status:** Planned (docs-first). Behavior described as “shipped” below is what 1.4.x already does; fleet cutover is not implemented yet.  
> **LocalOps spec (source of truth for phases/API):** sibling repo `LocalOpsConsole/docs/SYNCME_INTEGRATION.md`.

## Shipped today

### Same-host LocalOps registration

- Module: `Modules/LocalOpsClient.ps1`
- When LocalOps is reachable on loopback (`http://127.0.0.1:8787` by default) and `LocalOpsEnabled` is true, SyncMe POSTs `/api/v1/syncme/register` with install path and optional last-run summary.
- Non-fatal if LocalOps is offline.
- Lets LocalOps Operations → SyncMe open the console / start backup without manually setting `syncMePath`.

### SyncMe Monitor (optional package)

- Module: `Modules/MonitorClient.ps1`
- Separate host package (`SyncMe-Monitor-Setup-*.zip`) on port **17846**, Bearer token.
- Post-backup (and Save test) heartbeats for a multi-PC fleet dashboard.
- Remains supported until LocalOps fleet ingest ships and dual-write cutover completes.

## Locked upcoming direction

1. **Monitor’s fleet UI role moves to LocalOps Console** — not into SyncMe core host (keeps SyncMe install lean).
2. SyncMe keeps **thin clients** only: LocalOps register + Monitor-compatible heartbeat POST.
3. LocalOps will accept the **same heartbeat JSON** MonitorClient already sends, with Bearer auth (`syncMeFleetToken` on the LocalOps side).
4. **Dual-write** one release (Monitor URL + LocalOps), then deprecate and stop shipping the Monitor setup zip.
5. Loopback LocalOps register for local `installPath` stays; it is not a substitute for token fleet ingest.

## SyncMe client duties (when implementing)

| Duty | Module / config | Notes |
|------|-----------------|-------|
| Probe LocalOps health | `LocalOpsClient.ps1` | Already: GET `/api/v1/health` |
| Loopback register | `LocalOpsClient.ps1` | Already: POST `/api/v1/syncme/register` |
| Fleet heartbeat | `MonitorClient.ps1` | Point `MonitorUrl` at LocalOps base once ingest exists; client appends `/api/heartbeat` if needed |
| Options | `Config/SyncMeOptions.json` | `LocalOpsUrl`, `LocalOpsEnabled`, `MonitorUrl`, `MonitorToken`, `MonitorSiteId` |
| Fleet dashboards UI | Host Operations | Prefer LocalOps during cutover; remove Monitor-only path after Phase 4 |

Do **not** merge Monitor’s HttpListener UI into `SyncMe-Host.ps1`. Do **not** send restic passwords or rclone secrets in heartbeats.

## Cutover (SyncMe releases)

1. LocalOps ships token fleet ingest + SyncMe sites UI (see LocalOps spec phases 1–2).
2. SyncMe docs/UI: set Monitor URL to LocalOps (or dual-write if a second URL field is added temporarily).
3. Mark Monitor package deprecated in README / build output.
4. Stop building `SyncMe-Monitor-Setup-*.zip`; Fleet dashboards point only at LocalOps.
5. Update `V2.md` decision D005 when Monitor package is actually removed from the release train.

## Related

- This repo: [README.md](../README.md) (Monitor + LocalOps sections)
- This repo: [V2.md](../V2.md) (architecture; Monitor not absorbed into SyncMe host)
- LocalOps: `docs/SYNCME_INTEGRATION.md`, `modules/SyncMe/README.md`
