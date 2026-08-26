# Privileged daemon

Technical side of F3 (helper installation, start/stop, reconnect) and the transport for
F4/F5 (status and logs). The daemon is a small Swift executable: XPC listener, a
`Supervisor` actor, process/route helpers. No UI, no Keychain, no networking of its own.

Everything that needs no privileges lives in the `WayforkDaemonCore` library (second
target of the `WayforkCore` package, unit-tested without root): `ManagedProcess`
(`posix_spawn` + pipes + exit source), `UnixSocketLineClient`, `RotatingLogFile`,
`AtomicFile`, the management-protocol parser and `OpenVPNSessionReducer` (the whole
tunnel state machine as a pure reducer: events in, `TunnelState` + effects out),
`ReconcilePlanner`, `PlanValidator`, `BackoffPolicy`/`CrashCounter`, `RouteCommand`,
argv builders. `Wayfork/Daemon/` only wires those to XPC, `Security` and the filesystem.

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
- App update: handshake compares `version`, `bundlePath` and `buildID` (the CDHash of the
  daemon executable — a rebuild of the same version is a different daemon, and launchd keeps
  the old process alive otherwise, and the daemon hashes its executable once at startup —
  hashing on request reports the *replaced* file and hides a stale process); mismatch →
  `unregister()` then `register()`. Seen
  2026-08-25: approval survives the re-registration, no second Login Items prompt.

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
    func trafficChanged(_ snapshot: Data)  // TrafficSnapshot, once a second while sing-box runs (F9)
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
struct TrafficSnapshot: Codable {
    var sampledAt: Date
    var interval: TimeInterval                 // seconds covered by the rates
    var tunnels: [String: TrafficCounters]     // by tunnel id (OpenVPN and VLESS alike)
    var direct: TrafficCounters
}
struct TrafficCounters: Codable {
    var downBytesPerSecond: Double; var upBytesPerSecond: Double
    var downTotal: UInt64; var upTotal: UInt64 // since Turn On
    var connections: Int                       // open at sample time
}
```

Semantics: `apply` validates the plan, runs `sing-box check` and — when sing-box has to
(re)start — waits for its startup verification (≤ ~4 s) before returning; OpenVPN
processes are only spawned, their progress arrives via `statusChanged`. `apply`, `stop` and
`reconnect` execute one at a time in call order; an `apply` that is still waiting when a
newer one arrives is skipped (latest wins) and answers `ok`. `stop` returns after every
child has exited or been killed. Status queries never wait for an operation in flight.

`TunnelState.failed(reason:)` and `EngineState.failed(reason:)` carry the codes from the
error catalogue in [02-ux.md](02-ux.md) (`ovpn.authFailed`, `ovpn.needsCredentials`,
`ovpn.keyPassphrase`, `ovpn.needsKeyPassphrase`, `ovpn.configError`,
`ovpn.unsupportedPrompt`, `ovpn.exited` (auto-reconnect off), `ovpn.startFailed`,
`singbox.startFailed`); details go to the log stream.

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

Before every spawn (and once more at the start of every `apply`, so an untrusted binary
fails the whole plan before anything is written): resolve `<bundle>` from the daemon's own
executable path (`…/Contents/MacOS/WayforkDaemon` → three levels up), then
`SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` against
`anchor apple generic and identifier "com.wayfork.bin.<name>" and certificate leaf[subject.OU] = "<TEAMID>"`
(same Team ID as the client requirement; the identifiers `com.wayfork.bin.sing-box` /
`com.wayfork.bin.openvpn` are assigned by `scripts/embed-bins.sh` when the binaries are
copied into the bundle and signed). Failure → `DaemonError.binaryUntrusted`, nothing runs.

### Startup cleanup

1. Put the system resolver back if `run/dns-override.json` was left behind (daemon crash,
   `kill -9`; see "System resolver override").
2. Read `run/*.pid`; for each pid, compare `proc_pidpath` with our binaries; matching
   processes get SIGTERM → 3 s → SIGKILL.
3. Delete stale sockets, `t-*.ovpn`, `sing-box.json`, `rules-*.json`. Keep `cache.db`.
4. Remove scoped default routes on `utun101…utun132` that still exist as interfaces
   (`route -n delete -inet default -ifscope utunN`, ignore errors).
5. `status = stopped`.

The daemon also handles `SIGTERM` (launchd unload, app update): it runs `stop` and exits,
so no child outlives it.

### Route helper

`/sbin/route` executed with an argv array (absolute path, no shell). Interface names are
validated against `^utun(1[0-9]{2})$` before use. Later can move to a `PF_ROUTE` socket to
drop the exec.

## Traffic sampling (F9)

Per-tunnel rates come from sing-box's Clash API (`with_clash_api` is in the pinned build),
which counts bytes per connection for every outbound — OpenVPN (`direct` bound to `utun10N`)
and VLESS alike. Interface counters would only cover OpenVPN, so one mechanism serves both.

- **Config**: the app's generated config stays as it is (goldens unchanged, `configHash`
  unaffected). Before `sing-box check` the daemon injects
  `experimental.clash_api = { "external_controller": "127.0.0.1:<port>", "secret": "<hex>" }`
  into the JSON it writes (`ClashAPIConfig` in `WayforkDaemonCore`): the port is a free
  loopback port probed by binding `127.0.0.1:0`, the secret 32 random bytes, both regenerated
  on every sing-box start and never leaving the daemon. If sing-box loses the bind race it
  fails to start and the normal `singbox.startFailed` path reports it; the next `apply`
  probes again.
- **Sampler**: a `TrafficSampler` task lives on the `Supervisor` while sing-box is running:
  every second `GET /connections` with `Authorization: Bearer <secret>` over `URLSession`
  (loopback only; no proxy), decode `{ connections: [{ id, chains, upload, download }] }`.
  `TrafficAccumulator` attributes a connection to the tunnel whose tag `t-<id>` appears in
  `chains`, everything else to `direct`, and turns per-connection cumulative counters into
  per-outbound deltas: connections seen in both samples contribute `now − previous`, new
  ones their full count, closed ones nothing (≤ 1 s of a closing connection's bytes is lost;
  acceptable for a rate display). Rates divide by the measured interval; totals accumulate
  since Turn On and survive sing-box restarts (the per-connection map is cleared, the totals
  are not), `stop` resets everything. Snapshots are pushed to subscribed clients through
  `trafficChanged`; nothing is stored.
- **Failures**: an HTTP or decode error logs one WARNING per failure streak (`traffic:
  clash api unreachable`) and the sampler keeps trying every second; no snapshot is sent, so
  the app shows `—` after its 3 s staleness cut-off. Sampling never affects `apply`, `stop`
  or status.
- **Privacy**: `/connections` lists destination hosts, so the secret is a trust boundary: it
  exists only in root-only `run/sing-box.json` (0600) and daemon memory, never in logs,
  diagnostics or XPC. The daemon forwards aggregates only — no hosts, no addresses.
- **Developer mode** prints one `traffic:` line per snapshot so the sampler can be verified
  without the app.
- Implementation notes (2026-08-25): the endpoint is generated per config *write*
  (`SingBoxEngine.check` → `ClashAPIEndpoint.generate` + `ClashAPIConfig.inject`, port probed
  by binding `127.0.0.1:0`), so a crash restart reuses the file on disk with its port and
  secret; an `apply` that restarts sing-box regenerates both. The injected file is
  re-serialized by `JSONSerialization` (sorted keys); the app's `configHash` stays that of
  the original text. `TrafficSampler` (daemon) polls with an ephemeral `URLSession`
  (`connectionProxyDictionary = [:]`, 0.9 s timeout) and drops a sample that completes after
  `pause`; `SingBoxEngine` starts it after startup verification and pauses it on stop/exit,
  `Supervisor.performStop` resets it. `TrafficAccumulator` (`WayforkDaemonCore`) attributes a
  connection by the first `t-<id>` tag in `chains` (`Tunnel.tunnelID(fromOutboundTag:)`);
  `dns-out`, `block` and chain-less entries count as Direct. A counter that shrank under a
  reused id, or an id that moved to another outbound, is treated as a new connection. The
  snapshot lists only tunnels seen since Turn On; the app reads a missing entry as zero.

## Connection cut on rule change

sing-box reloads a rewritten rule-set within ~350 ms but leaves established connections on
the outbound they were matched to. A browser's keep-alive connection therefore ignores a
new rule until it happens to close (2026-08-26, "rules need an app restart"). After a
`rewriteRuleSets` the daemon closes the affected connections:

- `RuleSetSelectors` (`WayforkDaemonCore`) flattens a rule-set file in sing-box's source
  format into its matchers (`domain`, `domain_suffix`, `domain_regex`,
  `process_path_regex`, `ip_cidr`); the symmetric difference of the old and new file, over
  all rewritten files, is the *change*. A connection is affected when its Clash API
  `metadata.host` (fake-ip or sniffed domain) matches a changed domain matcher, its
  `processPath` a changed app matcher, or its `destinationIP` a changed CIDR. Matching is a
  deliberate superset of sing-box's (a rule moved between tunnels is both removed and added).
- 1 s after the rewrite (`SingBoxEngine.ruleSetReloadGrace`, so the reload has landed and
  reconnects hit the new rules) the engine fetches `GET /connections` and issues
  `DELETE /connections/<id>` for each affected one; if a file is not in the expected shape
  the change is unknown and `DELETE /connections` closes everything. One INFO line reports
  the count. Failures are logged and otherwise ignored — the rules are already in effect
  for new connections.
- `ClashConnection` now decodes `metadata.host` / `destinationIP` / `processPath` for this;
  they are used inside the daemon only and never forwarded (the privacy note under
  "Traffic sampling" stands).

## System resolver override (F12)

While sing-box is `running` the daemon makes Wayfork the system resolver
(docs/design/03-routing.md, "Notes on specific choices"). `ResolverOverride` (actor) writes

```
State:/Network/Service/<PrimaryService>/DNS = { ServerAddresses: ["172.19.0.1"],
                                                SearchDomains, DomainName: <as before> }
```

through `SCDynamicStore` (root), `<PrimaryService>` being `PrimaryService` of
`State:/Network/Global/IPv4`. configd folds it into `State:/Network/Global/DNS`, and
mDNSResponder sends every query to the TUN address, where `hijack-dns` answers. Search
domains are kept so that `host.lan` still resolves (through `dns-direct`).

- **Record.** Before the first write the previous value of the key (or its absence) is
  saved to `run/dns-override.json` (`{service, original}`, 0600). Restore = write the
  original back (or remove the key when there was none) and delete the record.
- **Lifecycle.** Active iff the plan says so (`RuntimePlan.overrideSystemDNS`) *and* the
  engine is `running`; every other engine state (`starting` during a crash backoff,
  `failed`, `stopped`) restores at once, so there is no window with a resolver that leads
  nowhere. `stop` restores before `run/` is wiped (the record is not transient); SIGTERM
  goes through `stop`; bootstrap restores a leftover record before anything else.
- **Rewrites.** configd rewrites the key on DHCP renew, network switch and primary-service
  change. The actor watches `State:/Network/Global/DNS`, `Global/IPv4` and the services'
  `Setup:` DNS (`SystemDNS.Watcher`) and re-plans while active: a foreign value on the
  same service becomes the new original and is overridden again; a new primary service
  gets the old one restored and the override moved; no primary service (network down)
  restores and reports `failed`. The daemon's own write triggers a notification too — the
  planner finds everything consistent and does nothing.
- **Manual DNS.** A resolver entered in System Settings lives in
  `Setup:/Network/Service/<id>/DNS` and takes precedence over `State:` in configd's merge.
  The daemon still writes the override (it takes effect the moment the manual entry is
  cleared) and reports `shadowed(manual: [...])`; the app logs a warning saying where to
  clear it. Wayfork never edits `Setup:` — that is the user's persistent configuration.
- **Status.** `RuntimeStatus.resolverOverride`: `off`, `active(service)`,
  `shadowed(manual)`, `failed(reason)`.

The decisions — `write` / `restore` / nothing, and the resulting state — are a pure
function in `WayforkDaemonCore` (`ResolverOverridePlanner.plan`) over a
`ResolverSnapshot` (primary service, its `State:` entry, its `Setup:` servers) and the
saved record; unit-tested. The actor only performs the I/O.

## Developer mode (no app, no launchd)

`WayforkDaemon --dev-apply <plan.json>` runs the same `Supervisor` from a terminal as root:
bootstrap, apply the plan, re-apply whenever the file changes (poll 1 s), print status and
log pushes to stderr, `Ctrl-C` → `stop`. `wayforkctl plan` (executable target in the
`WayforkCore` package) builds such a plan from `.ovpn` files / `vless://` URIs and
`--rule pattern=tunnel` arguments. The plan file contains secrets: keep it root-only and
delete it afterwards. This is how M2 is verified before the app exists.

## Files written by the daemon

| File | Mode | Note |
|------|------|------|
| `run/sing-box.json` | 0600 | contains VLESS UUIDs and REALITY keys → root-only; written as `sing-box.json.check`, promoted by `rename` after `sing-box check` passes |
| `run/rules-t-<id>.json` | 0600 | rewritten in place via temp file + `rename` so sing-box's watcher sees one change |
| `run/rules-direct.json`, `run/rules-t-<id>-ip.json`, `run/rules-direct-ip.json` | 0600 | Direct exceptions (F8) and IP rule-sets (F11); same rewrite |
| `run/t-<id>.ovpn` | 0600 | contains private keys |
| `run/t-<id>.sock` | 0600 | management socket |
| `run/*.pid` | 0600 | |
| `run/cache.db` | 0600 | sing-box cache |
| `run/dns-override.json` | 0600 | the primary service's DNS entry before the override (F12); survives `stop`'s wipe until restored |
| `/Library/Logs/Wayfork/daemon.log` | 0600 | daemon's own log (also `os_log`, subsystem `com.wayfork.daemon`) |
| `/Library/Logs/Wayfork/<source>.log` | 0600 | raw child output (`sing-box.log`, `openvpn-<id>.log`), 5 × 1 MB rotation, one `<ISO-8601> <LEVEL> <message>` per line |

Everything under `run/` except `cache.db` (and `dns-override.json`, which its own restore deletes) is deleted on `stop`.

## Logging plumbing

Child stdout/stderr → line reader → `LogLine` (source `sing-box` / `openvpn:<id>`, level
parsed from the line: sing-box prefixes `INFO`/`WARN`/`ERROR`/`DEBUG`, openvpn management
`>LOG` flags `I`/`W`/`F`/`N`/`D`) → ring buffer of the last 2 000 lines per source (for
reattach) → batched push to the subscribed client. Daemon's own events use source `daemon`.
openvpn prints every line on stdout *and* to management clients with `log on`; stdout is
forwarded only until the management socket is up (that is where `Options error` from a bad
config shows up — openvpn exits before the socket exists). `subscribe` replays the current
status and every ring buffer to the new client.

Redaction at the source: the management client never logs what it writes to the socket;
sing-box's `log.level` is capped at `info` in the generated config unless the user picks
`debug`, in which case the UI warns that debug logs may include hostnames.
