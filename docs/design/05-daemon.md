# Privileged daemon

Technical side of F3 (helper installation, start/stop, reconnect) and the transport for
F4/F5 (status and logs). The daemon is a small Swift executable: XPC listener, a
`Supervisor` actor, process/route helpers. No UI, no Keychain, no networking of its own.

## Registration (SMAppService)

`Wayfork.app/Contents/Library/LaunchDaemons/com.wayfork.daemon.plist`:

```xml
<dict>
  <key>Label</key>                      <string>com.wayfork.daemon</string>
  <key>BundleProgram</key>              <string>Contents/MacOS/WayforkDaemon</string>
  <key>MachServices</key>               <dict><key>com.wayfork.daemon.xpc</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>com.wayfork.app</string></array>
  <key>RunAtLoad</key>                  <false/>
  <key>KeepAlive</key>                  <false/>
  <key>ProcessType</key>                <string>Interactive</string>
</dict>
```

- `SMAppService.daemon(plistName: "com.wayfork.daemon.plist")`. `register()` on first
  Turn On; status polling handles `.requiresApproval` (see UX). launchd starts the daemon
  on the first XPC connection.
- Requires the app to be signed with a real Team ID (Apple Development or Developer ID).
  Ad-hoc builds cannot use `SMAppService`; `scripts/dev-sign.sh` signs debug builds with the
  developer's certificate.
- App update: handshake compares `daemonVersion` and `bundlePath`; mismatch →
  `unregister()` then `register()`.

## XPC interface

Payloads are `Codable` structs encoded as `Data` (JSON); the `@objc` protocols stay
minimal and stable.

```swift
@objc protocol WayforkDaemonXPC {
    func getInfo(_ reply: @escaping (Data) -> Void)                 // DaemonInfo
    func apply(_ plan: Data, _ reply: @escaping (Data) -> Void)     // RuntimePlan → ApplyResult
    func stop(_ reply: @escaping (Data) -> Void)                    // → ApplyResult
    func reconnect(tunnelID: String, _ reply: @escaping (Data) -> Void)
    func getStatus(_ reply: @escaping (Data) -> Void)               // RuntimeStatus
    func subscribe(_ reply: @escaping (Data) -> Void)               // registers the client's exported object for pushes
    func collectDiagnostics(_ reply: @escaping (Data) -> Void)      // DaemonDiagnostics (daemon log tails, run/ listing, routes)
}

@objc protocol WayforkClientXPC {          // exported by the app on its connection
    func statusChanged(_ status: Data)     // RuntimeStatus, on every change (coalesced 100 ms)
    func logLines(_ batch: Data)           // [LogLine], every 250 ms or 200 lines
}
```

```swift
struct DaemonInfo: Codable { var version: String; var bundlePath: String; var singBoxVersion: String; var openVPNVersion: String }
struct ApplyResult: Codable { var ok: Bool; var error: DaemonError? }
struct RuntimeStatus: Codable {
    var engine: EngineState            // stopped | starting | running(since) | failed(reason)
    var tunnels: [String: TunnelState] // by tunnel id (OpenVPN only)
    var planHash: String?              // hash of the last applied plan
}
struct LogLine: Codable { var ts: Date; var source: String; var level: LogLevel; var message: String }
```

Semantics: `apply` returns after reconcile has been *initiated* and `sing-box check` passed;
progress arrives via `statusChanged`. A second `apply` while one is in flight is queued
(latest wins). `stop` returns after every child has exited or been killed.

## Client verification

On `listener(_:shouldAcceptNewConnection:)`:

```swift
connection.setCodeSigningRequirement(
    "anchor apple generic and identifier \"com.wayfork.app\" and certificate leaf[subject.OU] = \"<TEAMID>\"")
```

The Team ID is baked in at build time from the signing identity: `Wayfork/Daemon/Info.plist`
carries `WayforkTeamID = $(DEVELOPMENT_TEAM)`, which Xcode expands and embeds into the
daemon binary (`__TEXT,__info_plist` section, `CREATE_INFOPLIST_SECTION_IN_BINARY`).
`scripts/dev-sign.sh` derives `DEVELOPMENT_TEAM` from the chosen identity and verifies the
embedded value after the build. Ad-hoc builds (plain `xcodebuild`, CI) leave it empty, so
such a daemon rejects every client — by design, since `SMAppService` cannot register them
anyway. Connections failing the requirement are rejected before any method runs. Only one
client at a time is expected; a second connection replaces the subscriber.

## Supervisor

Single actor owning:

```swift
actor Supervisor {
    var plan: RuntimePlan?
    var singBox: ManagedProcess?
    var openVPN: [String: OpenVPNSession]      // ManagedProcess + management socket client
    var status: RuntimeStatus
}
```

`ManagedProcess`: `posix_spawn` (with `POSIX_SPAWN_SETSIGMASK` cleared, file actions for
stdout/stderr pipes, cwd `run/`), pid file, `DispatchSource` for exit, line-buffered readers
feeding the log stream. Restart policy per process:

- Backoff 1, 2, 4, 8, 16, 32, 60 s; counter resets after 60 s of uptime.
- sing-box: 3 exits within 60 s → `engine = failed`, children keep running (tunnels stay up
  but nothing is routed through them), user is notified.
- openvpn: permanent failures (auth, key passphrase, config error) stop retries; anything
  else retries while `autoReconnect` is on. `reconnect(tunnelID:)` resets backoff and
  restarts immediately.

Reconcile runs on the actor; per-process start/stop are `async` steps so a slow openvpn
shutdown never blocks status queries.

### Binary validation

Before every spawn: resolve `<bundle>` from the daemon's own executable path
(`…/Contents/MacOS/WayforkDaemon` → three levels up), then
`SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` against
`anchor apple generic and identifier "com.wayfork.bin.<name>" and certificate leaf[subject.OU] = "<TEAMID>"`
(same Team ID as the client requirement; the identifiers `com.wayfork.bin.sing-box` /
`com.wayfork.bin.openvpn` are assigned by `scripts/embed-bins.sh` when the binaries are
copied into the bundle and signed). Failure → `DaemonError.binaryUntrusted`, nothing runs.

### Startup cleanup

1. Read `run/*.pid`; for each pid, compare `proc_pidpath` with our binaries; matching
   processes get SIGTERM → 3 s → SIGKILL.
2. Delete stale sockets, `t-*.ovpn`, `sing-box.json`, `rules-*.json`. Keep `cache.db`.
3. Remove scoped default routes on `utun101…utun132` if any survive (`route -n delete
   -ifscope utunN default`, ignore errors).
4. `status = stopped`.

### Route helper

`/sbin/route` executed with an argv array (absolute path, no shell). Interface names are
validated against `^utun(1[0-9]{2})$` before use. Later can move to a `PF_ROUTE` socket to
drop the exec.

## Files written by the daemon

| File | Mode | Note |
|------|------|------|
| `run/sing-box.json` | 0600 | contains VLESS UUIDs and REALITY keys → root-only |
| `run/rules-t-<id>.json` | 0600 | rewritten in place via temp file + `rename` so sing-box's watcher sees one change |
| `run/t-<id>.ovpn` | 0600 | contains private keys |
| `run/t-<id>.sock` | 0600 | management socket |
| `run/*.pid` | 0600 | |
| `run/cache.db` | 0600 | sing-box cache |
| `/Library/Logs/Wayfork/daemon.log` | 0600 | daemon's own log (also `os_log`, subsystem `com.wayfork.daemon`) |
| `/Library/Logs/Wayfork/<source>.log` | 0600 | raw child output, 5 × 1 MB rotation |

Everything under `run/` except `cache.db` is deleted on `stop`.

## Logging plumbing

Child stdout/stderr → line reader → `LogLine` (source `sing-box` / `openvpn:<id>`, level
parsed from the line: sing-box prefixes `INFO`/`WARN`/`ERROR`/`DEBUG`, openvpn management
`>LOG` flags `I`/`W`/`F`/`N`/`D`) → ring buffer of the last 2 000 lines per source (for
reattach) → batched push to the subscribed client. Daemon's own events use source `daemon`.

Redaction at the source: the management client never logs what it writes to the socket;
sing-box's `log.level` is capped at `info` in the generated config unless the user picks
`debug`, in which case the UI warns that debug logs may include hostnames.
