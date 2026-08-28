# 08 — Windows

Deltas of the Windows client against [00](00-architecture.md)–[06](06-logging.md), section
by section; anything not mentioned here applies unchanged. Roadmap:
[ROADMAP-windows.md](../ROADMAP-windows.md). The sections below are the W2b design,
written from the W2a spike results (§ Spike); each cites the spike rows it rests on.

Pinned versions come from [scripts/versions.env](../../scripts/versions.env):
sing-box **1.13.19**, OpenVPN **2.7.6**.

## Components and trust boundary

Same shape as macOS ([00-architecture.md](00-architecture.md)): an unprivileged **app**
(Flutter) and a privileged **service** (Go, running as `LocalSystem`). The macOS
`WayforkDaemonCore` / `WayforkCore` split is mirrored as a Go `service` package (pure
reconcile logic, unit-tested) under a thin `svc` host, and a Dart `core` layer under the
UI; the plan and status types are the shared contract ([ROADMAP-windows.md](../ROADMAP-windows.md) WM0).

- The service runs as `LocalSystem` (needs to create adapters, write routes and NRPT).
  It starts at boot **idle** (`SERVICE_AUTO_START`, or delayed-auto) and does nothing until
  the app connects and sends a plan.
- Children (`sing-box.exe`, `openvpn.exe`) are spawned by the service **detached** and
  placed in a **job object** with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` so they die with the
  service no matter how it exits (S8; the Windows replacement for pid files). Detached start
  is mandatory: a child that inherits the console dies with the launching session (learned
  repeatedly in the spike — `Start-Process` from an SSH session, `PsExec -d` is the fix).
- **Trust boundary.** The named pipe is the app→service channel (see IPC). The service
  accepts a client only after `GetNamedPipeClientProcessId` → the client image path →
  Authenticode signature check against our publisher + the path being inside
  `%ProgramFiles%\Wayfork\` (the counterpart of the macOS `setCodeSigningRequirement` Team-ID
  check). It executes only the two binaries shipped next to itself, path derived from its own
  module path, never from the client; each binary's Authenticode signature is validated
  before every spawn. Config *contents* (not paths) cross the pipe and the service writes
  them into a root-only directory. `openvpn` runs with `--script-security 1`; dangerous
  directives are stripped at import (as on macOS, [04-tunnels.md](04-tunnels.md)). Secrets
  (OpenVPN bodies, credentials, key passphrases, VLESS UUIDs) live in **DPAPI-protected**
  app storage and cross the pipe at apply, held in service memory; OpenVPN credentials go in
  over the management socket, never to disk.

## Filesystem layout

| Path | Owner | Contents |
|------|-------|----------|
| `%LOCALAPPDATA%\Wayfork\store.json` | user | tunnels, rules, settings — no secrets |
| `%LOCALAPPDATA%\Wayfork\secrets.dat` | user | DPAPI-encrypted (CurrentUser) OpenVPN bodies, credentials, passphrases, VLESS UUIDs — the Keychain stand-in |
| `%LOCALAPPDATA%\Wayfork\logs\` | user | app log + mirrored runtime logs ([06-logging.md](06-logging.md)) |
| `%ProgramData%\Wayfork\run\` | `LocalSystem`, ACL `SYSTEM`+`Administrators` only | `sing-box.json`, `rules-*.json`, `t-<id>.ovpn`, `cache.db`, `dns-override.json`, `*.pid`-equivalents |
| `%ProgramData%\Wayfork\logs\` | `LocalSystem`, same ACL | service log, raw child stdout/stderr (rotated) |
| `%ProgramFiles%\Wayfork\` | TrustedInstaller (MSI) | `wayfork.exe` (app), `wayfork-service.exe`, `bin\sing-box.exe`, `bin\openvpn.exe` + `tapctl.exe` + its DLLs (`libcrypto-3-x64`, `libssl-3-x64`, `libpkcs11-helper-1`, `vcruntime140`), `drivers\ovpn-dco\` (`.inf`/`.sys`/`.cat`) — the set `scripts/fetch-win-bins.ps1` produces |

`run\` is wiped on stop except `cache.db` (fake-ip mappings must survive restarts) and
`dns-override.json` (its own restore deletes it). The ACL matters: `%ProgramData%` is
world-readable by default, so `run\` and `logs\` get an explicit DACL that drops `Users`
(the config carries VLESS keys). Management sockets are **TCP on loopback**, not files
(Windows OpenVPN management is TCP-only) — see IPC.

## IPC

A **named pipe** `\\.\pipe\wayfork` replaces the macOS XPC/Unix socket. Newline-delimited
JSON, one request or event per line; the same logical messages as XPC
([05-daemon.md](05-daemon.md)): `getInfo`, `getStatus`, `subscribe`, `apply(plan)`, `stop`,
`reconnect(id)`, `collectDiagnostics`, plus a version handshake as the first exchange
(`getInfo` returns the plan-format version; a mismatch is a hard error surfaced in the UI).
The pipe is created by the service with a DACL granting `SYSTEM`+`Administrators` full
control and authenticated users connect-only; the client-verification check above runs on
every accept. Reconnect: the app dials with a short backoff and re-`subscribe`s; the
service keeps running the current plan across app restarts (it only reacts to `apply`/`stop`).

The **runtime plan** is the macOS `RuntimePlan` verbatim in spirit — desired-state, not
imperative — with two field changes: `OpenVPNRuntime.interface` carries the **adapter name**
(`"Wayfork-1"`), not a `utun` unit, and the plan gains `overrideSystemDNS: bool` (already on
macOS) whose Windows mechanism is NRPT (see Resolver override); `DaemonInfo.bundlePath`
becomes `installPath` (`%ProgramFiles%\Wayfork`) and `buildID` carries the service
executable's Authenticode hash. The reconcile algorithm
(diff OpenVPN by `id`+`configHash`+verb; sing-box by `configHash` / rule-set contents;
concurrent start) is unchanged. As on macOS, `bind_interface` is resolved lazily at dial
time — confirmed on Windows: with the adapter present but no route, the dial fails
per-connection (`WSAENETUNREACH`) rather than at startup (S4a).

## Adapters

Names, not indices. sing-box's TUN is **`Wayfork`** (`interface_name`, sing-tun embeds
wintun); each OpenVPN tunnel gets a pre-created adapter **`Wayfork-1` … `Wayfork-32`**.

- **Creation.** The service runs `tapctl create --name Wayfork-N --hwid ovpn-dco` once per
  configured tunnel (idempotent: `tapctl` refuses a duplicate name, exit 1 — treat as
  "already there"). Adapters persist across reboots with a **stable name and GUID** but an
  **unstable `ifIndex`** (S2.4: 17→3 across a reboot). Everything therefore keys on the
  **name** (and re-reads GUID/LUID when a handle is needed); `ifIndex` is never cached.
- **Driver.** Two drivers appear in practice: `ovpn-dco` (default, best perf) and
  `tap-windows6` as the fallback OpenVPN picks when a profile enables compression
  (`Note: '--allow-compression' is not set to 'no', disabling data channel offload` → the
  tunnel comes up on `TAP-Windows Adapter V9`, S7). `bind_interface` works on **both**, so
  this is not a blocker, but the importer normalises compression off to keep dco, and the
  adapter code must not assume the `ovpn-dco` hwid — it addresses by name and reads whatever
  driver `tapctl list` reports.
- **The address is set by OpenVPN**, via `netsh interface ip set address <ifIndex> static …
  store=active` (S3d) — the service does not assign it. The dco adapter's on-link routes
  appear **asynchronously** a moment after `CONNECTED`, so the service must not snapshot the
  adapter's routes immediately on the CONNECTED event.
- **Removal / stray cleanup.** Adapters not named `Wayfork-*` with hwid `ovpn-dco` are stray
  and deleted. On uninstall (and only then) adapters are removed with `tapctl delete` — see
  Installer for the ordering trap.

## Routes

The Windows replacement for macOS `route -ifscope` ([04-tunnels.md](04-tunnels.md)). Two
independent route facts came out of the spike:

- **sing-box TUN default.** sing-tun does **not** add a `0.0.0.0/0` on `Wayfork`; with
  `auto_route` it lays down ~53 inverse `/n` routes (the complement of `route_exclude_address`)
  at interface metric 0 and pins the TUN's interface metric to 0. `Find-NetRoute 9.9.9.9`
  resolves to `Wayfork` and the physical NIC keeps the real `0.0.0.0/0`. Nothing for the
  service to add here; it just verifies the TUN came up.
- **Per-tunnel scoped default (the go/no-go, S4 = GO).** `bind_interface: Wayfork-N` alone is
  not enough: `IP_UNICAST_IF` still needs a route to pick a next hop, so a bound socket to an
  adapter with only OpenVPN's on-link routes fails `WSAENETUNREACH` (S4a). After `CONNECTED`
  the service adds, per tunnel:

  ```
  New-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceAlias Wayfork-N \
    -NextHop <route-gateway from PUSH_REPLY> -RouteMetric 9999 -PolicyStore ActiveStore
  ```

  (Go: `CreateIpForwardEntry2` with the adapter LUID, next hop = the pushed `route-gateway`,
  metric 9999, no persistence.) The pushed-gateway shape worked first try for both tunnels
  (t1 `10.8.0.1`, t2 `192.168.35.1`); the on-link `0.0.0.0/0 → 0.0.0.0` fallback was not
  needed. Windows ranks routes by **`RouteMetric + InterfaceMetric`**; the dco/TAP interface
  metric is 25, so the effective cost is 9999+25 — far above the metric-0 TUN and the
  metric-15 NIC, so the scoped default can only ever be chosen by a socket already bound to
  `Wayfork-N`. Proven end-to-end: `jira.sccloud.ru` exited through `Wayfork-2` with HTTP 200
  while `Find-NetRoute 9.9.9.9` still pointed at the TUN and direct traffic kept the home IP
  (S4b/S4c). `route-gateway` is parsed from the `PUSH_REPLY` line the same way macOS discovers
  pushed DNS ([04-tunnels.md](04-tunnels.md)); it survives even under `--route-nopull`.
- **`--route-nopull` noise.** Each pushed `route` logs `Options error: option 'route' cannot
  be used in this context ([PUSH-OPTIONS])` (3–5 per connect). Benign; the log parser
  whitelists it and never treats a `PUSH-OPTIONS` `Options error` as fatal.
- **Table cleanup at start.** These `ActiveStore` routes **survive the child's death** (S7):
  after a force-kill the `0.0.0.0/0` metric-9999 routes and the on-link `/24` are still in the
  table on the (now `Disconnected`) `Wayfork-N`. The service deletes every `0.0.0.0/0` on
  `Wayfork-*` (and stale `Manual` addresses) at start — or, equivalently, deletes and
  recreates the adapters, which clears both.

## Resolver override

**Mechanism: NRPT, not per-adapter DNS.** This is the crux of F12 on Windows and the spike
tested both. Setting the physical adapter's DNS server to the TUN resolver
(`Set-DnsClientServerAddress`) **leaks**: Windows sends the query for an adapter's configured
resolver **out of that adapter to its gateway**, regardless of the routing table — the exact
Windows twin of the macOS `State:`-DNS `if_index` scoping trap ([05-daemon.md](05-daemon.md)).
The canary `probe.wayfork.internal` still appeared on the wire to the router (S6b). It is
ruled out.

A single **NRPT catch-all** is airtight (S6c, re-confirmed on the full fake-ip config):

```
Add-DnsClientNrptRule -Namespace "." -NameServers 172.19.0.2
```

`Get-DnsClientNrptPolicy -Effective` then routes **every** name to `172.19.0.2` (the TUN
resolver, an address of the carved /30 that `hijack-dns` answers) before the per-adapter
resolvers are consulted, so no query reaches the LAN router (**0** canary packets on the NIC).
It applies to `getaddrinfo` users (curl, ping) and `Resolve-DnsName` alike; `nslookup` bypasses
NRPT (talks to the adapter server directly) but no application path does. It holds across a
Wi-Fi↔Ethernet switch **without re-applying** (S6d) — sing-box re-binds its own upstream
sockets via `auto_detect_interface` — so unlike the leaky per-adapter scheme there is nothing
to chase on an interface change. DoH auto-upgrade does not bypass it on stock Windows 11
(`172.19.0.2` is not a known DoH template, S6e). This is `172.19.0.2` = the TUN resolver
(address+1), the analogue of the macOS choice to use the carve-out address rather than the
TUN's own address.

- **Record & restore.** Before the first write the effective NRPT state is saved to
  `run\dns-override.json`; restore removes Wayfork's rule (`Remove-DnsClientNrptRule`). NRPT is
  **persistent** and survives both process death and reboot (S7), and with sing-box gone
  `172.19.0.2` answers nothing — resolution is dead (`curl` → `Resolving timed out`). So, like
  the macOS daemon's bootstrap restore, the service **removes/restores NRPT at start before
  anything else**, restores on every non-`running` engine state, and restores on `stop` before
  `run\` is wiped. If Wayfork is removed while On, the rule lingers — the uninstaller must
  delete it (Installer), and the README documents the manual `Remove-DnsClientNrptRule` as the
  Windows twin of the macOS "clear DNS" note.
- **Probe.** After activation the service resolves `probe.wayfork.internal` through
  `getaddrinfo` and repeats every 300 ms until it answers `172.19.0.2` (sing-box's `predefined`
  rule, TTL 0); no answer within 5 s backs the override out and reports `failed` — identical to
  macOS, so a wrong resolver path costs 5 s, not the user's network.
- **Planner.** The write/restore/nothing decision stays a pure function in the Go `service`
  core over an NRPT snapshot + the saved record, unit-tested; the I/O lives in a thin actor.

## Lifecycle

As on macOS ([00-architecture.md](00-architecture.md)): the service starts at boot **idle**,
the app connects over the pipe and sends a plan, `app quit stops everything` (the app sends
`stop`; if the app vanishes the tunnels keep running until an explicit `stop` — the service is
the source of truth, same as macOS). Service `stop` restores networking (NRPT first, then
routes/adapters) before wiping `run\`. Boot sequence, in order: **restore a leftover NRPT
record**, delete stray `Wayfork-*` routes/addresses/adapters, then idle. The engine state
machine (`stopped`/`starting`/`running`/`failed` with crash backoff) and the resolver-override
lifecycle are the macOS ones. `reconnect(id)` restarts one OpenVPN child (which re-opens its
adapter and re-adds its scoped route). MSI upgrade stops the service, replaces files, restarts
it (see Installer).

## Logging

Paths per the Filesystem table: the service writes its own log + raw child stdout/stderr under
`%ProgramData%\Wayfork\logs\` (`sing-box.log`, `openvpn-<id>.log`), 5×1 MB rotation, one
`<ISO-8601> <LEVEL> <message>` per line, mirrored to the app under `%LOCALAPPDATA%` for the Logs
window ([06-logging.md](06-logging.md)). Windows specifics: OpenVPN is launched with
`--suppress-timestamps --machine-readable-output` so its lines carry the epoch+flags the parser
already expects; the management dialogue is TCP (loopback) and echoes each `>STATE:` twice when
`log on` is set (a `>LOG:…,,MANAGEMENT: >STATE:…` copy of every `>STATE:`) — the parser
de-duplicates. Diagnostics zip adds Windows-only items: `Get-NetRoute`/`Get-NetAdapter`/
`Get-DnsClientNrptPolicy -Effective` dumps and `tapctl list`, the counterparts of the macOS
`scutil`/`netstat` captures.

## Installer

WiX (MSI). Contents: `%ProgramFiles%\Wayfork\` payload, the service registered via a WiX
`ServiceInstall`/`ServiceControl` (start delayed-auto), the app + Start-menu shortcut, and the
**bundled `ovpn-dco` driver**.

- **Driver install without the OpenVPN MSI.** `msiexec /a` of the OpenVPN MSI yields **no**
  driver files (S0, confirmed for the amd64 MSI in WM0), but the package *is* inside the MSI:
  the embedded `openvpn.cab` carries two `ovpn-dco` builds (File-table directories
  `OpenVPN\Common Files\ovpn-dco\Win10` = NetAdapterCx 2.0 and `Win11` = 2.1, both
  2.8.4.0). `scripts/fetch-win-bins.ps1` reads the cabinet through the `WindowsInstaller`
  COM object, expands it, maps the `nx21` members via the File table and verifies each file
  against `scripts/versions.env` — so no OpenVPN install is needed to build. The `Win11`
  package is what ships in `drivers\ovpn-dco\`. Install is
  `pnputil /add-driver ovpn-dco.inf /install` (a WiX custom action, or `DifxApp`-free): silent,
  **no reboot**, WHQL/attestation-signed (S2.2). The signature is checked before install.
- **Uninstall ordering (trap).** Delete adapters **first**, then the driver:
  `tapctl delete Wayfork-*` for every adapter, then `pnputil /delete-driver <oemNN.inf>
  /uninstall`. Reversed, `/uninstall` leaves the root devnodes (`ROOT\NET\000N`) as driverless
  devices and the next `add-driver` re-binds them as `Local Area Connection N` with **new GUIDs
  and the Wayfork names lost** (S2.2). Uninstall also **removes the NRPT rule** and deletes the
  `Wayfork` service; it keeps user data under `%LOCALAPPDATA%`.
- **Upgrade** stops the service (`ServiceControl` stop) so the binaries are unlocked, replaces
  the payload, and restarts it; the driver is re-published only if the pinned version changed.
- After a `pnputil` driver re-install OpenVPN reports `ovpn-dco-win driver is missing` until a
  reboot (spike gotcha) — so the installer never re-publishes the driver on a normal upgrade,
  only on a version bump, and the version bump path schedules a reboot.

## Repository layout (WM0)

`WayforkWindows/app` (Flutter, `fluent_ui`, `lib/core` mirrors WayforkCore file by file),
`WayforkWindows/service` (Go module `wayfork/service`: `internal/core` pure and tested on
every OS, `internal/winnet` = Win32 behind `//go:build windows`, `cmd/wayfork-service`,
`cmd/wayforkctl`), `WayforkWindows/versions.env` (Flutter/Dart/Go pins), fetched binaries in
`WayforkWindows/bin/<arch>` and `drivers/<arch>/ovpn-dco` (git-ignored). Shared
`fixtures/` (see its README): `singbox/<variant>/input.json` + golden outputs, `ovpn/`,
`vless/links.json`, `clash/connections.json`; the Swift tests read them from there and
regenerate with `WAYFORK_UPDATE_GOLDEN=1`. The Windows runner under `app/windows/` was
rendered from Flutter's `app/windows.tmpl` (`flutter create --platforms=windows` refuses to
emit it on macOS); `generated_plugin_registrant.*` and `generated_plugins.cmake` are written
by `flutter pub get` on Windows. CI: `.github/workflows/ci-windows.yml` (windows-latest,
Flutter + Go jobs) runs on `WayforkWindows/**`, `fixtures/**`, `scripts/**`; `ci.yml` ignores
the mirror set.

## Dart core (WM1)

`app/lib/core` mirrors `WayforkCore` file by file (`model/`, `store/`, `secrets/`, `rules/`,
`openvpn/`, `vless/`, `singbox/`, `plan/`, `ipc/`, `diagnostics/`, `support/`) and is tested
against `fixtures/` from `test/core/`. The deltas from the Swift core, all deliberate:

- **Platform object.** `WayforkPlatform` (`windows` / `macOS`) carries what differs in the
  generated artefacts: the TUN name (`Wayfork` vs `utun100`), the OpenVPN interface names
  (`Wayfork-N` vs `utun<101+slot>`), the bundled `openvpn` path (`<install>\bin\openvpn.exe`)
  and application-rule handling. The generators take it as an input: the golden tests replay
  `fixtures/singbox/*/input.json` with `macOS` and must match byte for byte, `sing-box check`
  runs on the `windows` output.
- **JSON.** `JsonText` reproduces Foundation's `JSONSerialization` pretty/sorted output
  (case-insensitive key order, `"key" : value`, empty containers spread over three lines, `/`
  unescaped, lowercase `\u00xx`) so `sing-box.json`, the rule-sets, `store.json` and
  `wayfork-export.json` stay byte-identical across the clients. UUIDs are held lowercase and
  written uppercase like Swift's `UUID.uuidString`; dates are whole-second ISO 8601 UTC.
- **App rules (F10).** The pattern is an absolute `.exe` path (drive letter or UNC, `file:`
  URLs accepted, `/` becomes `\`, must end in `.exe`, no `.`/`..` components, case kept); the
  rule-set emits `process_path_regex` `(?i)^<escaped path>$` — one executable, case-insensitive
  because sing-box reports the on-disk case (S3a). macOS bundles keep `^<path>/`.
- **Importer.** On top of the macOS strip list ([04-tunnels.md](04-tunnels.md)) the Windows
  importer drops `comp-lzo`, `compress`, `comp-noadapt`, `allow-compression` (compression
  framing forces the TAP fallback, see Adapters) and the Windows-only `windows-driver`,
  `ip-win32`, `dhcp-renew`, `dhcp-release`, `register-dns`, `tap-sleep`, `route-method`,
  `pause-exit`, `show-net-up`; all of them are reported in `strippedDirectives`. NFC
  normalisation of rule patterns is not applied (the Dart SDK has no normaliser).
- **Secrets.** `SecretStore` over `%LOCALAPPDATA%\Wayfork\secrets.dat`: compact JSON
  `{"version":1,"items":{"tunnel/<id>/<kind>":"<base64 DPAPI blob>"}}`, one
  `CryptProtectData` blob per secret (`CRYPTPROTECT_UI_FORBIDDEN`, current user), decrypted
  only on read; the accounts (`tunnel/<id>/{ovpn,credentials,keyPassphrase,uuid}`) and the
  orphan cleanup are the Keychain ones. The Win32 backend compiles everywhere and is exercised
  on Windows only (WM3); the tests use a fake protector.
- **IPC types.** `RuntimePlan`, `RuntimeStatus` and the other payloads keep the Swift
  `Codable` wire form (`{"case":{…}}` for enums with payloads, `{"case":{}}` without) so the Go
  service implements one contract; `DaemonInfo.installPath` replaces `bundlePath`.
- **Host resolution.** `HostResolver.resolveIPv4` drops answers inside the fake-IP range
  (`198.18.0.0/15`): a lookup made while Wayfork is already On may get sing-box's fake answer
  for a server name that is not yet in the config, which must not end up in the direct
  `ip_cidr` rule. *(The macOS core does not filter yet — worth back-porting.)*
- **Win32 halves (landed in WM3a):** `LocalNetwork.current()` and `SystemDns.snapshot()`
  are built on `WindowsAdapters.enumerate()` (`GetAdaptersAddresses`, IPv4 only, gateways
  included) — see "Flutter app (WM3)" below; the pure halves (`SystemDnsSnapshot.routable`,
  `coversLocalNetwork`, `LocalNetwork.fromAdapters`, `SystemDns.fromAdapters`) are tested
  everywhere.

## Go core (WM2, `service/internal/core`)

`internal/core` mirrors `WayforkDaemonCore` file by file (plan/status wire types, validator,
run layout, argv, backoff, line splitter, management protocol, failure codes, session
reducer, reconcile planner, resolver-override planner, Clash API, traffic accumulator,
sing-box log parsing, log rings, rule-set selectors, rotating log, atomic file) and is
tested everywhere against `fixtures/`. The deltas from the Swift daemon core:

- **Wire encoding.** The Swift `Codable` shapes are reproduced with custom JSON: enum
  cases as `{"case":{…}}`, sorted keys, whole-second UTC timestamps, `{}`/`[]` for empty
  collections. Go's `json.Marshal` HTML-escapes `<>&` even inside a `MarshalJSON` result, so
  the IPC layer encodes top-level payloads with `core.MarshalWire` (no escaping) — the
  pinned literals in the Dart `ipc_test.dart` are shared with the Go tests, and the
  two-tunnels `planHash` / OpenVPN `configHash` are pinned against values the Dart core
  computed. The zero values of `EngineState` / `ResolverOverrideState` encode as `stopped` /
  `off`.
- **Run layout.** No sockets and no pid files: management is TCP on loopback with a
  password file `t-<id>.mgmt` (transient, next to `t-<id>.ovpn`), children live in the job
  object. `cache.db` and `dns-override.json` survive `stop` as on macOS.
- **argv.** `--dev-node <Wayfork-N>` selects the pre-created adapter; `--management
  127.0.0.1 <port> <run>\t-<id>.mgmt`; `--persist-key` and `--max-routes` dropped
  (DEPRECATED in 2.7); the rest as on macOS, `--dns-updown disable` included.
- **Management protocol.** The socket client answers the `ENTER PASSWORD:` prompt (no
  newline; `IsManagementPasswordPrompt`) before reporting the channel up, so the reducer is
  unchanged there. With `log on` OpenVPN echoes every `>STATE:` as `MANAGEMENT: >STATE:…`
  and every command as `MANAGEMENT: CMD '…'` (verb 3, `D` flag, `username` arguments
  verbatim): both become `EventEcho` and are dropped — that is the de-duplication and what
  keeps usernames out of the log ring. `PushedRouteGateway` reads `route-gateway` from the
  logged `PUSH_REPLY` (fallback: the net30 `ifconfig` peer).
- **Child stdout.** `--machine-readable-output` prints `<epoch>.<micros> <flags-hex>
  <message>` (OpenVPN `error.c`; the timestamp ignores `--suppress-timestamps`), the flags
  being the `M_FATAL`/`M_NONFATAL`/`M_WARN`/`M_DEBUG` bitmask (`0x10`/`0x20`/`0x40`/`0x80`).
  `ParseOutputLine` maps them to the `>LOG` letters. *(The macOS `OpenVPNOutput.parse`
  expects letters and never matches a real line — back-port candidate.)*
- **Adapter check.** OpenVPN `init.c` logs `"%s device [%s] opened"` with the backend
  driver — `ovpn-dco device [Wayfork-1] opened` (spike S3c) or `tap-windows6 device
  [Wayfork-2] opened` — the replacement for `Opened utun device utunN`; a mismatch with
  the planned adapter is `ovpn.configError`. A soft restart logs `Preserving previous
  TUN/TAP instance` instead (no check).
- **Reducer.** `AddScopedRoute{Interface, Gateway}` on `CONNECTED` carries the pushed
  gateway (empty = on-link fallback plus a warning); exits carry a code, not a signal.
  `Options error … ([PUSH-OPTIONS])` is whitelisted in the fatal classifier.
- **Resolver-override planner.** Over an NRPT snapshot instead of SCPreferences: the
  service's rule is `Namespace "."` + `Comment "Wayfork"` (a stale address is still ours);
  consistent → nothing; ours missing/stale/duplicated → `Restore` then `Write`; a foreign
  `"."` rule → `failed` and ours removed (two catch-alls have no defined precedence);
  inactive → `Restore` of whatever is there (rule and/or record). `run\dns-override.json` =
  `{version, address, rules}`; the state reports `active(service: "NRPT")`.
- **Rule-set selectors / Clash API / traffic** are straight ports (Go `regexp` is RE2 like
  sing-box; `ip_cidr` also accepts a bare host). `InjectClashAPI` re-encodes with
  `encoding/json` (sorted keys, two-space indent, `UseNumber`), a different pretty-print than
  Foundation's but only sing-box reads that file.

## Service shell (WM2, `service/internal/{service,ipc,winnet,winproc}`, `cmd/`)

The macOS daemon's wiring (`Wayfork/Daemon/`) ported with one structural change: the
orchestration is a cross-platform package over small I/O interfaces, so it is unit-tested
on every platform with fakes; only the interface implementations touch Win32.

- **`internal/service`** — `Supervisor` (bootstrap, serialized apply/stop/reconnect with
  latest-wins, status, diagnostics; implements `ipc.Handler`), `SingBoxEngine` (write
  rule-sets, `sing-box check` on an injected copy, start with startup verification —
  `Wayfork` adapter up and `1.1.1.1` routing through it — crash counter/backoff, connection
  cut after a rule-set rewrite), `OpenVPNSession` (process + management client feeding the
  core reducer; effects performed in order), `ManagementClient` (TCP, answers the
  `ENTER PASSWORD:` prompt before reporting the channel up), `ResolverOverride` (NRPT
  planner + record + `probe.wayfork.internal` probe with the 5 s back-out), `TrafficSampler`
  / `ConnectionCloser` (loopback `net/http`, no proxy), `Hub` (rings, rotating raw logs,
  100 ms status coalescing, 250 ms / 200-line log batches, replay on subscribe). The I/O
  interfaces: `ProcessRunner` / `Process`, `Network`, `Resolver`, `BinaryValidator`. The
  tests drive a fake OpenVPN management server over real TCP (password prompt, hold,
  PUSH_REPLY with `route-gateway`, CONNECTED, SIGTERM → EXITING) and check the scoped
  route, discovered DNS, NRPT rule, run\ wipe and the log stream end to end.
- **`internal/ipc`** — the pipe protocol, cross-platform: one JSON object per line,
  requests `{"id","method","params"}`, replies `{"id","result"|"error"}`, pushes
  `{"event","data"}`; the first line is `{"event":"hello","data":{"protocol":1,
  "planVersion":1,"version":…}}` (the version handshake). Requests on one connection are
  dispatched concurrently (an `apply` never delays `getStatus`), writes are serialized.
  `pipe_windows.go` implements the listener with `x/sys/windows` alone (`CreateNamedPipe`
  with the SDDL `D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)`, blocking `ConnectNamedPipe`,
  `GetNamedPipeClientProcessId`); no extra dependency. `Client` serves `wayforkctl`.
- **`internal/winnet`** — adapters via `tapctl create --name Wayfork-N --hwid ovpn-dco`
  (a duplicate counts as present; adapters of tunnels absent from the plan are kept — a
  foreign dco adapter such as the OpenVPN GUI's is never touched), routes via `winipcfg`
  (`LUID.AddRoute(0.0.0.0/0, <gateway>, 9999)` in the active store; startup cleanup deletes
  every `0.0.0.0/0` on `Wayfork-*` and flushes their IPv4 addresses), route lookup by
  longest prefix + `RouteMetric+InterfaceMetric` over `GetIpForwardTable2`, NRPT via the
  PowerShell cmdlets the spike used (`Get/Add/Remove-DnsClientNrptRule`, arguments
  validated by pattern before interpolation), the probe via Go's resolver (`GetAddrInfoW`
  on Windows, NRPT-aware), diagnostics dumps (`Get-NetRoute`, `Get-NetAdapter`,
  `Get-DnsClientNrptPolicy -Effective`, `tapctl list`), `WinVerifyTrust` for the binaries
  and the client image (any valid Authenticode chain + inside `%ProgramFiles%\Wayfork` —
  publisher pinning is owed with the signing setup), and the run\/logs\ DACL.
- **`internal/winproc`** — children via `os/exec` with `CREATE_NO_WINDOW`, assigned to one
  job object with `KILL_ON_JOB_CLOSE` right after start; `Terminate(timeout)` waits then
  kills (sing-box gets 500 ms — no graceful stop when detached, the TUN goes with the
  process; OpenVPN gets `signal SIGTERM` over management, then 5 s).
- **`cmd/wayfork-service`** — the `svc` host (start idle, `Bootstrap`, pipe accept loop
  with client verification, event-log mirror of warnings/errors, stop → `Shutdown`), and
  `--dev-apply <plan.json>` (console, no trust checks, plan re-applied on change, pipe
  served for `wayforkctl`). `DaemonInfo.buildID` is the SHA-256 of the executable.
- **`cmd/wayforkctl`** — `info | status | stop | diagnostics | apply <plan> | reconnect
  <id> | watch`, and `plan --config sing-box.json --rules <dir> --ovpn
  <id>=<adapter>:<file>[:<user>:<password>][:passphrase=<p>] -o plan.json` to assemble a
  plan from files the Dart core generated (the profile is taken as is — the importer's
  stripping is the app's job).

**Verified in the `wf-win` VM (2026-08-28)** via `wayfork-service --dev-apply` on a plan the
Dart core built from the maintainer's real export (sing-box TUN + one VLESS + two OpenVPN on
`ovpn-dco`, adapters `Wayfork-2`/`Wayfork-3`):

- `wayforkctl plan` reproduced the Dart core's plan hash byte-for-byte (`dd7a0a6830f5…`),
  including every OpenVPN `configHash` — the Go and Dart plan builders agree on the wire.
- Startup cleanup restored a stale NRPT rule **and** a `Wayfork-*` scoped default route left
  by a prior crash before re-applying (`system resolver left overridden by a previous service;
  restoring`); teardown on `wayforkctl stop` removed the NRPT rule and the 9999 route, wiped
  `run\` down to `cache.db`, and DNS/routing came back (verified with a live lookup + `curl`).
- NRPT override + the `probe.wayfork.internal` check, the scoped `0.0.0.0/0 → route-gateway`
  metric-9999 route on the dco adapter, `tapctl create` (new `Wayfork-3`) and its duplicate
  wording (`Adapter "Wayfork-2" already exists (GUID …).`, exit 1 — the `already` substring
  the `EnsureAdapters` guard matches), t1 CONNECTED with a private-key passphrase prompt, the
  benign `[PUSH-OPTIONS]` route warnings, per-tunnel + Direct traffic rates, `collectDiagnostics`
  (~64 KB), `wayforkctl info/status/stop/reconnect`, and a **rule-set hot reload** — a rule-set
  edit re-applied as `rewriteRuleSets` (`os.Rename` over the file sing-box watches, no restart:
  the sing-box PID was unchanged and `run\rules-direct.json` picked up the edit).
- **Fix that landed:** the named pipe now opens with `FILE_FLAG_OVERLAPPED` on both ends
  (`pipe_windows.go`). A synchronous pipe handle makes `os.File` run blocking `ReadFile`/
  `WriteFile`, so a read waiting for the next request held the write lock and every
  `wayforkctl` call hung; overlapped handles route through Go's runtime poller so reads and
  writes proceed independently. `ConnectNamedPipe` now takes an event-backed `OVERLAPPED`
  (cancelled on `Close` via `CancelIoEx`), and `DialPipe` retries `ERROR_PIPE_BUSY`.

Still not exercised (skipped by `--dev-apply` or owed to a later milestone): the real `svc`
SCM handler and its event-log source (WM3/WM4, needs the installed service), `WinVerifyTrust`
on binaries and the client image (dev mode skips trust checks — WM4 with a signed install),
sing-box crash-restart counting (no crash injected), the resolver re-apply on an adapter
change, and the on-link route fallback when no `route-gateway` is pushed (both real servers
pushed one, so `CreateIpForwardEntry2` used an explicit next-hop and needed no retry).

## Flutter app (WM3)

`app/lib` above the core mirrors the macOS app layer by layer. Landed so far (WM3a — the
pure app core, the service client and the Win32 halves; everything runs and is tested on
macOS except the three live lookups, which return empty off Windows):

- **`core/app/`** ports `WayforkCore/App` one file per Swift counterpart: `GlobalState` +
  `GlobalStateDerivation` (the tray state machine, 30 s `starting` grace), `StatusText`
  (summary line, tunnel cards and rows, `count`), `TrafficFormat` (decimal units, fixed
  digits, stale label), `RuleEditing` + `QuickAdd` (rule normalisation, duplicate check,
  clipboard candidate), `StoreImporter` / `StoreExporter` (Replace/Merge, slot reassignment,
  name collisions, F8 default, secrets map keyed by `SecretKey`) and `LogLineFormat` +
  `AppLogFile` (the `<ISO-8601 ms> <source> <LEVEL> <message>` line, size rotation to
  `<name>-<yyyyMMdd-HHmmss>.log`, retention prune). Deltas: the error catalogue drops
  `helper.notApproved` (no Login Items step on Windows) and maps `helper.versionMismatch` /
  `helper.unreachable` to one `FailureAction.repairInstallation` ("Repair the
  installation") instead of "reinstall helper"; the app-rule message reads "Choose an
  application (.exe)"; interface names in card details are the adapter names
  (`10.8.0.6 on Wayfork-1`). `AppLogFile` sets no POSIX permissions — `%LOCALAPPDATA%` is
  private by its inherited ACL.
- **Service client (`core/ipc/`).** `ServiceTransport` is a byte stream + `write` +
  `close`; `ServiceConnection` speaks the pipe protocol over it (NDJSON framing with the
  64 MB line cap, the `hello` as the first event with a 5 s timeout, request/reply matched
  by `id`, `error` strings become `ServiceException(remote)`, events fan out on broadcast
  streams, unknown events are ignored, a pending call is rejected when the transport ends).
  `ServiceClient` is the reconnecting wrapper the model talks to: phases `connecting` →
  `connected` / `serviceMissing` (pipe absent → "repair installation") / `versionMismatch`
  (hello `protocol` ≠ 1 or `planVersion` ≠ `RuntimePlan.currentVersion`; the client keeps
  re-dialing every `backoff.max` so an upgrade picks up) / `disconnected`; it subscribes
  after every successful hello, forwards `statusChanged` / `logLines` / `trafficChanged`,
  and re-dials with a 0.5 s → 5 s doubling backoff (`retryNow()` skips the wait). Calls
  while not connected fail with `ServiceException(notConnected)` as a Future error.
  Tests drive it through an in-memory transport pair against a fake service that
  implements the Go handler contract (`test/core/ipc/service_client_test.dart`).
- **Named pipe transport (`NamedPipeTransport`).** `CreateFile` on `\\.\pipe\wayfork` with
  `FILE_FLAG_OVERLAPPED` — the client-side twin of the WM2 fix: a synchronous handle would
  serialise the pending read against every write. Reads run in a helper isolate
  (`ReadFile` + `GetOverlappedResult(wait)` on their own event, chunks posted to the main
  isolate); writes complete on the caller's isolate, serialised so frames never interleave;
  `close()` = `CancelIoEx` → wait for the reader to exit → `CloseHandle`.
  `ERROR_FILE_NOT_FOUND` → `ServiceUnavailableException` (the `serviceMissing` phase);
  `ERROR_PIPE_BUSY` is retried for 2 s. `dart:io`'s `File` was not used: it opens the pipe
  synchronously and would deadlock the same way.
- **Win32 halves (`core/support/windows_adapters.dart`).** `WindowsAdapters.enumerate()`
  walks `GetAdaptersAddresses(AF_INET, SKIP_ANYCAST|SKIP_MULTICAST|INCLUDE_GATEWAYS)` into
  `WindowsAdapter` (GUID, friendly name, ifIndex, ifType, oper status, `Ipv4Metric`,
  unicast addresses with on-link prefix length, IPv4 resolvers, IPv4 gateways).
  `LocalNetwork.current()` keeps adapters that are up, not loopback (`IF_TYPE` 24), not
  tunnel (131) and not ours (`Wayfork`, `Wayfork-N`), with `0 < prefix < 32` and outside
  169.254/16 — the F11 "covers your LAN" check. `SystemDns.snapshot()` picks the **primary
  adapter** = physical, up, has an IPv4 gateway, lowest `Ipv4Metric` (the counterpart of
  macOS `PrimaryService`); `servers` = its resolvers, `router` = its first gateway,
  `manualServers` / `networkServers` come from the adapter's Tcpip registry key
  (`HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\<GUID>`:
  `NameServer` = manual, `DhcpNameServer` = DHCP; DHCP entries count only while no manual
  entry overrides them). Because the override is NRPT, the adapter lists are never rewritten
  while On, and the Wayfork adapters never qualify as primary, so a snapshot taken while On
  still describes the underlying network. The DPAPI backend (`DpapiProtector`) is unchanged
  from WM1.
- **Verified in the VM (2026-08-28, `wf-win`, arm64, Dart SDK 3.12.2 running the core as a
  plain Dart package against `wayfork-service --dev-apply` idling on a missing plan):**
  `GetAdaptersAddresses` enumeration (Ethernet + the spike's dormant `Wayfork-1/2` and
  TAP adapters, loopback), primary = Ethernet with `DhcpNameServer` from the registry,
  `LocalNetwork.current()` = the LAN /24 only, `SystemDns.snapshot()` (resolver = the
  router, so `routable()` is empty — the macOS rule), DPAPI protect/unprotect +
  `secrets.dat` round-trip through a fresh store (no plain text on disk); named pipe:
  `ServiceUnavailableException` without a service, hello/getInfo/getStatus/subscribe (the
  status push arrives right after `subscribe`), collectDiagnostics, three concurrent calls
  on one connection in ~1 ms, `reconnect` of an unknown id → `tunnelNotFound`;
  `ServiceClient` survives `taskkill` + restart of the service (`connected` →
  `disconnected` → `serviceMissing`… → `connected`, re-subscribed, calls in between fail
  with `notConnected`). Two bugs fixed by the run: `close()` awaited
  `StreamController.close()` on a stream nobody had listened to (never completes), and a
  `close()` racing a freshly spawned reader isolate found no I/O to cancel and sat out the
  2 s reader timeout — the reader now reports ready before its first `ReadFile` and
  `close()` repeats `CancelIoEx` until the reader exits (first close ≈ 110 ms = isolate
  spawn, later ones 0 ms). The VM keeps the Dart SDK under `C:\wf\dart` and the probe
  under `C:\wf\probe` (snapshot `s3-dart`) for the next sub-steps.

WM3b — the app model, the apply pipeline and the service states, still without UI
(`app/lib/app/`, tested on macOS against the fake service of
`test/core/ipc/fake_service.dart` plus in-memory store/secret fakes):

- **`AppModel` (`app/model/app_model.dart` + `_tunnels` / `_rules` /
  `_import_export` parts)** is the macOS `AppModel` as a `ChangeNotifier` over
  `StoreStorage` (the new interface `StoreRepository` implements), `SecretStore`,
  `ServiceClient`, `LogCenter`, `Notifier` and `LaunchAtLogin`: store, settings, runtime
  status, traffic (stale after 3 s), `desiredOn`, `AppTransition`, `missingSecrets`,
  `persistenceDisabled`, the derived `GlobalState` and `summary`, tunnels CRUD
  (`addOpenVPN` / `replaceOpenVPNConfig` from a parsed result — the picker and the
  missing-files loop are UI, `addVLESS`, credentials / key passphrase / DNS, rename,
  enable, `deleteTunnel` after the UI confirms with `deleteTunnelMessage`), rules CRUD
  (quick add, add at the end of the group, update, move before / to the end, note,
  enable, remove, fake-IP translation from the sing-box log), default tunnel (F8),
  `exportDocument` / `decodeImport` / `performImport`. What macOS shows from the model
  (`NSAlert`, window opening) is state here: `alerts` (`AppAlert` with an optional
  `AppAction` button, dismissed by the UI) and the `actions` stream (`openTunnel` with a
  field to focus, `showLogs`, `exportDiagnostics`, `repairInstallation`, `revealFile`).
- **Apply pipeline.** Every `update` persists (debounced by the repository), recomputes
  the missing secrets when tunnels changed, follows the log level and — while on —
  schedules an apply (300 ms debounce; secret writes call `secretsChanged()` too).
  `applyNow` = `PlanSecrets.load` → `HostResolver.resolveIPv4` (injected, real DNS in
  the app) → `SystemDns.snapshot()` (injected) → `RuntimePlanBuilder.build` with the
  service's `installPath` as the install dir (fallback: next to the app executable) →
  `ServiceClient.apply`; unresolved servers, gateway resolvers and skipped tunnels are
  logged as on macOS, an `ApplyResult` error becomes an alert with the catalogue's
  follow-up (`configInvalid` → Export Diagnostics, `startFailed` → Show Log,
  `binaryUntrusted` → repair). Applies are serialised; a request during an apply queues
  exactly one more run. The macOS `SystemDNS.Watcher` has no Win32 twin yet: the model
  takes an optional `networkChanges` stream and re-applies from `systemDNSChanged()` only
  when the effective resolvers or the gateway differ from the applied snapshot
  (`NotifyIpInterfaceChange` / polling is a WM3c item).
- **Service states.** The model mirrors `ServiceClient.states`: on `connected` it runs
  `getInfo` + `getStatus`, logs a version difference, and — while `desiredOn` — re-applies
  when the service is idle (a restarted service) or reports a `planHash` other than
  `lastPlan`'s; a service already running the current plan is left alone. The first
  attach after launch adopts a running service (`desiredOn = true`, "reattached"). On
  `disconnected` / `serviceMissing` / `versionMismatch` status, info and traffic are
  cleared; `desiredOn` survives so routing resumes when the service is back.
  `ServiceIssue` (from the client phase) carries the message and the hint — "Repair the
  installation" for missing / mismatch, "Reconnecting…" for a lost connection — and takes
  over `summary` when it needs repair or the user wants routing on. Turn On waits up to
  10 s for the connection and fails with the repair alert when the service is missing or
  incompatible; Turn Off waits for an in-flight apply before `stop`.
- **`LogCenter` (`app/services/log_center.dart`)** is the macOS one: a 10 000-line ring
  (trimmed in 1000-line chunks), `minimumLevel` from the settings, the service replay
  de-duplicated by (ts, source, message), `wayfork.log` / `runtime.log` mirrors through
  `AppLogFile` under `%LOCALAPPDATA%\Wayfork\logs` (the runtime tail is loaded at start),
  `prune` at launch, daily and when the retention changes. **`Notifier`** is an interface
  with a console backend (toasts come with WM3c); the model posts for permanent tunnel
  failures, engine failures — once per state change, opt-out via
  `notifyOnTunnelFailure`. **`LaunchAtLogin`** is an interface with an in-memory backend;
  the `HKCU\…\Run` implementation is WM3c. `WayforkVersion.app` pins the app version
  (kept in step with `pubspec.yaml`) for the connect-time comparison.
- Deltas from macOS: no helper approval flow (nothing to register — the service is
  installed by the MSI), so `helper.*` collapses into `ServiceIssue` and the repair
  action; `update` takes a `Store → Store` function (immutable models); the resolver
  override log line names the mechanism (`via NRPT`); `deleteTunnel` does not confirm
  itself.

## Open items

- **t1/pilot-gps user flow (not a Windows issue) — resolved 2026-08-27.** In S5 the
  `jira.pilot-gps.com` flow failed (`Connection reset` / `context deadline exceeded`) while the
  identical mechanism carried `jira.sccloud.ru`. Root: the fake-ip → `direct` outbound
  **connect-time re-resolution**; the spike template only had `default_domain_resolver:
  dns-direct`, which returned the real IP for sccloud's private `192.168.42.75` but not for
  pilot's public `185.147.81.35` (a host the tunnel pushes a `/32` for). The production
  generator (macOS and the Dart port alike) gives every OpenVPN outbound its own
  `domain_resolver` — `dns-t-<id>`, the tunnel's resolver detoured through the tunnel — so a
  VPN-only name is re-resolved where it exists; the Dart test
  `OpenVPN outbounds resolve through their own tunnel DNS` pins this shape.
- **OpenVPN WFP block filters** *(verify)*. OpenVPN adds per-connect WFP filters on CONNECTED
  (`WFP Block: Added block filters for all interfaces` / `… for DNS traffic to loopback`, seen
  in the WM2 VM run). After a graceful `wayforkctl stop` DNS and routing came back cleanly
  (live lookup + `curl` succeeded), so the filters do not outlive a clean teardown; a
  `netsh wfp` scan tagged 0 filters to the OpenVPN provider (they live under a different
  sublayer). Still unconfirmed: whether a **force-kill** leaves them behind — if it can, add a
  WFP sweep to start-up cleanup.
- **t2 (`Office_afosteev_most`) fails on `ovpn-dco` — server-side.** In WM2 the sanitized
  profile keeps `ovpn-dco` (the Dart importer strips `comp-lzo`), and t2 loops
  `server-pushed-connection-reset` → `process-push-msg-failed` on every `PUSH_REPLY`, ending in
  a permanent `ovpn.authFailed` (no credentials are configured, so this is the server rejecting
  the session, not a client bug). t1 (same mechanism, same dco driver) CONNECTs in ~4 s and
  VLESS carries traffic, so the shell is sound. The spike already saw t2 fall back to
  `tap-windows6` **because its profile had `comp-lzo no`** — with compression stripped for dco,
  the server's pushed options are what dco can't apply. This is the maintainer's own Office
  server; not a Wayfork blocker. If dco parity matters for it later, the importer could keep
  `tap-windows6` for a profile whose server insists on compression (a per-tunnel driver hint).
  Still worth confirming once on a cooperative server: that a transient reconnect re-adds the
  scoped route (the `reconnect` path deletes then re-adds it — exercised, but t1 re-CONNECT
  after `reconnect` was not observed to completion in the VM window).
- **amd64 re-check** owed in WM5: the whole spike ran on ARM64; re-run S0–S8 on x64 with the
  x64 sing-box/OpenVPN/`ovpn-dco` artefacts before shipping.

---

## Spike (W2a)

Manual runbook for the feasibility spike on a Windows 11 machine. The maintainer runs it;
every item ends with a yes/no and a note in the results table at the end. A "no" changes
the design (the sections above), not the roadmap. Nothing here touches the macOS build or a
running Wayfork.

Conventions:

- All commands are PowerShell in an **elevated** window (Run as administrator) unless the
  step says `psexec -s`. In PowerShell `curl` is an alias for `Invoke-WebRequest` — always
  type `curl.exe`.
- Working tree: `C:\wf\` (`sb\` for sing-box and its run directory, `ovpn\` for OpenVPN).
  Nothing is installed system-wide except the drivers in S2.
- Placeholders follow [examples/](../../examples/): `<VLESS_SERVER>`, `<VLESS_UUID>`,
  `<VLESS_SNI>`, `<REALITY_PUBLIC_KEY>`, `<REALITY_SHORT_ID>`, `<OVPN1_SERVER>`,
  `<OVPN2_SERVER>`, `<OVPN1_DNS>` (the DNS the first OpenVPN server pushes, or `1.1.1.1`
  if it pushes none), `<LAN_DNS>` (the router / DHCP resolver, `ipconfig /all`), `<NIC>`
  (the physical adapter's name as `Get-NetAdapter` prints it, e.g. `Wi-Fi` or `Ethernet`).
- Exit checks use services that echo the caller's address: `ipinfo.io/ip` (direct),
  `api.ipify.org` (OpenVPN 1), `icanhazip.com` (OpenVPN 2), `ifconfig.me` (VLESS). Note
  the expected exit addresses once (the tunnel servers' public IPs) before starting.
- Record = paste the command output into the results table or a text file next to it
  (`C:\wf\results\<step>.txt`); the table cell says which output.

### Spike environment (2026-08-27)

The spike runs in a **Parallels Desktop VM** on the maintainer's Apple Silicon Mac, not on
a physical PC, and is driven over SSH from the macOS session (`ssh wf-win`, key-only,
PowerShell 5.1 as the default shell; the maintainer only handles secrets and anything that
needs the console).

- Guest: Windows 11 **ARM64** (26200.x), 4 vCPU, 8 GB, user `fost` (Administrators),
  `C:\wf\` with a Defender exclusion. `prlctl exec` from the host runs commands in the
  guest as SYSTEM — used for bootstrap and available as a second channel if sshd is lost.
- Network: both virtual NICs **bridged** over the host's Wi-Fi (Parallels *Shared* would NAT
  the guest through the host's stack, i.e. through the host's own Wayfork TUN, and the
  results would be meaningless). `Ethernet` (`192.168.31.203`) is the primary; `Ethernet 2`
  is left `Disabled` and exists for S6d (enable it and disable `Ethernet` instead of
  swapping a cable). Verified before the spike: first hop `192.168.31.1`, DNS from the
  router, real (non-198.18.x) answers.
- Snapshot `clean` taken before S0; revert it instead of cleaning up by hand after S7.
- **arm64, not amd64.** Every artefact below has an arm64 twin — use it in the VM:
  `sing-box-1.13.19-windows-arm64.zip`, `OpenVPN-2.7.6-I001-arm64.msi` (same directory as
  the amd64 files). OS-level semantics (routes, `IP_UNICAST_IF`, NRPT, multi-homed DNS, job
  objects, driver install flow) are what the spike decides and they do not depend on the
  architecture; the amd64 drivers and binaries get their own confirmation on a physical
  machine in WM5. Record the architecture in the results table header.
- `Disable-NetAdapter` is a PnP disable: after a reboot the adapter shows `Not Present`
  (problem code 22) and `Enable-NetAdapter` no longer sees it — bring it back with
  `Enable-PnpDevice -InstanceId <id>`. Harness detail; the product never disables NICs.
- Long-running children (sing-box, openvpn) are started through `PsExec64.exe -s -d` (or
  another parent that is not the SSH session): a process started with `Start-Process` from
  an SSH session is attached to that session's console and dies when the session ends
  (found in S1a). The service will own its children anyway (S8), so this is a harness
  detail, not a product one.
- Windows firewall: the network is set to *Private* and the sshd rule to all profiles; an
  ICMPv4 echo allow rule (`Wayfork spike ICMPv4-In`) exists so the host can ping the guest.
  Neither is part of the product.

### Facts checked upstream before the spike (2026-08-27)

So that the runbook does not guess. Sources: sing-box / sing-tun / sing sources on GitHub
at the pinned version's `main`, OpenVPN `Changes.rst` and sources at `master`,
`openvpn-build/windows-msi/msi.wxs`, `build.openvpn.net/downloads/releases/`.

- **sing-box Windows build embeds wintun.** `sing-tun/internal/wintun` carries the DLL
  per architecture and loads it from memory (`memmod.LoadLibrary`); the release zip has no
  `wintun.dll` and none is needed next to `sing-box.exe`. (The ROADMAP WM0 line about
  fetching `wintun.dll` from wintun.net is corrected accordingly.)
- **sing-tun on Windows with `auto_route`:** creates the wintun adapter named
  `interface_name` with a GUID derived from that name, sets the adapter's DNS server to
  the address after the TUN address (`172.19.0.1/30` → `172.19.0.2`, unless the TUN option
  `dns_address` says otherwise), sets the interface metric to 0, adds the auto routes,
  flushes the resolver cache. WFP filters (including a "block port 53 elsewhere" rule
  when `dns_mode` is `hijack`, the default) are added **only** with `strict_route: true`;
  Wayfork runs `strict_route: false`, so no WFP involvement. `stack: system` has a
  Windows implementation (`stack_system_windows.go`). `bind_interface` is implemented
  with `IP_UNICAST_IF` on the interface index looked up by *name* — the adapter's friendly
  name as `Get-NetAdapter` shows it. `process_path` / `find_process` are supported on
  Windows.
- **TUN `address` vs `inet4_address`:** the golden config already uses `address`;
  `inet4_address` was merged into it in 1.10 and is gone since 1.12. Do not use it.
- **OpenVPN 2.7:** "Support for wintun Windows driver has been removed." The
  `--windows-driver` option "will no longer do anything — it's kept so existing configs
  will not become invalid, but it is ignored with a warning. The default is now `ovpn-dco`
  if all options used are compatible with DCO, with a fallback to `tap-windows6`." To
  force TAP: `--disable-dco`. So the drivers to consider are **ovpn-dco** (primary) and
  **tap-windows6** (fallback); wintun is off the table. S2 verifies this against the
  actual binary.
- **`tapctl` (2.7):** `tapctl create [--name <name>] [--hwid <hwid>]`, `tapctl list
  [--hwid <hwid>]`, `tapctl delete <adapter GUID | adapter name>`. Default `--hwid` is
  `ovpn-dco`; tap-windows6 is `root\tap0901` (or `tap0901`). A requested name that already
  exists — as an adapter or as a leftover registry name — is refused with `Adapter "…"
  already exists` / `Adapter name "…" is already in use`; tapctl never appends a suffix
  itself. Names must not contain `\ / : * ? " < > |` or tabs.
- **`--dev-node` on Windows** selects the adapter "which is named `node` in the Network
  Connections Control Panel or the raw GUID of the adapter enclosed by braces";
  `--show-adapters` lists them. A driver mismatch is fatal:
  `Adapter '<name>' is using <driver> driver, <driver> expected.` where driver is
  `ovpn-dco` or `tap-windows6`.
- **`--dns-updown`** is parsed on every platform (`options.c`, outside the `_WIN32`
  block), so `--dns-updown disable` should be accepted on Windows; S3 confirms.
- **Management interface on Windows is TCP only** (`unix` needs `UNIX_SOCK_SUPPORT`):
  `--management 127.0.0.1 <port> [<password-file>]`.
- **The Darwin `Opened utun device utunN` line does not exist on Windows.** The Windows
  `open_tun` logs `open_tun`, then driver-specific lines; the adapter is named in messages
  such as `TAP-Windows Driver Version …`, `Set TAP-Windows TUN subnet mode …` or the
  IP-Helper `Succeeded in adding a temporary IP/netmask … to interface {GUID}` line. The
  exact line(s) that carry the adapter *name* (not GUID) for ovpn-dco are what S3 records.
- **OpenVPN MSI:** `OpenVPN-2.7.6-I001-amd64.msi` (also `-arm64`, `-x86`), dated
  2026-08-05, from `https://swupdate.openvpn.org/community/releases/`. The drivers are
  merge modules (`ovpn-dco.msm`, `tap-windows6.msm`) merged into the MSI and installed by
  the `libopenvpnmsica.dll` custom actions (`InstallTUNTAPAdapters`), not by plain file
  copies. `openvpn.exe`, `tapctl.exe`, `openvpnserv.exe` and the DLLs live in
  `OpenVPN\bin\`.
- `OPENVPN_SHA256` in `versions.env` is the source tarball, `SING_BOX_SHA256_*` are the
  macOS builds — the Windows artefact hashes are new and get recorded in S0.

### S0 — Machine preparation

1. **Tools.** Windows 11 with `curl.exe` (built in). PsExec from Sysinternals
   (<https://learn.microsoft.com/sysinternals/downloads/psexec>) unzipped to
   `C:\wf\tools\`. Telnet client for the management interface:
   `Enable-WindowsOptionalFeature -Online -FeatureName TelnetClient` (or use the
   PowerShell reader in S3). Wireshark is optional — `pktmon` (built in) covers the DNS
   leak test.
2. **Layout.**

   ```powershell
   New-Item -ItemType Directory -Force C:\wf\sb, C:\wf\ovpn, C:\wf\ovpn-msi, C:\wf\tools, C:\wf\results | Out-Null
   ```

3. **sing-box.**

   ```powershell
   $v = '1.13.19'
   curl.exe -L -o C:\wf\sing-box.zip "https://github.com/SagerNet/sing-box/releases/download/v$v/sing-box-$v-windows-amd64.zip"
   Get-FileHash C:\wf\sing-box.zip -Algorithm SHA256 | Format-List      # record
   Expand-Archive C:\wf\sing-box.zip -DestinationPath C:\wf\ -Force
   Copy-Item "C:\wf\sing-box-$v-windows-amd64\sing-box.exe" C:\wf\sb\
   Unblock-File C:\wf\sb\sing-box.exe
   C:\wf\sb\sing-box.exe version                                          # record
   ```

   Record whether the zip contains anything besides `sing-box.exe` and `LICENSE` (it is
   not expected to contain `wintun.dll`; if it does, note it — it is still not required).

4. **OpenVPN, extracted from the MSI without installing.**

   ```powershell
   curl.exe -L -o C:\wf\OpenVPN-2.7.6-I001-amd64.msi https://swupdate.openvpn.org/community/releases/OpenVPN-2.7.6-I001-amd64.msi
   Get-FileHash C:\wf\OpenVPN-2.7.6-I001-amd64.msi -Algorithm SHA256 | Format-List   # record
   Start-Process msiexec.exe -Wait -ArgumentList '/a', 'C:\wf\OpenVPN-2.7.6-I001-amd64.msi', '/qn', 'TARGETDIR=C:\wf\ovpn-msi'
   Get-ChildItem C:\wf\ovpn-msi -Recurse -File | Select-Object FullName, Length | Out-File C:\wf\results\s0-msi-tree.txt
   Get-ChildItem C:\wf\ovpn-msi -Recurse -Include *.inf, *.sys, *.cat, *.msm            # record
   Copy-Item "C:\wf\ovpn-msi\OpenVPN\bin\*" C:\wf\ovpn\bin\ -Recurse -Force
   Get-ChildItem C:\wf\ovpn\bin | Unblock-File
   C:\wf\ovpn\bin\openvpn.exe --version                                                   # record
   ```

   If `msiexec /a` lays out no `*.inf` (merge-module files may be absent from an
   administrative image), note it and install the MSI normally on the spike machine
   instead (`msiexec /i … ` with the default features); the drivers then come from that
   install and `C:\Program Files\OpenVPN\bin\` replaces `C:\wf\ovpn\bin\` in every
   command below. Either way, record which path was taken — WM4 needs to know whether the
   Wayfork MSI can carry the driver package on its own.

5. **PsExec sanity.**

   ```powershell
   C:\wf\tools\psexec.exe -accepteula -s cmd /c whoami      # expect: nt authority\system
   ```

6. **Baseline network state** (before anything else, for the restore checks in S6/S7):

   ```powershell
   Get-NetAdapter | Format-Table Name, InterfaceDescription, ifIndex, Status, MacAddress
   Get-NetIPInterface -AddressFamily IPv4 | Format-Table InterfaceAlias, ifIndex, InterfaceMetric, Dhcp, ConnectionState
   Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | Format-Table ifIndex, InterfaceAlias, NextHop, RouteMetric, InterfaceMetric
   Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table InterfaceAlias, InterfaceIndex, ServerAddresses
   netsh interface ipv4 show dnsservers
   Get-DnsClientNrptRule
   Get-DnsClientDohServerAddress
   ipconfig /all
   ```

   Save all of it to `C:\wf\results\s0-baseline.txt`. `netsh … show dnsservers` is the
   one that says whether a resolver is "configured through DHCP" or "statically
   configured" — that distinction is what a restore has to reproduce.

### Configs

Two sing-box configs and the rule-set files, all in `C:\wf\sb\`. Both are the
[two-tunnels golden](../../Wayfork/WayforkCore/Tests/WayforkCoreTests/Golden/two-tunnels/sing-box.json)
adapted for Windows: `interface_name` `Wayfork`, `bind_interface` `Wayfork-N`,
`process_path` of `openvpn.exe`, `dns-direct` named explicitly (the `local` transport
loops under the resolver override, 2026-08-26), a third tunnel (second OpenVPN), a Clash
API block, and per-tunnel test domains in the rule-sets. `route_exclude_address` is the
golden list verbatim.

**`C:\wf\sb\sing-box.min.json`** — TUN only, everything direct (S1):

```json
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-direct", "type": "udp", "server": "<LAN_DNS>" }
    ],
    "rules": [
      {
        "action": "predefined",
        "domain": ["probe.wayfork.internal"],
        "rcode": "NOERROR",
        "answer": ["probe.wayfork.internal. 0 IN A 172.19.0.2"]
      },
      { "action": "reject", "domain": ["_dns.resolver.arpa"] }
    ],
    "final": "dns-direct",
    "strategy": "ipv4_only",
    "independent_cache": true,
    "reverse_mapping": true
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "Wayfork",
      "address": ["172.19.0.1/30"],
      "mtu": 1500,
      "auto_route": true,
      "strict_route": false,
      "stack": "system",
      "route_exclude_address": [
        "10.0.0.0/8", "172.16.0.0/15", "172.18.0.0/16", "172.19.0.4/30", "172.19.0.8/29",
        "172.19.0.16/28", "172.19.0.32/27", "172.19.0.64/26", "172.19.0.128/25",
        "172.19.1.0/24", "172.19.2.0/23", "172.19.4.0/22", "172.19.8.0/21", "172.19.16.0/20",
        "172.19.32.0/19", "172.19.64.0/18", "172.19.128.0/17", "172.20.0.0/14",
        "172.24.0.0/13", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "224.0.0.0/4"
      ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-direct",
    "final": "direct",
    "find_process": true,
    "rules": [
      { "action": "sniff" },
      { "action": "hijack-dns", "protocol": "dns" },
      { "ip_is_private": true, "outbound": "direct" }
    ]
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "cache.db", "store_fakeip": true }
  }
}
```

**`C:\wf\sb\sing-box.json`** — two OpenVPN tunnels + one VLESS (S4–S7). Tunnel ids
follow the golden fixture: `…0001` OpenVPN on `Wayfork-1`, `…0002` VLESS, `…0003` OpenVPN
on `Wayfork-2`.

```json
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-direct", "type": "udp", "server": "<LAN_DNS>" },
      {
        "tag": "dns-t-00000000-0000-4000-8000-000000000001",
        "type": "udp",
        "server": "<OVPN1_DNS>",
        "detour": "t-00000000-0000-4000-8000-000000000001"
      },
      { "tag": "fakeip", "type": "fakeip", "inet4_range": "198.18.0.0/15" }
    ],
    "rules": [
      {
        "action": "predefined",
        "domain": ["probe.wayfork.internal"],
        "rcode": "NOERROR",
        "answer": ["probe.wayfork.internal. 0 IN A 172.19.0.2"]
      },
      { "action": "reject", "domain": ["_dns.resolver.arpa"] },
      { "rule_set": "rules-direct", "server": "dns-direct" },
      { "domain": ["<OVPN1_SERVER>", "<OVPN2_SERVER>"], "server": "dns-direct" },
      {
        "query_type": ["A", "AAAA"],
        "rule_set": [
          "rules-t-00000000-0000-4000-8000-000000000001",
          "rules-t-00000000-0000-4000-8000-000000000002",
          "rules-t-00000000-0000-4000-8000-000000000003"
        ],
        "server": "fakeip"
      }
    ],
    "final": "dns-direct",
    "strategy": "ipv4_only",
    "independent_cache": true,
    "reverse_mapping": true
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "Wayfork",
      "address": ["172.19.0.1/30"],
      "mtu": 1500,
      "auto_route": true,
      "strict_route": false,
      "stack": "system",
      "route_exclude_address": [
        "10.0.0.0/8", "172.16.0.0/15", "172.18.0.0/16", "172.19.0.4/30", "172.19.0.8/29",
        "172.19.0.16/28", "172.19.0.32/27", "172.19.0.64/26", "172.19.0.128/25",
        "172.19.1.0/24", "172.19.2.0/23", "172.19.4.0/22", "172.19.8.0/21", "172.19.16.0/20",
        "172.19.32.0/19", "172.19.64.0/18", "172.19.128.0/17", "172.20.0.0/14",
        "172.24.0.0/13", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "224.0.0.0/4"
      ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    {
      "type": "direct",
      "tag": "t-00000000-0000-4000-8000-000000000001",
      "bind_interface": "Wayfork-1",
      "domain_resolver": {
        "server": "dns-t-00000000-0000-4000-8000-000000000001",
        "strategy": "ipv4_only"
      }
    },
    {
      "type": "vless",
      "tag": "t-00000000-0000-4000-8000-000000000002",
      "server": "<VLESS_SERVER>",
      "server_port": 443,
      "uuid": "<VLESS_UUID>",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "insecure": false,
        "server_name": "<VLESS_SNI>",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "<REALITY_PUBLIC_KEY>",
          "short_id": "<REALITY_SHORT_ID>"
        }
      }
    },
    {
      "type": "direct",
      "tag": "t-00000000-0000-4000-8000-000000000003",
      "bind_interface": "Wayfork-2",
      "domain_resolver": { "server": "dns-direct", "strategy": "ipv4_only" }
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-direct",
    "final": "direct",
    "find_process": true,
    "rule_set": [
      { "type": "local", "format": "source", "tag": "rules-direct", "path": "rules-direct.json" },
      { "type": "local", "format": "source", "tag": "rules-direct-ip", "path": "rules-direct-ip.json" },
      { "type": "local", "format": "source", "tag": "rules-t-00000000-0000-4000-8000-000000000001", "path": "rules-t-00000000-0000-4000-8000-000000000001.json" },
      { "type": "local", "format": "source", "tag": "rules-t-00000000-0000-4000-8000-000000000001-ip", "path": "rules-t-00000000-0000-4000-8000-000000000001-ip.json" },
      { "type": "local", "format": "source", "tag": "rules-t-00000000-0000-4000-8000-000000000002", "path": "rules-t-00000000-0000-4000-8000-000000000002.json" },
      { "type": "local", "format": "source", "tag": "rules-t-00000000-0000-4000-8000-000000000002-ip", "path": "rules-t-00000000-0000-4000-8000-000000000002-ip.json" },
      { "type": "local", "format": "source", "tag": "rules-t-00000000-0000-4000-8000-000000000003", "path": "rules-t-00000000-0000-4000-8000-000000000003.json" },
      { "type": "local", "format": "source", "tag": "rules-t-00000000-0000-4000-8000-000000000003-ip", "path": "rules-t-00000000-0000-4000-8000-000000000003-ip.json" }
    ],
    "rules": [
      { "action": "sniff" },
      { "action": "hijack-dns", "protocol": "dns" },
      { "process_path": ["C:\\wf\\ovpn\\bin\\openvpn.exe"], "outbound": "direct" },
      { "domain": ["<OVPN1_SERVER>", "<OVPN2_SERVER>"], "outbound": "direct" },
      { "rule_set": ["rules-direct", "rules-direct-ip"], "outbound": "direct" },
      {
        "rule_set": ["rules-t-00000000-0000-4000-8000-000000000001", "rules-t-00000000-0000-4000-8000-000000000001-ip"],
        "outbound": "t-00000000-0000-4000-8000-000000000001"
      },
      {
        "rule_set": ["rules-t-00000000-0000-4000-8000-000000000002", "rules-t-00000000-0000-4000-8000-000000000002-ip"],
        "outbound": "t-00000000-0000-4000-8000-000000000002"
      },
      {
        "rule_set": ["rules-t-00000000-0000-4000-8000-000000000003", "rules-t-00000000-0000-4000-8000-000000000003-ip"],
        "outbound": "t-00000000-0000-4000-8000-000000000003"
      },
      { "ip_is_private": true, "outbound": "direct" }
    ]
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "cache.db", "store_fakeip": true },
    "clash_api": { "external_controller": "127.0.0.1:9090", "secret": "spike" }
  }
}
```

If the OpenVPN servers were installed by IP rather than by name, drop the two
`<OVPN*_SERVER>` rules (the `process_path` rule alone must then keep OpenVPN's own
traffic direct — that is part of what S3 checks). If `openvpn.exe` ends up under
`C:\Program Files\OpenVPN\bin\` (S0 fallback), change `process_path` accordingly and
record whether the match is case-sensitive (run once with the path as
`(Get-Process openvpn).Path` prints it, once lower-cased).

**Rule-set files** (`version: 3`, sing-box source format), all in `C:\wf\sb\`:

```powershell
Set-Content C:\wf\sb\rules-direct.json @'
{ "version": 3, "rules": [ { "domain": ["localhost", "ipinfo.io"], "domain_suffix": [".local", ".lan", ".internal", ".home.arpa", ".localhost"] } ] }
'@
Set-Content C:\wf\sb\rules-t-00000000-0000-4000-8000-000000000001.json @'
{ "version": 3, "rules": [ { "domain": ["api.ipify.org"] } ] }
'@
Set-Content C:\wf\sb\rules-t-00000000-0000-4000-8000-000000000002.json @'
{ "version": 3, "rules": [ { "domain": ["ifconfig.me"] } ] }
'@
Set-Content C:\wf\sb\rules-t-00000000-0000-4000-8000-000000000003.json @'
{ "version": 3, "rules": [ { "domain": ["icanhazip.com"] } ] }
'@
foreach ($t in 'direct', 't-00000000-0000-4000-8000-000000000001', 't-00000000-0000-4000-8000-000000000002', 't-00000000-0000-4000-8000-000000000003') {
  Set-Content "C:\wf\sb\rules-$t-ip.json" '{ "version": 3, "rules": [] }'
}
```

**OpenVPN profiles** `C:\wf\ovpn\t1.ovpn`, `C:\wf\ovpn\t2.ovpn`: the real profiles with
the same strip list the macOS importer applies ([04-tunnels.md](04-tunnels.md)): no
`up`/`down`/`route-up`/`dns-updown` scripts, no `dev-node`, no `windows-driver`, no
`block-outside-dns`, no `dhcp-option`, inline `<ca>`/`<cert>`/`<key>`/`<tls-crypt>`
blocks as in [tunnel.example.ovpn](../../examples/tunnel.example.ovpn). `dev tun` stays
(argv overrides it anyway). A profile with `auth-user-pass` is preferable for one of the
two — it exercises the `>PASSWORD:` query path in S3.

**OpenVPN argv** — the macOS list from [04-tunnels.md](04-tunnels.md) with the two
Windows substitutions: the adapter name in `--dev-node`, TCP management instead of the
unix socket. Saved as `C:\wf\ovpn\run-t1.ps1` / `run-t2.ps1` (second one: `t2.ovpn`,
`Wayfork-2`, port `7506`):

```powershell
& C:\wf\ovpn\bin\openvpn.exe `
  --config C:\wf\ovpn\t1.ovpn `
  --dev tun --dev-type tun `
  --dev-node Wayfork-1 `
  --route-nopull `
  --script-security 1 `
  --management 127.0.0.1 7505 `
  --management-hold `
  --management-query-passwords `
  --auth-nocache `
  --auth-retry interact `
  --persist-tun --persist-key `
  --resolv-retry infinite `
  --connect-retry 2 60 `
  --verb 3 `
  --machine-readable-output `
  --suppress-timestamps `
  --dns-updown disable
```

No `--windows-driver` (ignored with a warning in 2.7, see facts above) and no
`--ip-win32` (default `adaptive`; the log shows which method set the address — record
it). If `--dns-updown disable` is rejected on Windows, drop it and record the error
verbatim; `--route-nopull` already discards pushed `dhcp-option DNS`.

### S1 — sing-box TUN

**S1a, as Administrator.**

```powershell
cd C:\wf\sb
.\sing-box.exe check -D C:\wf\sb -c C:\wf\sb\sing-box.min.json     # must print nothing and exit 0
.\sing-box.exe run   -D C:\wf\sb -c C:\wf\sb\sing-box.min.json     # leave running in this window
```

In a second elevated window:

```powershell
Get-NetAdapter -Name Wayfork | Format-List Name, InterfaceDescription, ifIndex, Status
Get-NetIPAddress -InterfaceAlias Wayfork -AddressFamily IPv4 | Format-Table IPAddress, PrefixLength
Get-NetIPInterface -InterfaceAlias Wayfork -AddressFamily IPv4 | Format-Table InterfaceMetric, Dhcp, NlMtu
Get-DnsClientServerAddress -InterfaceAlias Wayfork -AddressFamily IPv4
Get-NetRoute -AddressFamily IPv4 | Where-Object InterfaceAlias -eq Wayfork | Measure-Object | Select-Object Count
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | Format-Table ifIndex, InterfaceAlias, NextHop, RouteMetric, InterfaceMetric
Find-NetRoute -RemoteIPAddress 9.9.9.9 | Select-Object -ExpandProperty InterfaceAlias -First 1
Find-NetRoute -RemoteIPAddress <LAN_DNS> | Select-Object -ExpandProperty InterfaceAlias -First 1
route print -4 | Out-File C:\wf\results\s1a-route.txt
curl.exe -4 -sS --max-time 15 https://ipinfo.io/ip
Resolve-DnsName -Server 172.19.0.2 -Type A probe.wayfork.internal
Resolve-DnsName -Server 172.19.0.2 -Type A example.com
```

- **Yes** = adapter `Wayfork` is `Up` with `172.19.0.1/30`; the `0.0.0.0/0` route with
  the lowest effective metric is on `Wayfork` (`Find-NetRoute 9.9.9.9` → `Wayfork`);
  `<LAN_DNS>` still resolves to `<NIC>` (excluded range); `curl.exe` prints the home IP;
  `probe.wayfork.internal` answers `172.19.0.2` from `172.19.0.2` (proves the resolver
  path into the TUN and `hijack-dns`); the sing-box log shows the `inbound/tun` connection
  lines with `process` names (`find_process` works). `sing-box check` exits 0.
- **No** = any of those fails. Record the failing output and the sing-box log
  (`C:\wf\results\s1a-singbox.log`, copy from the window).
- **Stack check.** If TCP through the TUN fails while DNS (UDP) works, or the log shows
  `system` stack errors, restart with `"stack": "mixed"` and, if needed, `"gvisor"`.
  Record which stack worked; the generator has to emit it on Windows.
- Record: the DNS server sing-box put on `Wayfork` (expected `172.19.0.2`), the interface
  metric (expected `0`), the route count on `Wayfork`, the two `Find-NetRoute` results.

Stop sing-box with Ctrl+C in its window; then record what is left:

```powershell
Get-NetAdapter -IncludeHidden | Where-Object Name -like 'Wayfork*'
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | Format-Table ifIndex, InterfaceAlias, NextHop, RouteMetric
```

**S1b, as SYSTEM in session 0** (the service's situation):

```powershell
C:\wf\tools\psexec.exe -accepteula -s -w C:\wf\sb C:\wf\sb\sing-box.exe run -D C:\wf\sb -c C:\wf\sb\sing-box.min.json
```

Repeat the S1a checks from the user session (second window). **Yes** = identical
results; the adapter is visible and usable from the user session. Record any difference
(adapter creation errors, `Access is denied`, missing routes). Stop with Ctrl+C in the
psexec window and confirm `sing-box.exe` is gone (`Get-Process sing-box`).

### S2 — OpenVPN drivers and named adapters

1. **What the binary supports.**

   ```powershell
   C:\wf\ovpn\bin\openvpn.exe --version | Out-File C:\wf\results\s2-version.txt
   C:\wf\ovpn\bin\openvpn.exe --help | Select-String -Pattern 'windows-driver', 'disable-dco', 'dev-node', 'show-adapters', 'dns-updown'
   C:\wf\ovpn\bin\openvpn.exe --windows-driver wintun --show-adapters
   C:\wf\ovpn\bin\tapctl.exe help create
   ```

   Expected (2.7, per `Changes.rst`): `--windows-driver` prints a warning that it is
   ignored; `--show-adapters` lists adapters with their driver. **Record the exact
   warning text**, and whether `wintun` is mentioned anywhere in `--help` /
   `--show-adapters`. If `--windows-driver wintun` is *accepted without a warning*, the
   pinned build predates the removal — record that and still do not rely on it.

2. **Driver installation** (needed before `tapctl create` can create a dco adapter on a
   machine without OpenVPN installed).

   ```powershell
   $inf = Get-ChildItem C:\wf\ovpn-msi -Recurse -Filter ovpn-dco.inf | Select-Object -First 1 -ExpandProperty FullName
   pnputil /add-driver $inf /install
   pnputil /enum-drivers | Select-String -Context 1,6 'ovpn-dco'
   ```

   **Yes** = `pnputil` reports the package added and installed with no prompt (signed
   driver, no UI). Record the published name (`oemNN.inf`) — the uninstaller needs it —
   and whether a reboot was requested. If there is no `ovpn-dco.inf` in the extracted
   tree (S0 fallback), record that the driver came from the full MSI install.
   tap-windows6 (`OemVista.inf`) the same way only if the dco path fails.

3. **Named adapter.**

   ```powershell
   C:\wf\ovpn\bin\tapctl.exe create --name Wayfork-1 --hwid ovpn-dco      # prints the GUID
   C:\wf\ovpn\bin\tapctl.exe create --name Wayfork-2 --hwid ovpn-dco
   C:\wf\ovpn\bin\tapctl.exe list
   Get-NetAdapter -Name 'Wayfork-*' | Format-Table Name, InterfaceDescription, ifIndex, Status
   C:\wf\ovpn\bin\openvpn.exe --show-adapters
   ```

   **Yes** = both adapters exist with exactly those names (`Get-NetAdapter` `Name` is the
   friendly name sing-box binds to), `Status` `Disconnected` until OpenVPN opens them.
   Record the `tapctl list` output (name, GUID, hwid).

4. **Reboot survival and renaming.** Reboot, then `tapctl list` and `Get-NetAdapter`
   again — **yes** = same names and GUIDs. Then the rename case:

   ```powershell
   C:\wf\ovpn\bin\tapctl.exe create --name Wayfork-1 --hwid ovpn-dco      # expect: already exists
   C:\wf\ovpn\bin\tapctl.exe delete Wayfork-2
   C:\wf\ovpn\bin\tapctl.exe create --name Wayfork-2 --hwid ovpn-dco      # same name after delete
   Get-NetAdapter -IncludeHidden | Where-Object Name -like 'Wayfork*' | Format-Table Name, ifIndex, Status
   Get-PnpDevice -Class Net | Where-Object FriendlyName -like '*Data Channel Offload*' | Format-Table FriendlyName, Status, InstanceId
   ```

   Record: whether the duplicate is refused (expected `Adapter "Wayfork-1" already
   exists`), whether the re-created `Wayfork-2` gets its name back or Windows hands out
   `Wayfork-2 2` / `OpenVPN Data Channel Offload #2` (a ghost in the registry), and
   whether ghost PnP devices (`Status` `Unknown`) accumulate after deletes. This decides
   whether the service can trust `Wayfork-N` names or must reconcile by GUID.

### S3 — OpenVPN with `--route-nopull` under the sing-box TUN

Start sing-box with the full config (`sing-box.json`) — with only one OpenVPN running,
the other outbound's adapter simply has no link yet:

```powershell
cd C:\wf\sb; .\sing-box.exe check -D C:\wf\sb -c C:\wf\sb\sing-box.json; .\sing-box.exe run -D C:\wf\sb -c C:\wf\sb\sing-box.json
```

Second window: `C:\wf\ovpn\run-t1.ps1 | Tee-Object C:\wf\results\s3-openvpn-t1.log`.
Third window, management client:

```
telnet 127.0.0.1 7505
state on
log on
bytecount 5
hold release
```

(PowerShell fallback that reads only — enough to see the events, not to answer a
password query:
`$c=[Net.Sockets.TcpClient]::new('127.0.0.1',7505);$s=$c.GetStream();$w=[IO.StreamWriter]::new($s);$w.AutoFlush=$true;$r=[IO.StreamReader]::new($s);'state on','log on','hold release'|%{$w.WriteLine($_)};while(($l=$r.ReadLine()) -ne $null){$l}`.)

**Yes** =

- OpenVPN reaches `>STATE:…,CONNECTED,SUCCESS,<local ip>,<remote ip>,…` while the TUN is
  up: its own UDP/TCP to `<OVPN1_SERVER>` went direct (the `process_path` rule). The
  sing-box log should show that flow as `outbound/direct` with
  `process=C:\wf\ovpn\bin\openvpn.exe` (or whatever it prints — record the exact
  `process` field format). If OpenVPN hangs in `WAIT`/`RESOLVE`, the rule did not match:
  try the lower-cased path, then `process_name: ["openvpn.exe"]`, and record what worked.
- The management dialogue matches [04-tunnels.md](04-tunnels.md): `>HOLD:Waiting for hold
  release`, `>STATE:` transitions, `>LOG:` lines, `>PASSWORD:Need 'Auth'
  username/password` for the credential profile (answer with `username "Auth" <u>` /
  `password "Auth" <p>` in telnet). Record any line whose wording differs from the macOS
  table.
- `PUSH_REPLY` in the `>LOG:` stream carries `dhcp-option DNS <ip>` and/or
  `route-gateway <ip>` (needed for S4). Record both values.
- `--dns-updown disable` accepted (or the exact rejection).

**Record the adapter line.** The macOS daemon matches `Opened utun device utunN`. Grep the
OpenVPN log for the adapter name and GUID:

```powershell
Select-String -Path C:\wf\results\s3-openvpn-t1.log -Pattern 'Wayfork-1', 'open_tun', 'ovpn-dco', 'TAP-Windows', 'IP Helper', 'netsh', '\{[0-9A-F-]{36}\}'
```

Paste every matching line into the table (`S3c`). The Go management parser needs one
line that (a) appears once per open and (b) carries the adapter *name* so a `--dev-node`
mismatch can be detected as on macOS; if only the GUID appears, note that the service
will have to map GUID → name via `tapctl list` / `Get-NetAdapter`.

Also record, for the design of the interface address handling: the line that shows how
the address was set (`… using the Win32 IP Helper API` vs `netsh …`), and
`Get-NetIPAddress -InterfaceAlias Wayfork-1` afterwards.

### S4 — `bind_interface` on Windows (go / no-go)

Keep S3 running (sing-box + OpenVPN 1 connected on `Wayfork-1`). Nothing has added a
route on `Wayfork-1` except what OpenVPN itself did:

```powershell
Get-NetRoute -AddressFamily IPv4 | Where-Object InterfaceAlias -eq 'Wayfork-1' | Format-Table DestinationPrefix, NextHop, RouteMetric, InterfaceMetric, Store
Get-NetIPInterface -InterfaceAlias Wayfork-1 -AddressFamily IPv4 | Format-Table InterfaceMetric, ConnectionState
```

Record it (`S4a-routes-before`). Then the test itself:

```powershell
curl.exe -4 -sS --max-time 15 https://api.ipify.org       # rule-set of tunnel 1
curl.exe -4 -sS --max-time 15 https://ipinfo.io/ip         # direct, control
```

- **S4a yes** = `api.ipify.org` prints OpenVPN 1's exit address with no extra route.
  Windows honoured `IP_UNICAST_IF` with only the on-link route OpenVPN's `ifconfig` left.
- **S4a no** = timeout / sing-box log says `dial tcp … : network is unreachable` (or
  `WSAENETUNREACH`, `A socket operation was attempted to an unreachable network`) for
  `outbound/t-…0001`. Record the exact error, then try the smallest route that helps:

  ```powershell
  # 1) proper gateway from PUSH_REPLY route-gateway (or the server-side ifconfig address)
  New-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceAlias Wayfork-1 -NextHop <OVPN1_GATEWAY> -RouteMetric 9999 -PolicyStore ActiveStore
  # 2) if (1) is refused (next hop not on-link): on-link default
  New-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceAlias Wayfork-1 -NextHop 0.0.0.0 -RouteMetric 9999 -PolicyStore ActiveStore
  ```

  `-PolicyStore ActiveStore` keeps it out of the persistent store, which is what the
  service wants (nothing survives a reboot). `route add 0.0.0.0 mask 0.0.0.0 <gw> metric
  9999 if <ifIndex>` is the equivalent without the cmdlet. Repeat the two `curl.exe`
  calls after each attempt. **S4b yes** = the tunnel domain exits through OpenVPN 1 with
  the 9999 route in place.

- **S4c — the system default is undisturbed.** With the route added:

  ```powershell
  Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Format-Table ifIndex, InterfaceAlias, NextHop, RouteMetric, InterfaceMetric
  Find-NetRoute -RemoteIPAddress 9.9.9.9 | Select-Object -ExpandProperty InterfaceAlias -First 1    # expect Wayfork (the TUN)
  curl.exe -4 -sS --max-time 15 https://ipinfo.io/ip                                                # still the home IP
  Resolve-DnsName -Type A example.com | Select-Object -First 1                                       # still answers
  ```

  **Yes** = `Find-NetRoute` still picks `Wayfork`, direct traffic and DNS are unaffected.
  Windows ranks routes by `RouteMetric + InterfaceMetric`; sing-tun pinned the TUN's
  interface metric to 0, so the 9999 route can only ever be chosen by a socket bound to
  `Wayfork-1`. Record the sorted table.

- Cleanup: `Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceAlias Wayfork-1 -Confirm:$false`.

This is the go/no-go item. Go = S4a **or** S4b yes together with S4c yes. No-go =
neither route shape makes `bind_interface` leave through the tunnel, or it cannot be done
without stealing the system default; then the Windows design needs a different exit
mechanism (e.g. policy routing per outbound via `default_interface` per tunnel is not
available — this would be a real design change, not a note).

### S5 — Two OpenVPN tunnels + one VLESS

With sing-box (full config) running and S4's route shape applied to `Wayfork-1`, start
OpenVPN 2 (`run-t2.ps1`, port 7506) and apply the same route shape to `Wayfork-2`. Then:

```powershell
curl.exe -4 -sS --max-time 15 https://ipinfo.io/ip        # direct    → home IP
curl.exe -4 -sS --max-time 15 https://api.ipify.org       # OpenVPN 1 → server 1 exit
curl.exe -4 -sS --max-time 15 https://icanhazip.com       # OpenVPN 2 → server 2 exit
curl.exe -4 -sS --max-time 15 https://ifconfig.me         # VLESS     → VLESS exit
Resolve-DnsName -Type A api.ipify.org | Select-Object -First 1    # expect a 198.18.x.x fake IP once the resolver override is on (S6); a real IP before
curl.exe -s -H "Authorization: Bearer spike" http://127.0.0.1:9090/connections | Out-File C:\wf\results\s5-connections.json
```

**Yes** = four different, correct exit addresses; `/connections` lists the four flows
with `metadata.host` set to the domain and `chains[0]` equal to the outbound tag
(`direct`, `t-…0001`, `t-…0003`, `t-…0002`). Record the four addresses and the
`chains` / `metadata.host` / `metadata.processPath` fields of one connection per
outbound.

Also record: both OpenVPN processes connected at once (no adapter or port clash), and
the sing-box log line for the UDP DNS query to `<OVPN1_DNS>` via
`dns-t-…0001` (`detour` through `bind_interface` — UDP is the other half of S4).

### S6 — DNS: leaks, per-adapter override, NRPT

Everything from S5 stays up. The physical adapter `<NIC>` still points at the router.
Capture plain DNS leaving the physical NIC while resolving:

```powershell
# capture (built-in pktmon; syntax verified on 26200: `pktmon list` gives the NIC's component id)
pktmon stop | Out-Null; pktmon filter remove | Out-Null
pktmon filter add dns -t UDP -p 53
pktmon start --capture --comp <NIC component id> --pkt-size 0 --file-name C:\wf\results\s6-<case>.etl
Clear-DnsClientCache
Resolve-DnsName -Type A probe.wayfork.internal
Resolve-DnsName -Type A example.com
curl.exe -4 -sS --max-time 15 https://api.ipify.org
pktmon stop
pktmon etl2txt  C:\wf\results\s6-<case>.etl -o C:\wf\results\s6-<case>.txt
pktmon etl2pcap C:\wf\results\s6-<case>.etl -o C:\wf\results\s6-<case>.pcapng   # (not "etl2pcapng")
```

**Leak criterion.** "Any UDP/53 on `<NIC>`" is *not* it: sing-box's own `dns-direct`
upstream queries leave through `<NIC>` to `<LAN_DNS>` by design (its sockets are bound to
the physical NIC). The canary is `probe.wayfork.internal`: sing-box answers it from the
`predefined` rule and never forwards it, so that name on the wire towards `<LAN_DNS>`
can only have come from the Windows resolver going around the TUN = leak. Count the
wire-format name (`\x05probe\x07wayfork\x08internal`) in the pcapng, and read
`Resolve-DnsName probe.wayfork.internal` (no `-Server`): `172.19.0.2` means the system
resolver reached the TUN, NXDOMAIN / no answer means the router answered first. Wireshark
alternative: capture on `<NIC>` with `dns.qry.name == "probe.wayfork.internal"`.

**S6a — no override (baseline).** Run the capture. Expected: leaks — Windows queries the
resolvers of all adapters in parallel, `<NIC>`'s router included, and the first answer
wins (and it wins races against the TUN). Record: whether `probe.wayfork.internal`
resolved, whether `api.ipify.org` came back as a fake IP or a real one, and the packet
count on `<NIC>`.

**S6b — per-adapter override** (the macOS mechanism, on the physical adapter):

```powershell
Set-DnsClientServerAddress -InterfaceAlias '<NIC>' -ServerAddresses 172.19.0.2
Clear-DnsClientCache
Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table InterfaceAlias, ServerAddresses
```

Run the capture again. **Yes** = zero UDP/53 packets on `<NIC>` to anything but
`172.19.0.2`; `probe.wayfork.internal` → `172.19.0.2`; tunnel domains resolve to
`198.18.x.x`; all four `curl.exe` exits from S5 still correct; `curl.exe -v` to a
Direct-listed domain shows a real IP (the `dns-direct` path to `<LAN_DNS>` still works
because sing-box binds that socket to the physical NIC, not the resolver setting).
Additional adapters (a second Ethernet, Hyper-V vEthernet, a phone tether) each need the
same override — list `Get-NetAdapter | ? Status -eq Up` and note how many would have to
be rewritten.

Restore and check that the restore reproduces the baseline from S0:

```powershell
Set-DnsClientServerAddress -InterfaceAlias '<NIC>' -ResetServerAddresses     # DHCP-configured adapter
# static adapter instead: Set-DnsClientServerAddress -InterfaceAlias '<NIC>' -ServerAddresses <saved list from S0>
netsh interface ipv4 show dnsservers
```

Record: whether `-ResetServerAddresses` brings back "configured through DHCP" (the
record file must therefore store *DHCP vs static + the static list*, exactly like the
`Setup:` raw dictionary on macOS).

**S6c — NRPT catch-all** (S6b restored first):

```powershell
Add-DnsClientNrptRule -Namespace '.' -NameServers 172.19.0.2 -Comment 'Wayfork spike'
Get-DnsClientNrptRule | Format-List Name, Namespace, NameServers, Comment
Get-DnsClientNrptPolicy -Effective
Clear-DnsClientCache
```

Same capture, same **yes** criteria as S6b. Extra checks for NRPT specifically:

```powershell
Resolve-DnsName -Type A <single-label hostname on the LAN, e.g. the router's name>
nslookup example.com                                   # nslookup ignores NRPT — it asks the adapter's servers; record what it does
curl.exe -4 -sS --max-time 15 https://api.ipify.org    # getaddrinfo path
ping -4 -n 1 ifconfig.me                               # another getaddrinfo user
```

Record: whether the rule applies to every application (`Resolve-DnsName`, curl, ping),
what happens to single-label and search-suffix names, and whether
`Get-DnsClientNrptPolicy -Effective` lists `.` with `172.19.0.2`. Remove:

```powershell
Get-DnsClientNrptRule | Where-Object Comment -eq 'Wayfork spike' | Remove-DnsClientNrptRule -Force
Get-DnsClientNrptRule                                  # empty (or the S0 baseline)
```

**S6d — adapter switch.** With S6b applied on Wi-Fi: plug in Ethernet (or the other way
round), wait for the new default route, run the capture. Expected: leak through the new
adapter until it is overridden too — the service needs `NotifyIpInterfaceChange` /
`NotifyRouteChange2` to re-apply. Then the same with S6c: expected airtight without any
re-apply. Record both, plus `Get-NetRoute -DestinationPrefix 0.0.0.0/0` after the switch.

**S6e — encrypted DNS.** Record the physical adapter's DoH setting (Settings → Network →
`<NIC>` → DNS server assignment, "Encrypted only / Encrypted preferred / Unencrypted
only") and `Get-DnsClientDohServerAddress`. Windows 11 only upgrades to DoH for servers in
that list; `172.19.0.2` is not, so no DDR-style bypass is expected — confirm no TCP/443
or TCP/853 from the DNS client to `<LAN_DNS>` in the capture (`pktmon filter add doh -t
TCP -p 853` in a second run if in doubt).

The design picks per-adapter (S6b) or NRPT (S6c) — or both, belt and braces — from what
S6a–S6d record.

### S7 — Teardown: what a crash leaves behind

With S5 + S6b (or S6c) in place, kill everything the ugly way:

```powershell
Stop-Process -Name sing-box -Force
Stop-Process -Name openvpn -Force
Get-Process sing-box, openvpn -ErrorAction SilentlyContinue
```

Then record the leftovers — this list is the service's start-up cleanup:

```powershell
Get-NetAdapter -IncludeHidden | Where-Object Name -like 'Wayfork*' | Format-Table Name, ifIndex, Status
Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -like 'Wayfork*' } | Format-Table DestinationPrefix, InterfaceAlias, NextHop, RouteMetric, Store
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 | Format-Table ifIndex, InterfaceAlias, NextHop, RouteMetric
Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table InterfaceAlias, ServerAddresses
Get-DnsClientNrptRule
Resolve-DnsName -Type A example.com          # with the override still pointing at a dead 172.19.0.2 this must FAIL — that is the window the service has to close
Get-NetIPAddress -InterfaceAlias 'Wayfork-1' -AddressFamily IPv4 -ErrorAction SilentlyContinue
```

Record each: does the wintun adapter `Wayfork` disappear with the process (expected:
yes, wintun adapters live with their handle) or linger as a hidden/ghost device; do the
dco adapters keep their IP address and the 9999 route (routes on an interface whose
link went down are usually dropped — verify); the DNS override and the NRPT rule survive
(certainly — they are persistent), and name resolution is dead until restored. Restore
by hand (S6b/S6c restore commands) and confirm `Resolve-DnsName example.com` works
again. Finally reboot once with the override left in place and record whether it is
still there after the reboot (it should be — the service must restore at start).

### S8 — Job objects (`KILL_ON_JOB_CLOSE`)

The Windows replacement for pid files: children die with the parent, no matter how the
parent dies. Save as `C:\wf\tools\job-test.ps1`:

```powershell
$src = @'
using System;
using System.Runtime.InteropServices;
public static class Job {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr CreateJobObject(IntPtr attrs, string name);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint size);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [StructLayout(LayoutKind.Sequential)]
  struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
    public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)]
  struct IO_COUNTERS { public ulong A, B, C, D, E, F; }
  [StructLayout(LayoutKind.Sequential)]
  struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION Basic; public IO_COUNTERS Io;
    public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
  public static IntPtr Create() {
    IntPtr job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
    var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    info.Basic.LimitFlags = 0x2000;                       // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    int size = Marshal.SizeOf(info);
    IntPtr p = Marshal.AllocHGlobal(size);
    Marshal.StructureToPtr(info, p, false);
    if (!SetInformationJobObject(job, 9, p, (uint)size))  // JobObjectExtendedLimitInformation
      throw new System.ComponentModel.Win32Exception();
    return job;
  }
}
'@
Add-Type -TypeDefinition $src
$job = [Job]::Create()
$p = Start-Process -FilePath C:\wf\sb\sing-box.exe -ArgumentList 'run', '-D', 'C:\wf\sb', '-c', 'C:\wf\sb\sing-box.min.json' -PassThru
if (-not [Job]::AssignProcessToJobObject($job, $p.Handle)) { throw [System.ComponentModel.Win32Exception]::new() }
"sing-box pid $($p.Id) is in the job; this PowerShell is pid $PID. Kill me from another window."
while ($true) { Start-Sleep 5 }
```

Run it in elevated window #1. From elevated window #2:

```powershell
Get-Process sing-box | Format-Table Id, StartTime            # running
Stop-Process -Id <pid of window #1's PowerShell> -Force      # or close window #1 with the X
Start-Sleep 2
Get-Process sing-box -ErrorAction SilentlyContinue           # expect: nothing
```

**Yes** = `sing-box.exe` is gone within a second of the parent's death, and the `Wayfork`
adapter with it. Control: run the same `Start-Process` line without the job (`$p = …`,
kill the shell) and confirm sing-box *survives* — otherwise the test proved nothing.
Record both results, and any `AssignProcessToJobObject` error (`Access is denied` would
mean the shell already sits in a job that forbids nesting — note the terminal used).
Then the same script under `psexec -s` (the parent is then a session-0 process) — a
service will do exactly this.

### Results

Fill in during the spike; `Yes`/`No`/`Partial` plus the pasted evidence or a pointer to
`C:\wf\results\<file>`. Date each row.

Environment: Parallels VM, Windows 11 ARM64 (see § Spike environment) — amd64 re-check owed in WM5.

| # | Item | Result | Evidence / notes | Date |
|---|------|--------|------------------|------|
| S0 | sing-box zip contents + SHA256; `sing-box version` | Yes | arm64 zip = `sing-box.exe`, `libcronet.dll`, `LICENSE` — no `wintun.dll`; SHA256 `dbb6c4803f94a997fcc4a1cce313eff65a901abc197731b55109ea4fbd412c88`; `sing-box version 1.13.19`, go1.26.5 windows/arm64, tags `with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,…`. GitHub download from inside the guest crawled (5 MB in 6 min); fetched on the Mac and `scp`'d | 2026-08-27 |
| S0 | MSI SHA256; `msiexec /a` tree — where `*.inf`/`*.sys`/`*.cat` landed, or fallback to full install | Partial | arm64 MSI SHA256 `577d9bc20cd3e42447a0f94b063dd470a110e9d340b594515a2f4aba1b34485e`. `msiexec /a` exit 0, 72 files, `OpenVPN\bin\` complete (`openvpn.exe`, `tapctl.exe`, `openvpnserv*.exe`, DLLs) but **no driver files at all** (no `*.inf/*.sys/*.cat/*.msm`) — the admin image does not lay out the merge modules. Fallback taken: `msiexec /i … /qn /norestart` (exit 0) installed `ovpn-dco.inf` 2.8.4.0 (`oem10.inf`) and `oemvista.inf` 9.27.0.0 (`oem9.inf`), both `Microsoft Windows Hardware Compatibility Publisher`, and created the default adapters `OpenVPN Data Channel Offload` / `OpenVPN TAP-Windows6`. The dco package (`ovpn-dco.inf/.sys/.cat/.PNF`, cat signature Valid) was copied out of `DriverStore\FileRepository\ovpn-dco.inf_arm64_*` to `C:\wf\drivers\ovpn-dco` for the standalone `pnputil` test (S2.2). `OpenVPNService`/`OpenVPNServiceInteractive` stopped and disabled. Evidence: `s0-msi-tree.txt`, `s0-msiexec.log`, `s0-msi-install.log` | 2026-08-27 |
| S0 | `openvpn.exe --version` line | Yes | `OpenVPN 2.7.6 [git:v2.7.6/327a33de2aa21883] Windows [SSL (OpenSSL)] [LZO] [LZ4] [PKCS11] [AEAD] [DCO] built on Aug  5 2026`; `OpenSSL 3.6.3`, `Windows version: 10.0.26200,arm64`, `DCO version: 2.8.4` | 2026-08-27 |
| S1a | TUN as Administrator: adapter, address, metric, default route on `Wayfork`, `<LAN_DNS>` excluded, `curl` direct, probe answers | Yes | `sing-box check` exit 0. Adapter `Wayfork` (`sing-tun Tunnel`, ifIndex 16) Up, `172.19.0.1/30`, MTU 1500. **No `0.0.0.0/0` route on `Wayfork`** — sing-tun adds the inverse of `route_exclude_address` as 53 specific routes; `Find-NetRoute 9.9.9.9` → `Wayfork`, `Find-NetRoute 192.168.31.1` → `Ethernet`; the `0.0.0.0/0` table still shows only `Ethernet` (metric 0+15). `curl.exe https://ipinfo.io/ip` → home IP. `Resolve-DnsName -Server 172.19.0.2 probe.wayfork.internal` → `172.19.0.2`; `example.com` via `172.19.0.2` answered. Log: `inbound/tun` connections, `router: found process path: …` (process lookup works). Evidence: `s1a-route.txt`, `s1a-singbox.out` | 2026-08-27 |
| S1a | DNS server sing-box set on `Wayfork`; route count on `Wayfork`; stack that worked (`system` / `mixed` / `gvisor`) | Yes | TUN DNS = `172.19.0.2` (as predicted); 53 routes on `Wayfork`; `stack: system` worked first time (TCP via `curl`, UDP DNS) — no fallback needed. Interface metric: see S1b | 2026-08-27 |
| S1a | Leftovers after Ctrl+C (adapter, routes) | Yes | The process had already died: a child started with `Start-Process` inside an SSH session is console-attached and is terminated when that session's console closes (no Ctrl+C was ever sent). After that death: no `Wayfork` adapter (also not hidden), 0 routes on it, `Find-NetRoute 9.9.9.9` → `Ethernet`, DNS resolution fine. Same after `Stop-Process -Force` in S1b. The wintun adapter and its routes live and die with the process handle — nothing for the service to clean on the sing-box side | 2026-08-27 |
| S1b | Same under `psexec -s` (session 0) | Yes | `PsExec64.exe -s -d -w C:\wf\sb cmd /c "sing-box.exe run … > s1b-singbox.log 2>&1"` (x64 PsExec under emulation; `whoami` = `nt authority\system`, session 0 `services`). sing-box pid 6772, SessionId 0. Adapter `Wayfork` Up, `172.19.0.1/30`, TUN DNS `172.19.0.2`, 53 routes, `Find-NetRoute 9.9.9.9` → `Wayfork`. From the user session (ssh as `fost`): `curl.exe https://ipinfo.io/ip` → home IP through the TUN with `router: found process path: C:\Windows\System32\curl.exe`; probe → `172.19.0.2`. `netsh interface ipv4 show interfaces`: `Wayfork` Met **0**, `Ethernet` 15, dco adapters 25 (`Get-NetIPInterface`'s `InterfaceMetric` printed empty for the TUN — cmdlet quirk, netsh is authoritative). Evidence: `s1b-singbox.log` | 2026-08-27 |
| S2.1 | `--windows-driver wintun` reaction (exact warning); `wintun` anywhere in help/adapters | Yes | `DEPRECATED OPTION: windows-driver: In OpenVPN 2.7, the default Windows driver is ovpn-dco. If incompatible options are used, OpenVPN will fall back to tap-windows6. Wintun support has been removed.` — then it continues. `--windows-driver` is absent from `--help`; `--disable-dco`, `--dev-node`, `--show-adapters`, `--dns-updown` present. `--show-adapters` prints `'<name>' {GUID} <driver>` per adapter | 2026-08-27 |
| S2.2 | `pnputil /add-driver ovpn-dco.inf` silent; published name `oemNN.inf`; reboot asked? | Yes | Tested against a machine *without* the driver: `pnputil /delete-driver oem10.inf /uninstall` (`/force` is ignored with `/uninstall`) → `Driver package uninstalled. Driver package deleted successfully.`, 0 dco packages left, all dco adapters gone (`tapctl list` shows only the TAP one). Then `pnputil /add-driver C:\wf\drivers\ovpn-dco\ovpn-dco.inf /install` with the package harvested from the OpenVPN MSI install (`.inf` + `.sys` + `.cat`, WHQL/attestation-signed) → `Driver package added successfully. Published Name: oem10.inf`, exit 0, **no prompt, no reboot**; it also re-bound the three orphaned root devnodes (`ROOT\NET\0001-0003`). `tapctl create` afterwards made fresh `Wayfork-1` / `Wayfork-2` (`#4`/`#5`, new GUIDs). Conclusion for WM4: the Wayfork MSI can ship the `ovpn-dco` package and install it with `pnputil` (or WiX's `DifxApp`-less custom action) without the OpenVPN MSI — provided the arm64/amd64 packages are extracted from the pinned OpenVPN install once and their signature is checked; uninstall = `tapctl delete` every adapter **first**, then `pnputil /delete-driver <oem#.inf> /uninstall`. Order matters: `/uninstall` leaves the root devnodes (`ROOT\NET\000N`) in place as driverless devices, and the next `add-driver /install` re-binds them as adapters named `Local Area Connection`, `… 2`, `… 3` with **new GUIDs and the old names lost** (`Wayfork-1` came back as `Local Area Connection 2`). Cleaned with `tapctl delete "Local Area Connection…"`. Service start-up cleanup: any `ovpn-dco` adapter not named `Wayfork-N` is stray and gets deleted | 2026-08-27 |
| S2.3 | `tapctl create --name Wayfork-1/2 --hwid ovpn-dco`; `Get-NetAdapter` names match | Yes | `{161612A2-632E-4814-B689-4EDF431A88C4}⇥Wayfork-1⇥ovpn-dco`, `{3A563680-C05C-4802-9938-4104A3BF2248}⇥Wayfork-2⇥ovpn-dco` (printed by `tapctl create`). `Get-NetAdapter`: `Wayfork-1` ifIndex 17, `Wayfork-2` ifIndex 18, description `OpenVPN Data Channel Offload #2` / `#3`, `Disconnected`, no MAC. `openvpn --show-adapters` lists both with driver `ovpn-dco` | 2026-08-27 |
| S2.4 | Survive reboot (names + GUIDs) | Yes | After `Restart-Computer`: `tapctl list` and `Get-NetAdapter` show `Wayfork-1` `{161612A2-…}` and `Wayfork-2` `{3A563680-…}` unchanged. **ifIndex changed** (17→3, 18→6) — the service must address adapters by name/GUID (LUID), never by a cached index | 2026-08-27 |
| S2.4 | Duplicate refused; re-create after delete keeps the name or gets `… 2`; ghost PnP devices | Yes | `tapctl create --name Wayfork-1` → `Adapter "Wayfork-1" already exists (GUID {161612A2-…}).`, exit 1. `tapctl delete Wayfork-2` exit 0; `create --name Wayfork-2` again → new GUID `{D8572BD9-8E2D-48BC-B5A0-BB134158BCF9}`, **same name**, same ifIndex 6 and description `#3` reused; `Get-PnpDevice` shows exactly 3 present dco devices (`ROOT\NET\0001-0003`), no ghosts. Names are trustworthy; GUID changes on re-create, so the plan/records must key on the name and re-read the GUID/LUID | 2026-08-27 |
| S3a | OpenVPN 1 reaches CONNECTED under the TUN; `process_path` matched (exact `process` field; case) | Yes | t1 `>STATE:…,CONNECTED,SUCCESS,10.8.0.27,91.142.94.179,1194,,` **2 s** after `hold release` (`WAIT`→`AUTH`→`ASSIGN_IP`→`CONNECTED`). Its own UDP/1194 to the server went **direct**: sing-box logs `router: found process path: C:\wf\ovpn\bin\openvpn.exe` then `outbound/direct[direct]: outbound packet connection to 91.142.94.179:1194` — the `process_path` rule matched. **Field format:** sing-box prints the full native path with backslashes and on-disk case (`C:\wf\ovpn\bin\openvpn.exe`); the rule value must be JSON-escaped (`C:\\wf\\ovpn\\bin\\openvpn.exe`) and case is preserved as on disk — no lowercasing needed here, but the importer should case-fold defensively. `process_name: ["openvpn.exe"]` was not needed. Evidence: `s3-singbox.err`, `bisect-singbox.err` | 2026-08-27 |
| S3b | Management dialogue vs 04-tunnels table; `>PASSWORD:` wording; `PUSH_REPLY` DNS / route-gateway | Yes | Identical to the macOS table: `>HOLD:Waiting for hold release:0` → `hold release` → `>PASSWORD:Need 'Private Key' password` (answered with `password "Private Key" …`) → `>STATE:…,WAIT` → `AUTH` → `ASSIGN_IP,,10.8.0.27` → `>STATE:1787840212,CONNECTED,SUCCESS,10.8.0.27,91.142.94.179,1194,,`; with `log on` every `>STATE:` is echoed once more as `>LOG:…,,MANAGEMENT: >STATE:…` (parser must de-duplicate); `>BYTECOUNT:in,out` every 5 s. No wording differences. `PUSH_REPLY` (t1): `route-gateway 10.8.0.1`, `ifconfig 10.8.0.27 255.255.255.0`, `topology subnet`, `ping 10`, `ping-restart 120`, three `route …` and **no** `dhcp-option DNS` (the spike uses 1.1.1.1 as `<OVPN1_DNS>`). With `--route-nopull` each pushed `route` is logged as `Options error: option 'route' cannot be used in this context ([PUSH-OPTIONS])` — three per connect, harmless; the log parser must not treat `Options error` in a `PUSH-OPTIONS` context as fatal. Evidence: `s3-mgmt-t1.log`, `s3-openvpn-t1.log` | 2026-08-27 |
| S3c | Log line(s) naming the adapter (Windows replacement for `Opened utun device`) | Yes | `ovpn-dco device [Wayfork-1] opened` — exactly one line per open, carries the adapter **name**, no GUID anywhere in the log at `--verb 3`; regex `ovpn-dco device \[(.+)\] opened`. A soft restart (`SIGUSR1[soft,ping-restart]`) does not repeat it: `Preserving previous TUN/TAP instance: Wayfork-1`. No `open_tun`/`IP Helper`/GUID lines with the dco driver. Evidence: `s3-openvpn-t1.log` | 2026-08-27 |
| S3d | `--dns-updown disable` accepted; address-setting method (`IP Helper` / `netsh`) | Yes | `--dns-updown disable` accepted silently (no `Options error`/`Unrecognized`, no `dns-updown` line at all). Addresses go through **netsh**: `NETSH: C:\WINDOWS\system32\netsh.exe interface ip set address 5 static 10.8.0.27 255.255.255.0 store=active`, then `… interface ip delete dns 5 all` and `… delete wins 5 all` (`5` = ifIndex of `Wayfork-1`, `store=active` → nothing persistent). Result `Get-NetIPAddress Wayfork-1` = `10.8.0.27/24 Manual`; interface metric 3 (automatic), `ConnectionState Connected`. Routes on `Wayfork-1` appear **asynchronously**: 2 s after CONNECTED only `255.255.255.255/32` + `224.0.0.0/4` existed, the on-link `10.8.0.0/24`, `10.8.0.27/32`, `10.8.0.255/32` came later — the service must not snapshot routes right after CONNECTED. Also: `--persist-key` prints `DEPRECATED OPTION: --persist-key option ignored` in 2.7 (drop it from the Windows argv); `--max-routes` likewise | 2026-08-27 |
| S4a | `bind_interface Wayfork-1` exits through OpenVPN 1 with **no** extra route | No (as expected) | With only OpenVPN's own on-link routes on `Wayfork-1`, sing-box's `t-0001` outbound (a `direct` with `bind_interface: Wayfork-1`) cannot leave: `open connection … using outbound/direct[t-…0001]: dial udp 1.1.1.1:53: connect: A socket operation was attempted to an unreachable network` (`WSAENETUNREACH`) on the very first hop (the tunnel's own DNS). `IP_UNICAST_IF` alone is not enough on Windows — the bound socket still needs a matching route to pick a next hop. Matches the macOS need for a scoped default. Evidence: `bisect-singbox.err` | 2026-08-27 |
| S4b | … with the 9999 default route (which NextHop shape worked) | Yes | `New-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceAlias Wayfork-1 -NextHop <route-gateway> -RouteMetric 9999 -PolicyStore ActiveStore` — the **pushed `route-gateway`** shape worked on the first try for both tunnels (t1 `10.8.0.1`, t2 `192.168.35.1`, both taken from `PUSH_REPLY` even under `--route-nopull`); the on-link `0.0.0.0/0 → 0.0.0.0` fallback was never needed. With the route in place the `unreachable network` error is gone and `t-0003`/`Wayfork-2` carries real traffic end to end: `curl https://jira.sccloud.ru/` → **`http=200 remote=198.18.0.4`** (fake IP dialled, sing-box reverse-maps to the real `192.168.42.75` and exits through OpenVPN 2). `PolicyStore ActiveStore` keeps the route out of the persistent store (gone on reboot, as the service wants). Note the metric that decides selection is `RouteMetric + InterfaceMetric`: the dco `InterfaceMetric` is 25, so the effective cost is 9999+25 — still far above the TUN. Evidence: `s456.txt`, `s456-connections.json` | 2026-08-27 |
| S4c | System default untouched (`Find-NetRoute 9.9.9.9` → `Wayfork`; direct + DNS fine) | Yes | With both 9999 routes added the `0.0.0.0/0` table is: `Ethernet` metric 0+15 (the real default), `Wayfork-1` 9999+25, `Wayfork-2` 9999+25. `Find-NetRoute 9.9.9.9` → **`Wayfork`** (the TUN, interface metric 0); `curl ipinfo.io/ip` → the home IP `94.77.164.68`; `example.com` still resolves. The 9999 routes can only ever be chosen by a socket already bound to `Wayfork-N`, exactly as intended — they never win the general default. Evidence: `s456.txt` | 2026-08-27 |
| S4 | **Go / no-go** | **GO** | `bind_interface` is honoured on Windows **with** a scoped default route on the dco adapter (S4b), and it does **not** disturb the system default (S4c). S4a alone is not enough — the OS needs the route to pick a next hop — but that is the same shape as the macOS `route -ifscope` default and is fully under the service's control (`New-NetRoute … -PolicyStore ActiveStore`, next hop = the pushed `route-gateway`). Proven end to end by OpenVPN 2 (`jira.sccloud.ru` → 200 through `Wayfork-2`). No design change needed; the Windows routes module replaces `route -ifscope` with a per-adapter metric-9999 default. | 2026-08-27 |
| S5a | Four exits correct (direct, OVPN1, OVPN2, VLESS); both OpenVPN up together | Partial | **Both OpenVPN tunnels up at once** (no adapter/port clash: `Wayfork-1`:7505 + `Wayfork-2`:7506, `openvpn` process count 2 throughout). Three of the four exit classes confirmed correct: **direct** `ipinfo.io` → `94.77.164.68` (home), **VLESS** `ifconfig.me` → `64.188.61.102` (distinct exit), **OpenVPN 2** `jira.sccloud.ru` → `http=200` through `Wayfork-2`. **OpenVPN 1 (pilot-gps) did not complete**: `curl` → `(35) Recv failure: Connection was reset`; its real target `185.147.81.35` (a public IP the tunnel pushes a `/32` for) either looped back to a fake IP on the outbound re-resolve or was reset server-side — a sing-box DNS-config / upstream matter, **not** a Windows routing failure (the identical mechanism carried OpenVPN 2). Tracked as an open item; the routing go/no-go (S4) is unaffected. Evidence: `s456.txt` | 2026-08-27 |
| S5b | `/connections`: `chains`, `metadata.host`, `processPath` per outbound; UDP DNS via detour | Partial | `/connections` (Clash API, `Authorization: Bearer spike`) returns each flow with `chains` = the outbound tag chain and `metadata.host` = the sniffed hostname. Captured live: both OpenVPN control flows correctly classified **direct** by the `process_path` rule — `chains=direct host= dst=91.142.94.179:1194 proc=C:\wf\ovpn\bin\openvpn.exe` and `chains=direct host=vpn.sccloud.ru dst=109.202.30.197:40001 proc=C:\wf\ovpn\bin\openvpn.exe` (so `metadata.processPath` carries the native backslashed path the rule matches on). The short-lived user flows had closed before the snapshot, but the DNS side is visible in the sing-box log: tunnel domains resolve to fake IPs via the `fakeip` server and direct domains via `dns-direct`; `default_domain_resolver: dns-direct` does the connect-time real-IP resolution (works when the upstream answers, as for `jira.sccloud.ru` → `192.168.42.75`). Evidence: `s456-connections.json`, `s3-singbox.err` | 2026-08-27 |
| S6a | Leak without override (packets to `<LAN_DNS>`; probe result; fake vs real IP) | Leak confirmed | TUN-only config (no fake-ip yet). `Resolve-DnsName probe.wayfork.internal` → `172.19.0.2` (the TUN answered and won), **but** the canary name appears twice on `Ethernet` (query to `192.168.31.1` + its response): Windows queried the router in parallel. `nslookup` picks `172.19.0.2` (binding order puts the metric-0 TUN first). Evidence: `s6-a.pcapng` | 2026-08-27 |
| S6b | Per-adapter override airtight; direct names still resolve; number of adapters to rewrite | **No** | `Set-DnsClientServerAddress Ethernet 172.19.0.2`: lookups all succeed (probe → `172.19.0.2`, curl/ping fine), but the canary still shows up once on `Ethernet`: `192.168.31.203:54517 → 172.19.0.2:53`, dst-mac = the router. Windows sends the query for an adapter's configured resolver **out of that adapter** (to its gateway), regardless of the routing table — the Windows twin of macOS's `State:`-DNS `if_index` scoping. The TUN adapter's own entry got the answer; the copy still left the host. So the per-adapter override does not stop the leak, it only moves it; ruled out as the mechanism. Adapters that would have needed rewriting here: 1 (`Ethernet`). Evidence: `s6-b.pcapng` decode in the spike notes | 2026-08-27 |
| S6b | Restore reproduces DHCP/static state (`netsh … show dnsservers`) | Yes | `-ResetServerAddresses` → `DNS servers configured through DHCP: 192.168.31.1` again. Moot for the design since S6b is out, but a record file would have to store DHCP-vs-static | 2026-08-27 |
| S6c | NRPT `.` airtight; applies to Resolve-DnsName / curl / ping; single-label names; `nslookup` behaviour | Yes | `Add-DnsClientNrptRule -Namespace . -NameServers 172.19.0.2`; `Get-DnsClientNrptPolicy -Effective` lists `.` → `172.19.0.2`. **0** canary occurrences on `Ethernet`; `Resolve-DnsName`, `curl`, `ping` all resolved (through the TUN); probe → `172.19.0.2`. Single-label `nas`: no answer (no such host — inconclusive). `nslookup` still asks the first adapter's server directly (`172.19.0.2` here). Removing the rule with `Remove-DnsClientNrptRule -Force` leaves 0 rules. **Re-confirmed on the full fake-ip config (S6 re-run):** with sing-box + both OpenVPN + the 9999 routes up and NRPT `.` active, the system resolver returned fake IPs for tunnel domains (`jira.pilot-gps.com`→`198.18.0.2`, `wiki`→`198.18.0.3`, `jira.sccloud.ru`→`198.18.0.4`, `ifconfig.me`→`198.18.0.5`) and real IPs for direct (`ipinfo.io`→`34.117.59.81`, `example.com`→real); `Get-DnsClientNrptPolicy -Effective` = `.` → `172.19.0.2`; **canary = 0** UDP/53 to the router on the NIC (pktmon comp 2). `nslookup` prints both `172.19.0.2` and the fake answer. Evidence: `s6-c.pcapng`, `s456.txt`, `s456.pcapng` | 2026-08-27 |
| S6d | Wi-Fi ↔ Ethernet: S6b leaks until re-applied? S6c holds? | Yes (NRPT) | Simulated with the two virtual NICs: NRPT `.` active, `Enable-NetAdapter 'Ethernet 2'` + `Disable-NetAdapter 'Ethernet'` → new default route on `Ethernet 2` (`192.168.31.204`, DNS `192.168.31.1` from DHCP). `Find-NetRoute 9.9.9.9` → `Wayfork` still; probe → `172.19.0.2`; **0** canary packets on `Ethernet 2`; `curl` through the TUN fine — sing-box's `auto_detect_interface` re-bound its upstream sockets to `.204` without a restart. S6b was not re-tested after the switch: it leaks even without one (S6b). Side note: the idle dco/TAP adapters carry APIPA `169.254.x` addresses while `Disconnected` — harmless, but `Get-NetIPAddress` output must not be read as "tunnel up". Evidence: `s6d.txt`, `s6-d.pcapng` | 2026-08-27 |
| S6e | DoH setting on `<NIC>`; no 443/853 to `<LAN_DNS>` from the DNS client | Yes | `netsh dns show encryption`: every well-known template has `Auto-upgrade: no`, `UDP-fallback: no`; `Get-DnsClientDohServerAddress` lists only the built-in templates (Quad9/Google/Cloudflare) with `AutoUpgrade False`; no `DohInterfaceSettings` keys under `Dnscache\InterfaceSpecificParameters` for any interface. `172.19.0.2` cannot be upgraded — no DDR-style bypass on a stock 26200. 443/853 capture not run (no template applies) | 2026-08-27 |
| S7 | Leftovers after `Stop-Process -Force`: wintun adapter, dco adapters' IPs/routes, DNS override, NRPT, resolution dead | Yes | Killed sing-box + both OpenVPN `-Force` with NRPT `.` and the two 9999 routes live. **What vanished:** the sing-tun `Wayfork` adapter and all 53 of its inverse routes — gone with the process handle (`find 9.9.9.9` fell back to `Ethernet`, no blackhole). **What lingered (the service's start-up cleanup list):** (1) both dco/TAP `Wayfork-1`/`Wayfork-2` adapters stay present as **`Disconnected`** with their addresses in **`Deprecated`** state (`10.8.0.27` Manual, `192.168.35.112` Dhcp); (2) **their `0.0.0.0/0` metric-9999 routes and on-link `/24` routes SURVIVE the process death** (still in `ActiveStore` after the kill) — must be removed explicitly; (3) the **NRPT `.` rule survives**, so name resolution is **dead** (`Resolve-DnsName example.com` empty, `curl` → `Resolving timed out after 10003 ms`) until it is removed. **Restore** = `Remove-DnsClientNrptRule -Force` + `Remove-NetRoute` of every `0.0.0.0/0` on `Wayfork-*` + drop stale `Manual` addresses; afterwards `example.com` resolved and `curl ipinfo.io` → the home IP `94.77.164.68`. So the Windows service's boot sequence mirrors the macOS daemon: **restore DNS (NRPT) first**, then delete stray adapter routes/addresses (or just delete+recreate the `Wayfork-*` adapters, which clears both). OpenVPN's per-connect WFP block filters: teardown on force-kill *(verify)* — the `netsh wfp` tally read 0 but the runtime dump showed them present. Evidence: `s7-full.txt` | 2026-08-27 |
| S7 | Override survives reboot | Yes (NRPT) | `Add-DnsClientNrptRule . → 172.19.0.2`, `Restart-Computer`: the rule and the effective policy are back after boot; with no sing-box running `Resolve-DnsName example.com` fails and `curl` reports `Resolving timed out after 8028 milliseconds` — the machine has no working resolver until the rule is removed (`Remove-DnsClientNrptRule -Force` → resolution back at once). The service must restore at start (before anything else), exactly like the macOS daemon's bootstrap restore; the MSI uninstaller must remove the rule too | 2026-08-27 |
| S8 | Child dies with parent (job); control without job survives; under `psexec -s` | Yes | Run under `PsExec64 -s -d` (parent = PowerShell as SYSTEM, session 0). Job with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (`SetInformationJobObject` class 9, `AssignProcessToJobObject` on `Process.Handle`): sing-box pid 1808 alive with the `Wayfork` adapter → `Stop-Process -Force` on the parent (pid 4820) → sing-box gone and adapter gone within 3 s. Control without a job: parent exited at once, sing-box kept running (killed by hand). `AssignProcessToJobObject` succeeded — no nested-job problem under PsExec. Script: `C:\wf\tools\job-test.ps1` + `s8-run.ps1` | 2026-08-27 |
| — | Anything unexpected worth a design note | Yes | (1) **Compression forces the TAP fallback.** t2's profile carries `comp-lzo no`; OpenVPN 2.7 logs `Note: '--allow-compression' is not set to 'no', disabling data channel offload` and t2 came up on **`TAP-Windows Adapter V9` (`root\tap0901`)**, not dco — `bind_interface` worked on it all the same (DHCP address, `jira.sccloud.ru` → 200), so both driver types are fine, but the importer should strip/normalise compression to keep dco (better perf) and the adapter code must not assume the `ovpn-dco` hwid. (2) **`--route-nopull` + pushed `route` = benign `Options error`.** Every pushed `route` logs `Options error: option 'route' cannot be used in this context ([PUSH-OPTIONS])` (3–5 per connect) — expected, not fatal; the log parser must whitelist it. (3) **dco `InterfaceMetric` is 25**, so a metric-9999 route costs 9999+25 for selection — still far below the TUN, but the number to reason about is the sum. (4) sing-tun renders `route_exclude_address` as **53 inverse `/n` routes** pointing at the TUN (no `0.0.0.0/0`), all metric 0 — that is the Windows shape of the macOS default route. (5) idle dco/TAP adapters sit at APIPA `169.254.x` / `Disconnected` — `Get-NetIPAddress` must never be read as "tunnel up". | 2026-08-27 |

Closing W2a = every row filled, the go/no-go row decided, and the outcome written into
the sections above (W2b).
