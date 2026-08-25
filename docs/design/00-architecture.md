# Architecture

Covers F3 (start/stop) at the system level and the ground rules every other design doc
relies on. Feature-specific details live in the sibling documents.

## Components

| Component        | Runs as              | Responsibility |
|------------------|----------------------|----------------|
| `Wayfork.app`    | user, menu bar app   | UI, model + persistence, Keychain, `sing-box.json` generation, XPC client |
| `WayforkDaemon`  | root, launchd daemon | Spawns and supervises `sing-box` and `openvpn`, adds interface-scoped routes, captures child logs, exposes XPC |
| `sing-box`       | root, child of daemon| TUN, DNS (fake-ip + hijack), routing rules, VLESS outbounds |
| `openvpn` × N    | root, child of daemon| One process per OpenVPN tunnel on its own `utun`, `--route-nopull` |

```
 ┌───────────────────────── user session ─────────────────────────┐
 │  Wayfork.app  ── store.json / Keychain                          │
 │      │  XPC (Mach service, code-signing checked)                │
 └──────┼─────────────────────────────────────────────────────────┘
        ▼
 ┌───────────────────────── root (launchd) ───────────────────────┐
 │  WayforkDaemon ── /Library/Application Support/Wayfork/run/     │
 │      ├── sing-box  ──── utun100 (TUN, default route)            │
 │      ├── openvpn   ──── utun101  (tunnel A)                     │
 │      └── openvpn   ──── utun102  (tunnel B)                     │
 └────────────────────────────────────────────────────────────────┘
```

Packet flow: every app → TUN (`utun100`) → sing-box → rule match →
`direct` (physical interface) | `direct` bound to `utun10N` (OpenVPN) | VLESS outbound.
See [03-routing.md](03-routing.md).

## Trust boundaries

The daemon is root and can execute binaries; the app is unprivileged. Rules:

1. The daemon accepts XPC connections only from a client whose code signature matches our
   Team ID and bundle identifier (`NSXPCConnection.setCodeSigningRequirement`, macOS 13+).
2. The daemon executes only the binaries shipped next to it inside the app bundle
   (`Contents/Resources/bin/sing-box`, `Contents/Resources/bin/openvpn`). Paths are derived
   from the daemon's own executable location, never received from the client. Each binary's
   signature is validated (`SecStaticCodeCheckValidity`) before every spawn.
3. The daemon never receives file paths from the app. It receives config *contents* and
   writes them itself into a root-only directory.
4. The daemon validates the plan: interface names within the allowed range, tunnel count
   ≤ 32, config sizes ≤ 1 MB, no shell involved anywhere (`posix_spawn` with argv arrays).
5. `openvpn` runs with `--script-security 1`: `up`/`down` scripts from user configs are
   never executed. Directives that would let a config escape the sandbox are stripped at
   import (see [04-tunnels.md](04-tunnels.md)).
6. Secrets live in the user's Keychain and are read by the app only; they cross into the
   daemon over XPC at start and are held in memory there. OpenVPN credentials are passed
   through the management socket, never written to disk.

## Filesystem layout

| Path | Owner | Contents |
|------|-------|----------|
| `~/Library/Application Support/Wayfork/store.json` | user | tunnels, rules, settings — no secrets |
| Keychain (login) | user | OpenVPN config bodies, credentials, key passphrases, VLESS UUIDs |
| `~/Library/Logs/Wayfork/` | user | app log + mirrored runtime logs (see [06-logging.md](06-logging.md)) |
| `/Library/Application Support/Wayfork/run/` | root `0700` | `sing-box.json`, `rules-*.json`, `t-<id>.ovpn`, management sockets, pid files, `cache.db` |
| `/Library/Logs/Wayfork/` | root `0700` | daemon log, raw child stdout/stderr (rotated) |
| `Wayfork.app/Contents/Resources/bin/` | bundle | `sing-box`, `openvpn` (static builds, pinned versions) |
| `Wayfork.app/Contents/Library/LaunchDaemons/com.wayfork.daemon.plist` | bundle | daemon registration for `SMAppService` |
| `Wayfork.app/Contents/MacOS/WayforkDaemon` | bundle | daemon executable |

`run/` is wiped on stop except `cache.db` (fake-ip mappings must survive restarts, otherwise
apps holding cached fake IPs break until they re-resolve).

## Runtime plan (desired state)

The app never issues imperative "start X" commands. It computes a `RuntimePlan` from the
store and sends the whole thing; the daemon reconciles current state towards it. Hot reload,
reconnect-only-what-changed and crash recovery all fall out of this.

```swift
struct RuntimePlan: Codable {
    var version: Int                      // plan format version
    var singBox: SingBoxPlan              // config JSON + rule-set files
    var openVPN: [OpenVPNRuntime]         // VLESS tunnels have no process; they live in the sing-box config only
    var autoReconnect: Bool               // Settings.autoReconnect; not hashed, applies to the next failure
    var logLevel: LogLevel                // Settings.logLevel → openvpn --verb; part of the OpenVPN diff key
}
struct SingBoxPlan: Codable {
    var config: String                    // sing-box.json
    var ruleSets: [String: String]        // "rules-t-<id>.json" → contents
    var configHash: String                // hash of config with rule-set contents excluded
}
struct OpenVPNRuntime: Codable {
    var id: String                        // tunnel id
    var interface: String                 // "utun101"
    var config: String                    // sanitized .ovpn body (inline certs/keys)
    var credentials: Credentials?         // username/password
    var keyPassphrase: String?
    var configHash: String
}
```

Reconcile algorithm (daemon):

1. OpenVPN: diff by `id` + `configHash` + `--verb` (derived from `logLevel`). Stop removed,
   start added, restart changed. Unchanged processes are left alone.
2. sing-box:
   - `configHash` unchanged, rule-set contents changed → rewrite rule-set files only.
     sing-box reloads `type: local` rule-sets on file change — no restart, no dropped
     connections. *(Verify on the pinned version; fallback is a restart.)*
   - `configHash` changed → write config, run `sing-box check`; on failure keep the old
     process running and return the error; on success restart sing-box (< 1 s, in-flight
     connections through TUN are dropped).
   - Not running → start.
3. Start order is not enforced: sing-box and openvpn processes start concurrently. A
   `direct` outbound bound to a not-yet-existing `utun10N` fails per-connection until the
   tunnel is up, which surfaces as the tunnel being in `connecting` state. *(Verify that
   sing-box resolves `bind_interface` lazily at dial time, not at startup.)*

## Lifecycle

**Turn On** (app): ensure daemon registered and approved → connect XPC → version handshake
→ `apply(plan)` → subscribe to status/log streams.

**Turn Off**: `stop()` → daemon sends SIGTERM to sing-box first (restores routing), then to
every openvpn; waits up to 5 s, then SIGKILL; removes scoped routes it added; wipes `run/`.

**App quit**: stops everything (MVP decision: no headless tunnels without UI).

**App crash**: daemon keeps running. On relaunch the app calls `getStatus()` and reattaches;
the menu reflects the live state.

**Daemon start** (launchd, on demand when the app connects): read pid files, kill leftover
children whose executable path matches our bundle, remove stale routes/sockets, state =
stopped.

**Daemon crash**: launchd restarts it on next connection; the cleanup above handles orphans.
The daemon does not exit on idle in MVP.

**App update**: the daemon reports its version, bundle path and executable CDHash in the
handshake. Mismatch (or `.notFound` status after the app was moved) → `unregister()` +
`register()`; may require re-approval in System Settings.

## State machines

Global (derived in the app from daemon status):

```
off ──turnOn──▶ starting ──▶ on ⇄ degraded
 ▲                │           │
 └──── stopping ◀─┴───────────┘        error(reason)  ← sing-box failed to start
                                                       or crashed 3× in 60 s
```

- `on`: sing-box running and every enabled OpenVPN tunnel `connected`.
- `degraded`: sing-box running, at least one enabled tunnel not connected.
- `starting`: plan applied, waiting for first `on`/`degraded` (timeout 30 s → `degraded`).

OpenVPN tunnel (owned by daemon):

```
disabled | connecting(attempt) → connected(since, ip, interface)
                 │                        │
                 ▼                        ▼
         failed(reason, permanent)  reconnecting(attempt, nextIn)
```

- Permanent failures (auth rejected, config parse error, wrong key passphrase): no retries
  until the user changes something.
- Transient failures: openvpn's own reconnect first; if the process exits, daemon restarts
  with backoff 1, 2, 4, 8, 16, 32, 60 s (reset after 60 s stable). Off when
  `settings.autoReconnect` is false.

VLESS tunnel: no process, no health check in MVP. Shown as `ready` while sing-box runs;
reachability is only known per connection. Health checks are L4.

## Concurrency

Swift concurrency throughout. The app has one `@MainActor` `AppModel` (store + runtime
status). The daemon has a single `Supervisor` actor owning all child processes; XPC handlers
hop onto it. No shared mutable state elsewhere.

## Versions and pinning

`scripts/versions.env` pins `SING_BOX_VERSION` and `OPENVPN_VERSION`; `scripts/fetch-bins.sh`
downloads/builds them into `Wayfork/Resources/bin/` (git-ignored). The generated config
targets sing-box's current schema (`route.rules[].action`, typed `dns.servers`); bumping
sing-box requires a config-generator review.
