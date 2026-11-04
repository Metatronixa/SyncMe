# SyncMe ↔ LocalOps Console Integration

> **Status:** LocalOps Phase 2 fleet ingest is shipped. SyncMe **1.5.1+** dual-writes fleet heartbeats (Monitor URL + LocalOps loopback) and marks the Monitor package deprecated. **1.5.3** adds heartbeat `status` (`ok`/`degraded`/`failed`) so restic exit 3 is not shown as healthy — see [V2.1-SECURITY.md](V2.1-SECURITY.md) §0.  
> **LocalOps spec:** sibling repo `LocalOpsConsole/docs/SYNCME_INTEGRATION.md`.

## Shipped today

### Same-host LocalOps registration

- Module: `Modules/LocalOpsClient.ps1`
- When LocalOps is reachable on loopback (`http://127.0.0.1:8787` by default) and `LocalOpsEnabled` is true, SyncMe POSTs `/api/v1/syncme/register` with install path and optional last-run summary.
- Non-fatal if LocalOps is offline.
- Lets LocalOps Operations → SyncMe open the console / start backup without manually setting `syncMePath`.

### Fleet heartbeats (dual-write)

- Module: `Modules/MonitorClient.ps1` (+ `Send-SyncMeLocalOpsFleetHeartbeat` in `LocalOpsClient.ps1`)
- **Preferred:** set Monitor URL to LocalOps base (`http://OPS-PC:8787`). Client POSTs `/api/heartbeat` (LocalOps alias) with Bearer = LocalOps `syncMeFleetToken`.
- **Also:** when LocalOps is on this PC and `MonitorToken` is set, SyncMe POSTs `/api/v1/syncme/sites/heartbeat` on loopback (dual-write during cutover).
- Legacy SyncMe Monitor (`:17846`) still accepts the same POST if Monitor URL points there.

### SyncMe Monitor package (deprecated)

- Still built as `SyncMe-Monitor-Setup-*.zip` for one more release line.
- Prefer LocalOps Operations → SyncMe fleet list. Monitor will stop shipping in a later release (Phase 4).

## Locked direction

1. Monitor’s fleet UI role lives in **LocalOps Console** — not SyncMe core host.
2. SyncMe keeps **thin clients** only.
3. Loopback LocalOps register for local `installPath` stays separate from token fleet ingest.
4. Do **not** merge Monitor’s HttpListener into `SyncMe-Host.ps1`.
5. Do **not** send restic passwords or rclone secrets in heartbeats.

## Options (`Config/SyncMeOptions.json`)

| Key | Role |
|-----|------|
| `LocalOpsUrl` / `LocalOpsEnabled` | Loopback register (+ dual-write fleet when token set) |
| `MonitorUrl` | Fleet dashboard base (prefer LocalOps `:8787`; legacy Monitor `:17846`) |
| `MonitorToken` | Bearer — must match LocalOps `syncMeFleetToken` (or Monitor.json Token) |
| `MonitorSiteId` | Stable site key |

## Cutover checklist

1. LocalOps: set `syncMeFleetToken`; confirm fleet list in SyncMe tab.
2. SyncMe: set Monitor URL to LocalOps; shared token; Save (test heartbeat).
3. Optional dual-write: keep a second Monitor host on `:17846` during transition.
4. Phase 4: stop building Monitor zip; Fleet dashboards UI LocalOps-only; update `V2.md` D005.
5. **1.9.0:** per-device HMAC identity (`Data/Fleet/device.json`, DPAPI) + `X-SyncMe-Device-*` headers on heartbeats; LocalOps verifies signature/skew/nonce when headers present. Shared Bearer remains the channel gate for one release (dual-write compat). Loopback register publishes `deviceId` + `deviceHmacSecret` into `data/syncme/devices/`. No remote command channel yet.

## Related

- [README.md](../README.md)
- [V2.md](../V2.md)
- [V2.1-SECURITY.md](V2.1-SECURITY.md) — §0 shipped vs remaining
- LocalOps: `docs/SYNCME_INTEGRATION.md`
