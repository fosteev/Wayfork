# Roadmap

Work proceeds strictly phase by phase. A phase is closed only after explicit maintainer
approval; the next phase is not started before that.

The Windows client has its own track: [ROADMAP-windows.md](ROADMAP-windows.md).

| Phase | Deliverable | Status |
|---|---|---|
| 1. Features | Feature list below, split into MVP / Later | approved 2026-08-25 |
| 2. Design | `docs/design/*.md` — UX + technical design per feature | approved 2026-08-25 |
| 2b. UI prototype | `docs/design/prototype/index.html` — static HTML mockups of every MVP screen, approved before implementation | variant B approved 2026-08-25; variant C (F14–F18 redraw) approved 2026-09-15 |
| 3. Implementation | Task checklist in this file, ordered by dependencies | in progress |

## Phase 1 — Features

Written as user scenarios. Technical details belong to Phase 2.

### MVP

**F1. Tunnel configs**
- Add an OpenVPN tunnel from a `.ovpn` file (drag & drop / file picker). Inline certs
  and keys are supported; if the profile needs a username/password, ask once and store it.
- Add a VLESS tunnel from a `vless://` URI (paste or clipboard). Supported transports:
  TCP, WebSocket, gRPC; TLS and REALITY.
- Give each tunnel a name; edit, remove, enable/disable it.
- Secrets (keys, passwords, UUIDs) are stored in Keychain, never in plain files.

**F2. Rules: domain → tunnel**
- A rule is `pattern → tunnel`. Patterns: exact domain, domain suffix (`example.com`
  covers subdomains), wildcard (`*.cdn.example.com`).
- Everything not matched by a rule goes direct (no VPN).
- Rules are an ordered list; the first match wins. Add, edit, reorder, remove, toggle.
- Quick add: "route `<domain>` via `<tunnel>`" from the menu bar.

**F3. Start / stop**
- One global switch in the menu bar: On brings up every enabled tunnel and the routing
  engine; Off tears everything down and restores networking as it was.
- Editing a rule or tunnel while On applies the change without a full restart
  where possible (rule edits → hot reload; tunnel edits → reconnect that tunnel).
- The first start installs a privileged helper; the user approves it once in
  System Settings → Login Items. No password prompts from Wayfork itself.

**F4. Status**
- Menu bar icon reflects the global state: off / connecting / on / degraded (a tunnel is
  down) / error.
- The menu lists each tunnel with its state (connected, connecting, failed, disabled)
  and the number of rules pointing at it.
- Per-tunnel actions: reconnect, disable.

**F5. Logs and diagnostics**
- Log window with the app log, sing-box log and per-tunnel OpenVPN logs, filterable by
  source and level.
- "Export diagnostics" — a zip with logs and a sanitized config (secrets stripped) for
  bug reports.

**F6. Settings**
- Launch at login; connect on launch.
- Reconnect a tunnel automatically on failure (with backoff).
- DNS behavior: which upstream to use for direct traffic (system / custom).
- Log level and retention.

**F7. Import / export**
- Export tunnels and rules to a JSON file (secrets excluded or included on request).
- Import from that file. Templates in `examples/`.

**F8. Default tunnel ("everything else") and exceptions** *(added 2026-08-25)*
- Mark one tunnel as the default exit: everything not matched by a rule goes through it
  instead of direct. Only one tunnel can be the default; without one, unmatched traffic
  stays direct as before.
- Exceptions: rules whose target is **Direct**. They have the highest priority, so they
  carve domains out of the default tunnel — and, without a default, out of a broader
  tunnel rule (`example.com → Work`, `api.example.com → Direct`).
- Local names (`.local`, `.lan`, `.internal`, `.home.arpa`) are built-in exceptions.
- If the default tunnel is down, unmatched traffic is blocked rather than leaked direct.

**F9. Traffic rates** *(added 2026-08-25)*
- While On, every tunnel card in the popover shows the current download / upload rate of
  the traffic leaving through that tunnel, updated once a second. A slim **Direct** row
  under the cards shows what bypasses the tunnels.
- The default tunnel (F8) counts everything unmatched; with a default tunnel the Direct row
  is exceptions and local names only.
- Hovering a rate shows totals since Turn On and the number of open connections.
- Rates are shown only for connected/ready tunnels while routing is On; nothing in Settings,
  nothing in the menu bar. History, graphs and a menu bar readout are Later (L4, L7).

**F10. Rules: application → tunnel** *(added 2026-08-25)*
- A rule can name an application instead of a domain: "route Telegram via Home", "keep
  Bank.app direct". The app is picked in a file dialog; the rule covers every process
  inside the bundle (helpers included), whatever domain or IP it talks to.
- Application rules live in the same groups as domain rules and follow the same order:
  Direct group first, then tunnels in store order. Inside a group, domain and application
  rules are peers — either one matches.
- Only traffic that enters Wayfork is affected: an app that talks through another local
  proxy is seen as that proxy's process, not as the app.
- Quick add from the menu bar has no application entry. Rules by IP / CIDR are F11.

**F11. Rules by IP address / subnet** *(added 2026-08-25)*
- A rule can name an IPv4 address or subnet instead of a domain: `10.8.0.0/24 → Office`,
  `203.0.113.7 → Home`, `192.0.2.0/24 → Direct`. It is typed into the same field as a
  domain; the match type switches to **IP** on its own.
- Matches connections opened *to* an address in the range: SSH/RDP/DB clients pointed at
  an IP, internal servers without names, apps that resolve names on their own (DoH). A site
  reached by name is decided by the domain rules even when the name resolves into the range.
- Private ranges (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`) normally stay out of
  Wayfork entirely; a tunnel rule inside them pulls exactly that subnet in — what an
  OpenVPN office network needs, since `--route-nopull` drops the pushed routes. The UI
  warns when a rule covers the Mac's own LAN.
- IPv6 rules come with IPv6 support (Later); loopback, link-local, multicast and Wayfork's
  own ranges are rejected.

**F12. System resolver override** *(added 2026-08-26)*
- While Wayfork is On, the Mac's DNS points at Wayfork's own resolver (the TUN address);
  when it turns Off, crashes or the daemon is unloaded, the previous setting comes back.
- Why: routing the system resolver's queries *into* the TUN only works for a resolver that
  is not the default gateway (most home routers are), and even then macOS may upgrade the
  resolver to encrypted DNS (DDR) on a socket that never enters the TUN. With the override
  every application that asks the system resolver gets a fake IP and is routed by domain —
  including hosts whose public DNS record is a private address (an office Jira reachable
  only through its VPN), which never enter the TUN otherwise.
- A resolver typed by hand in System Settings › Network › DNS is replaced too and put back
  when Wayfork turns Off.
- Setting "Use Wayfork as the system resolver while On" (on by default) turns it off for
  people who run their own resolver setup.

**F13. More tunnel types** *(added 2026-09-07, promoted from L3; approved 2026-09-07)*
- A tunnel can be anything the pinned sing-box carries natively, imported the way a
  `vless://` link is today: a WireGuard `.conf` file (picked or pasted), and `ss://`,
  `trojan://`, `vmess://` links. Same set on both platforms; secrets land in Keychain /
  DPAPI like every other tunnel credential, and an export carries them only through the
  existing "export with secrets" path.
- The list stops where live testing stops: a kind ships only if there is a real server to
  check it against. Today that fence is the maintainer's Xray panel, which serves exactly
  WireGuard, Shadowsocks, Trojan and VMess. Anything else — Hysteria2, TUIC, AnyTLS — is the
  same recipe on the day a server exists, not a redesign.
- All of these follow the **VLESS model**: a native sing-box outbound (WireGuard: an
  `endpoints[]` entry), no process of its own, no interface to bring up — the tunnel is
  ready whenever sing-box runs. No new bundled binary: the pinned sing-box 1.13.19 already
  carries `with_wireguard`, `with_quic` and `with_utls` on both platforms. A WireGuard
  endpoint tag works as a route target and as a DNS detour like any outbound — verified
  2026-09-07 before the design was written.
- Everything a tunnel already has applies unchanged: domain / application / IP rules, the
  default tunnel and its exceptions, traffic rates and the dead-UDP hint, import/export.
- Scope of F13:

| Kind | Input | Secret(s) | In F13 |
|------|-------|-----------|--------|
| WireGuard | `.conf` file / pasted INI (`[Interface]`, `[Peer]`) | private key, preshared key | yes, first |
| Shadowsocks | `ss://` SIP002 (base64 userinfo, `plugin=`) | password | yes; AEAD + 2022 methods only, `plugin` → unsupported |
| Trojan | `trojan://pw@host:port?sni&fp&alpn&type&path&host&serviceName` | password | yes; shares the VLESS TLS/transport code |
| VMess | `vmess://` base64 JSON (V2RayN) | uuid | yes; `aid>0` → unsupported |
| Subscriptions (URL → list of links, plain or base64) | URL | — | yes, stage 7 (approved 2026-09-12) |
| Hysteria2, TUIC, AnyTLS, SOCKS/HTTP upstream, NaiveProxy | links / fields | password | no — no server to test against; same recipe on request |
| XHTTP via Xray-core | `vless://…type=xhttp` | uuid | no — separate approval (below) |
| IKEv2 / L2TP / other per-process VPNs | — | — | no — own process + system NE, outside the architecture |

- What sing-box would misroute or silently degrade is **refused at import with a reason**,
  never guessed: Shadowsocks legacy ciphers and `plugin=`, VMess `aid > 0` and non-V2RayN
  link forms. The VLESS parser set the precedent.
- A WireGuard conf whose `AllowedIPs` is narrower than `0.0.0.0/0` is imported as written
  and flagged: traffic Wayfork routes into it outside that list is dropped by the peer.
- **Subscription URLs** *(approved 2026-09-12)*: the same *Add from link…* sheet accepts an
  `https://` URL, fetches it, decodes the body (plain link lines or base64 of them), runs
  every line through the link parser and offers a checklist of servers to add. Lines the
  parser refuses are listed with the reason, not hidden. One-shot import, no auto-refresh
  and no stored URL — refreshing a server list belongs with L4 tunnel health, and a
  subscription URL is a bearer token, so it is never written to disk or to the log.
- **VLESS over XHTTP stays out of F13** and keeps its own shape: sing-box has no XHTTP
  transport (1.13.19 rejects `xhttp`/`splithttp`; upstream declined it), so each XHTTP
  tunnel runs its own bundled `xray` process with a local SOCKS5 inbound that sing-box
  reaches through a `socks` outbound — the OpenVPN per-process model with a port instead of
  a `utun`. Needs a pinned, signed `xray` binary (`com.wayfork.bin.xray`), an `XrayRuntime`
  entry in the plan, an xray config generator, `type=xhttp` in the URI parser and a
  process-path direct rule for xray's own traffic. Separate approval, its own roadmap file.
- Plan, decisions and per-step progress:
  [roadmap/more-tunnel-types.md](roadmap/more-tunnel-types.md); design in
  [design/04-tunnels.md](design/04-tunnels.md).

**F14. Tunnel latency** *(added 2026-09-15, promoted from L4; approved 2026-09-15)*
- Every connected tunnel shows its current latency next to the F9 rates and a sparkline of
  the last few minutes on its card; the popover and Settings show the same number.
- Latency is measured *through* the tunnel, not to the server's address: one small HTTP
  request to a fixed probe URL per sample, so the number is what a user feels and it doubles
  as a liveness check. ICMP to the server is not used — hosters drop it, and a reachable
  server says nothing about the tunnel inside.
- A probe that fails N times in a row marks the tunnel *unreachable* on the card; the
  tunnel itself is not restarted (failover is still L4).
- Rules do not get a periodic latency: a pattern, an application or an IP range names no
  host to probe, and probing every apex through the tunnel is traffic to third parties for a
  number that is the tunnel's own latency plus the site's distance. Instead, rule testing
  (L2) gets an on-demand **Probe**: one request to the entered host through the tunnel it
  matches, result shown once, nothing in the background.
- Windows client gets the same measurement and the same card.

**F15. Recent domains → rule** *(added 2026-09-15; approved 2026-09-15)*
- While the global state is on, the app shows the domains seen in the last few minutes
  that went to the *default* route (direct or the default tunnel), newest first, with the
  app that opened them where known. Each row has one action: *Route via ‹tunnel›*, which
  creates a suffix rule for the registrable domain and moves on.
- Domains already covered by a rule are not listed (they are routed as intended); a row can
  be hidden, and a hidden domain stays hidden for the session.
- Data comes from the F9 sampler: the daemon already reads `/connections`; it forwards a
  bounded list of `(host, process, tunnel, lastSeen)` in the traffic snapshot instead of
  aggregates only. The list lives in memory, is capped (200 rows), and is cleared when the
  state leaves *on*.
- Not a live connection view (L2 keeps that): no bytes, no per-connection rows, no
  history — a to-do list of "this went where you may not want it".

**F16. Tunnel groups** *(added 2026-09-15; approved 2026-09-15)*
- A group is a named, ordered list of tunnels with a policy: *fastest* (lowest F14 latency,
  re-evaluated on every probe) or *first live* (the first member whose probe passes).
  A rule, an exception or the default tunnel can point at a group wherever it can point at
  a tunnel.
- Rendered as a card among the tunnels with its members inside; the active member is
  marked. Latency on the group card is the active member's; rates are the group's own
  traffic (design decision 2026-09-15, 03-routing.md § Tunnel groups).
- Maps to a sing-box `urltest` outbound (`fastest`) or `selector` driven by the daemon
  (`first live`); the probe URL and interval are F14's. This is L4 "failover" delivered
  without a fallback field on every rule.
- Groups cannot contain groups; a member that is disabled or missing is skipped, and a
  group with no live member behaves like a down tunnel (rules fall to the default route,
  the card says so).

**F17. Local proxy port per tunnel** *(added 2026-09-15; approved 2026-09-15)*
- A tunnel (or group) can expose a local SOCKS5/HTTP port on `127.0.0.1`, shown on its card
  with a copy button: `curl --proxy socks5h://127.0.0.1:<port>`, a browser profile, a
  Telegram proxy — an explicit way to pick a tunnel without writing a rule.
- Off by default; the port is chosen by the app (stable per tunnel, stored in the model) and
  can be edited. Traffic entering the port bypasses the rules and goes to that tunnel; its
  DNS goes through the tunnel's resolver like a routed flow.
- One `mixed` inbound per enabled port and one route rule `inbound → outbound`; the
  generator emits them, the goldens cover them.
- *LAN sharing* (bind to `0.0.0.0` so a phone or a TV uses the Mac's tunnels) is a separate
  toggle behind a plain warning: the port has no password. Off by default, not in the first
  cut unless approved separately.

**F18. Block lists** *(added 2026-09-15; approved 2026-09-15)*
- Settings › General gains a *Block ads and trackers* switch backed by a bundled or
  fetched domain list (the same rule-set mechanism L1 needs for GeoSite lists). Blocked
  domains get `block` in sing-box and NXDOMAIN from the fake-ip resolver, so the browser
  fails fast instead of spinning.
- Counts blocked flows in the F9 snapshot so the switch can show "blocked N today".
- An exception field ("never block") reuses the domain-rule editor.
- Deliberately a switch, not a rule group: the audience for this feature does not want to
  see 40 000 rows.

Feature text, stages and working order for F15–F18 and the friendlier UI pass:
[roadmap/next-features.md](roadmap/next-features.md).

### Later

The F15–F18 wave (recent domains → rule, tunnel groups, local proxy ports, block lists) was
approved 2026-09-15 and sits above; the lines it replaced are marked below.

**L1. Rule sources beyond a single domain**
- Domain lists from a URL or file (e.g. GeoSite-style lists), auto-refreshed.
- Import rules from a Surge / Clash / sing-box rule-set.

**L2. Rule testing**
- "Where does `<domain>` go?" — resolve which rule/tunnel matches and why. Design:
  [design/07-rule-testing.md](design/07-rule-testing.md) (2026-08-25, not scheduled).
  The on-demand **Probe** from F14 lives in this view.
- Live connection view: active connections with domain, tunnel, bytes.

**L3. More tunnel types** — promoted to **F13** (2026-09-07). WireGuard, Shadowsocks,
Trojan, VMess, subscription URLs and XHTTP-via-Xray are all tracked there.

**L4. Tunnel health** — periodic latency checks promoted to **F14**, failover delivered by
**F16** tunnel groups (2026-09-15).
- Traffic history per tunnel (sparkline, totals per day) on top of the F9 rates.
- Refresh a subscription's server list (F13 stage 7 imports once).

**L5. Profiles**
- Named sets of rules (e.g. "work", "home") switchable from the menu bar.

**L6. Distribution and updates**
- Signed and notarized builds, Homebrew cask, in-app updates (Sparkle).
- Update bundled sing-box / openvpn independently of the app.

**L7. Nice-to-haves**
- Global hotkey for the main switch.
- Current throughput in the menu bar next to the icon (optional, F9 data).
- Per-tunnel kill switch (block matched domains instead of leaking direct when the
  tunnel is down).
- CLI for scripting (`wayfork on`, `wayfork rule add …`).

### Hardening (field findings, 2026-09-01)

Both platforms unless noted; found while debugging Discord voice ("Connecting to RTC")
on Windows. The trail: the daemon had silently killed a healthy-but-slow sing-box start
and stayed down for a day unnoticed (H1, H2); once running, voice UDP through the tunnel
died at the VPS (its host firewall drops UDP to high ports) and only per-flow counters
exposed it (H3); poisoned ISP DNS made `reverse_mapping` label the voice flows with an
unrelated domain, sending the investigation sideways (H4).

**H1. Startup verification without the race**
- The daemons wait a fixed 3 s, then check the TUN adapter and the probe route exactly
  once (`SingBoxEngine.swift` `startupGrace`, Windows `engine.go` `singBoxStartupGrace`).
  A slow utun/wintun bring-up fails a healthy start.
- Poll the check every ~500 ms for up to 10–15 s; on failure, retry the start once
  before declaring `startFailed`.

**H2. Engine failure must be loud**
- `startFailed` today is a quiet status line; the app looks On while everything routes
  direct.
- Error state on the menu bar / tray icon, a system notification, and an automatic
  re-apply with backoff.

**H3. Dead-UDP detector**
- The F9 clash counters already carry per-flow up/down. A tunnel UDP flow with
  `up > 0, down = 0` for ~10 s is a one-way tunnel (server-side UDP filtering) — the
  exact signature of broken voice/gaming.
- Highlight such flows in Traffic with a hint, and include them in the diagnostics
  report.

**H4. Truthful traffic labels**
- `reverse_mapping` lets a poisoned resolver (blocked-domain answers pointing at shared
  CDN ranges) attach an unrelated domain to raw-IP flows in Traffic.
- Drop `reverse_mapping` from the generator (routing does not need it: tunnel domains go
  through fake-ip), or at minimum show the IP next to the mapped name.

**H5. Actionable dead-UDP hint** *(approved 2026-09-02, follow-up of H3)*
- H3's ⚠ says a tunnel is dropping UDP but not *what* is dying, so the user still has to
  read the Clash API by hand to find the process and the address — which is exactly what
  the maintainer did on 2026-09-02 before adding two Direct rules that fixed Discord voice.
- Clicking the ⚠ lists the one-way flows (process, destination, bytes sent with no reply)
  and offers **Try Direct**: a prefilled, editable `/32` IP rule through the normal add
  path. Suggest only — never auto-apply, never widen the prefix automatically.
- This reopens the F9 privacy boundary on purpose: per-flow hosts and processes leave the
  daemon only on an explicit click, as a one-shot pull, never streamed.
- Plan and stages: [roadmap/dead-udp-suggestions.md](roadmap/dead-udp-suggestions.md).

## Phase 2 — Design

| Doc | Covers |
|-----|--------|
| [design/00-architecture.md](design/00-architecture.md) | components, trust boundaries, filesystem, runtime plan, lifecycle, state machines (F3) |
| [design/01-data-model.md](design/01-data-model.md) | entities, rule semantics, `store.json`, Keychain, import/export (F1, F2, F6, F7) |
| [design/02-ux.md](design/02-ux.md) | menu bar, quick add, Settings window, Logs window, onboarding, error catalogue (all) |
| [design/03-routing.md](design/03-routing.md) | `sing-box.json` generation, rule-sets, DNS/fake-ip, hot reload (F2, F3, F6) |
| [design/04-tunnels.md](design/04-tunnels.md) | OpenVPN import/runtime/management protocol, VLESS URI parsing and mapping (F1) |
| [design/05-daemon.md](design/05-daemon.md) | SMAppService, XPC protocol, client verification, supervisor, files (F3, F4, F5) |
| [design/06-logging.md](design/06-logging.md) | log sources, storage, Logs window, diagnostics export (F5) |

Open items marked *(verify)* in the docs are checked during implementation; the fallback
is stated next to each one.

### UI prototype

**Approved: [design/prototype/variant-b.html](design/prototype/variant-b.html)** — popover
dashboard (`MenuBarExtra(.window)`), sidebar Settings with inline tunnel expansion, rules
grouped by tunnel. The SwiftUI views follow it screen by screen.

**Approved 2026-09-15: [design/prototype/variant-c.html](design/prototype/variant-c.html)**
— the friendlier redraw for the F14–F18 wave, same architecture as variant B: seven boards
(popover on, popover states, Tunnels, Rules with the Recent strip, rule test with Probe,
General with block lists, New group sheet), light and dark. Its friction audit (the comment
at the top of the file) lists the wording, empty-state and one-click fixes that M10 applies
to the existing screens before the features land. Windows twin: boards W9–W15 of
[design/prototype/windows.html](design/prototype/windows.html).

[design/prototype/index.html](design/prototype/index.html) — rejected v1 (native NSMenu,
toolbar tabs, flat rules table); still the reference for the Logs window, helper alert and
Add VLESS sheet, which variant B reuses unchanged.

## Phase 3 — Implementation

Milestones in dependency order. A task is checked only when it builds, is formatted, and its
tests (where applicable) pass. Each milestone ends with a manual check on a real machine.
Targets: `Wayfork` (app), `WayforkDaemon`, `WayforkCore` (shared SPM package: models, parsers,
config generator, XPC payloads — no UI, no privileges, fully unit-testable).

### M0 — Scaffolding

- [x] Xcode project with three targets (`Wayfork`, `WayforkDaemon`, `WayforkCore` as a local
      SPM package) and a test target for `WayforkCore`; macOS 14 deployment, Swift 6 language
      mode with strict concurrency.
- [x] App `Info.plist`: `LSUIElement`, bundle id `com.wayfork.app`; daemon plist under
      `Contents/Library/LaunchDaemons/` per [05-daemon.md](design/05-daemon.md).
- [x] `scripts/versions.env` + `scripts/fetch-bins.sh`: download pinned sing-box release,
      build static openvpn (OpenSSL, lz4, lzo) into `Wayfork/Resources/bin/`; checksums.
- [x] `scripts/dev-sign.sh`: sign app + daemon + bundled binaries with the developer's
      identity, inject Team ID into the daemon's code-signing requirement.
- [x] GitHub Actions: build, `swift-format lint`, `WayforkCore` tests on every PR.
- [x] `examples/`: `tunnel.example.ovpn`, `vless.example.txt`, `export.example.json`.

### M1 — Core (WayforkCore)

- [x] Models from [01-data-model.md](design/01-data-model.md) (`Store`, `Tunnel`, `Rule`,
      `Settings`, …), `Codable` with schema version and a migration hook; tests.
- [x] `StoreRepository`: atomic debounced writes, corrupt-file recovery, slot allocation.
- [x] `KeychainStore`: generic-password CRUD per [01-data-model.md](design/01-data-model.md),
      orphan cleanup.
- [x] Rule pattern normalization and validation (lowercase, IDNA/punycode, wildcard rules,
      duplicates, shadowing detection); tests.
- [x] OpenVPN config parser: directives, inline blocks, file inlining, strip list, rejects,
      `needsCredentials` / `needsKeyPassphrase` / remotes; tests with fixtures.
- [x] VLESS URI parser → `VLESSMeta` + UUID, validation of unsupported combos; tests.
- [x] sing-box config generator + rule-set generator from [03-routing.md](design/03-routing.md);
      golden-file tests; a test that runs `sing-box check` on every golden config when the
      binary is present.
- [x] `RuntimePlan` builder (store + Keychain → plan), plan/config hashing.
- [x] XPC payload types (`DaemonInfo`, `RuntimeStatus`, `TunnelState`, `LogLine`,
      `ApplyResult`, `DaemonError`) and the two `@objc` protocols.
- [x] Diagnostics sanitizer; tests.

### M2 — Daemon

Unprivileged logic lives in the `WayforkDaemonCore` package target (tests run without
root); `Wayfork/Daemon/` is the XPC/Security/filesystem shell. `WayforkDaemon --dev-apply`
plus `wayforkctl plan` exercise the daemon without the app (see
[05-daemon.md](design/05-daemon.md), "Developer mode").

- [x] Listener with code-signing requirement; `getInfo`, `getStatus`, `subscribe`.
- [x] Bundle path resolution and binary signature validation before spawn.
- [x] `ManagedProcess`: `posix_spawn`, stdout/stderr line readers, exit source, pid files,
      backoff restart policy.
- [x] Run directory management (`run/` 0700, temp-file + rename writes, wipe on stop, keep
      `cache.db`), startup cleanup of leftovers and stale routes.
- [x] sing-box lifecycle: write config + rule-sets, `sing-box check`, start/stop/restart,
      startup verification (`utun100` up, public address routes through it), crash counting.
- [x] Route helper: scoped default route add/delete with interface-name validation.
- [x] OpenVPN session: argv from [04-tunnels.md](design/04-tunnels.md), management socket
      client (hold release, `state`/`log`, password queries, verification failures,
      CONNECTED/RECONNECTING/EXITING), `PUSH_REPLY` DNS discovery, permanent-failure rules.
- [x] `Supervisor.apply` reconcile (diff OpenVPN by id+hash, sing-box restart vs rule-set
      rewrite), `stop`, `reconnect`, status coalescing, log batching and ring buffers.
- [x] `collectDiagnostics`.
- [ ] Verify on a real machine and record results in the design docs:
      local rule-set hot reload on file change; `utun` unit numbers ≥ 100 accepted by
      `openvpn --dev` and sing-box `interface_name`; `bind_interface` to a not-yet-existing
      interface fails per-dial, not at startup. Apply the documented fallback for any that
      fails.

### M3 — App

- [x] `AppModel` (`@MainActor`): store, settings, runtime status, derived global state.
- [x] `DaemonClient`: `NSXPCConnection`, reconnect on invalidation, version handshake,
      status/log subscription.
- [x] Helper installation flow: `SMAppService` register/status polling, approval alert,
      re-register on version/path mismatch.
- [x] Menu bar icon assets (4 variants) and state mapping with pulse while transitioning.
- [x] Popover: header + toggle + summary, tunnel cards with actions, quick add, footer.
- [x] Settings window shell: sidebar, section title, window sizing.
- [x] Settings › Tunnels: rows with inline expansion, OpenVPN/VLESS forms, `+ Add` menu,
      `.ovpn` import (picker + drop), Add VLESS sheet with live preview, delete with rules.
- [x] Settings › Rules: groups per tunnel, inline editing, drag reorder/move, shadowed and
      warning chips, search, empty state, live apply with inline errors.
- [x] Settings › General: all toggles and fields wired to `Settings`, helper status block,
      About, Export Diagnostics.
- [x] Apply pipeline: store change → plan rebuild → `apply` (debounced), reconnect-only and
      hot-reload paths behave per [03-routing.md](design/03-routing.md).
- [x] Logs window: ring buffer, filters, search, follow, copy/clear; `runtime.log` and
      `wayfork.log` mirroring with rotation and retention.
- [x] Notifications for permanent failures and engine errors.
- [x] Import/export (`wayfork-export.json`, secrets checkbox, Replace/Merge).
- [x] Launch at login (`SMAppService.mainApp`), connect on launch, quit stops everything.
- [ ] Manual end-to-end check on a clean user account: fresh install → approve helper →
      one OpenVPN + one VLESS tunnel → rules → domains reach the right exit (`curl
      --resolve`-style checks + Logs), Off restores networking.

### M3b — Default tunnel and exceptions (F8)

Added after M3; implemented once the M3 end-to-end check passes. Design in
[01-data-model.md](design/01-data-model.md), [03-routing.md](design/03-routing.md) and
[02-ux.md](design/02-ux.md) (sections marked F8).

- [x] Model: `Store.defaultTunnelID`, `RuleTarget` (`tunnel` / `direct`) with backward
      compatible JSON, export/import carry both; tests.
- [x] `RuleValidator`: duplicates inside the Direct group, tunnel rules shadowed by an
      exception, default tunnel disabled / missing secret → warning; tests.
- [x] Generator: `rules-direct.json` (user exceptions + built-in local names) as the first
      route/DNS rule, `route.final` = default tunnel, `dns.final` through the default
      tunnel (OpenVPN: pushed/custom resolver; VLESS: DoT detoured through the outbound),
      A/AAAA catch-all to fake-ip; golden files + `sing-box check`; hot reload of exceptions.
- [x] UI: "Route everything else through this tunnel" toggle in Settings › Tunnels, Direct
      group at the top of Settings › Rules, popover summary/card text, "Direct" in quick add.
- [ ] Manual check: unmatched domain exits through the default tunnel, an exception goes
      direct, LAN names still resolve, default tunnel down → unmatched traffic blocked,
      no default → behaviour identical to M3.

### M3c — Traffic rates (F9)

Design in [05-daemon.md](design/05-daemon.md) ("Traffic sampling"), [02-ux.md](design/02-ux.md)
(popover) and [03-routing.md](design/03-routing.md) (Clash API section). Implemented
2026-08-25; manual check pending.

- [x] `WayforkDaemonCore`: `ClashAPIConfig` (inject `experimental.clash_api` with a free
      loopback port and a random secret into the config the daemon writes; `sing-box check`
      still passes on every golden), `ClashConnections` decoding of `/connections`,
      `TrafficAccumulator` (per-connection deltas → per-outbound rates and running totals);
      tests with fixtures.
- [x] Daemon: `TrafficSampler` task while sing-box runs (1 Hz GET, bearer secret), totals
      survive sing-box restarts and reset on `stop`, one WARNING per failure streak;
      `WayforkClientXPC.trafficChanged`; `--dev-apply` prints a snapshot line per second.
- [x] Core/App: `TrafficSnapshot` payload, `TrafficFormat` (rate and total strings, tests),
      `AppModel.traffic` with a 3 s staleness cut-off, cleared on Off.
- [x] Popover: rate label on tunnel cards (line 1, before the action), Direct row after
      the cards, `.help` tooltips with session totals; no layout jitter (monospaced
      digits, fixed formatting).
- [ ] Manual check: rates on an OpenVPN and a VLESS card while downloading through each,
      Direct row moves for an exception, default tunnel absorbs unmatched traffic,
      figures freeze/hide on tunnel failure and disappear on Off.

### M3d — Application rules (F10)

Design in [01-data-model.md](design/01-data-model.md) ("Application rules"),
[03-routing.md](design/03-routing.md) ("Application rules") and [02-ux.md](design/02-ux.md)
(Rules). Implemented 2026-08-25; manual check pending.

- [x] Model: `RuleMatch.app` (pattern = absolute `.app` bundle path), `RulePattern.normalize`
      for bundle paths, `store.json` schema 2 with a no-op migration (older builds refuse
      the file instead of dropping the rules), export/import unchanged; tests.
- [x] `RuleValidator`: duplicate / shadowed apply as for domains, `coversTunnelServer` skips
      app rules; tests.
- [x] Generator: `process_path_regex` as a second headless rule in the tunnel and Direct
      rule-set files (`^<escaped bundle path>/`); golden variant with app rules on a tunnel
      and on Direct; `sing-box check`; hot reload unchanged.
- [x] UI: group `+` becomes a menu (Domain / Application…), open panel limited to
      application bundles, app rows with icon and display name, "not found" chip when the
      bundle is gone, search matches app names and paths.
- [ ] Manual check: an app rule sends an otherwise-unmatched domain through its tunnel, an
      app exception keeps a domain-routed site direct, helper processes are covered, DNS
      still resolves, a removed app leaves the rule flagged but harmless.

### M3e — IP rules (F11)

Design in [01-data-model.md](design/01-data-model.md) ("IP rules"),
[03-routing.md](design/03-routing.md) ("IP rules") and [02-ux.md](design/02-ux.md)
(Rules, Quick add). Shares the schema 2 bump with M3d. Implemented 2026-08-25; manual check
pending.

- [x] Model: `RuleMatch.ip`, `RulePattern.normalize` for IPv4 addresses / CIDRs (canonical
      form, host bits cleared, reserved ranges rejected), `inferMatch` picks `ip`,
      `IPv4Prefix` moves to `Support` with parsing / containment tests; export unchanged.
- [x] `RuleValidator`: duplicate / shadowed as for domains, `coversTunnelServer` for
      IP-literal servers, `coversLocalNetwork` from a caller-supplied interface list; tests.
- [x] Generator: `rules-t-<id>-ip.json` / `rules-direct-ip.json` (`ip_cidr`, always
      emitted, route-only), route rules reference both sets, `route_exclude_address` minus
      the active tunnel IP rules; golden variant `ip-rules`; `sing-box check`.
- [x] Daemon: `PlanValidator` / `RunLayout` accept the `-ip` files; nothing else changes
      (the config diff already decides reload vs restart).
- [x] UI: **IP** in the match popup, auto-switch while typing, placeholder and search cover
      IPs, "covers your LAN" chip, quick add accepts IPs.
- [ ] Manual check: `curl` to a public IP through a tunnel, an office subnet reachable
      through OpenVPN by IP, a Direct IP exception under a default tunnel, LAN and the
      router untouched, adding a LAN-range rule restarts sing-box cleanly.

### M4 — Release

Scripts and docs written 2026-08-25. 0.1.0 shipped 2026-08-26 without notarization
(no Apple Developer Program membership): signed with the Apple Development identity,
users clear the quarantine flag by hand (README, "Install"). Notarized builds come with
the membership; `release.sh` already supports them.

- [x] `scripts/release.sh`: archive, Developer ID signing, notarization, stapling, DMG
      (smoke-tested with `--skip-notarize` and an Apple Development identity: archive,
      inside-out re-signing with timestamps + hardened runtime, DMG, checksum).
- [x] README: install, first run, adding tunnels and rules, troubleshooting, limitations
      (browser DoH, IPv4-only while on — no AAAA answers, no kill switch yet, F10/F11
      caveats), releasing.
- [x] `CHANGELOG.md` for 0.1.0 (date filled in at tagging).
- [x] `scripts/release.sh --skip-notarize` falls back to the Apple Development identity;
      README "Install" documents the quarantine step, CHANGELOG lists it as a limitation.
- [x] 0.1.0: `scripts/release.sh --skip-notarize --version 0.1.0`, tag `v0.1.0`, GitHub
      release with the DMG and its `.sha256`.
- [ ] First notarized build once a Developer ID identity and a notarytool profile exist.

### M5 — System resolver override (F12)

Design in [03-routing.md](design/03-routing.md) ("Notes on specific choices") and
[05-daemon.md](design/05-daemon.md) ("System resolver override"). Implemented 2026-08-26;
manual check pending.

- [x] Core: `Settings.overrideSystemDNS`, `RuntimePlan.overrideSystemDNS` (in the plan
      hash), `RuntimeStatus.resolverOverride`, `SystemDNS.Snapshot` reads the primary
      service's manual (`Setup:`) resolvers and the generator protects the *effective* ones;
      DDR (`_dns.resolver.arpa`) refused, 443/853 to the resolvers rejected.
- [x] DaemonCore: `ResolverOverridePlanner` — pure decisions (write / restore / nothing and
      the resulting state) over a resolver snapshot and the saved record; tests.
- [x] Daemon: `ResolverOverride` actor — the primary service's manual DNS
      (`Setup:/Network/Service/<primary>/DNS` via `SCPreferences`), `run/dns-override.json`
      record with the verbatim original, probe through `getaddrinfo` with back-out,
      re-applied on user edits and primary-service changes, restored on stop, crash
      backoff, SIGTERM and at bootstrap.
- [x] App: plan flag from Settings, status logging (active / failed), toggle in
      Settings › General › DNS.
- [ ] Manual check: `scutil --dns` shows 172.19.0.2 without `if_index` while On and the
      previous setting after Off; `dscacheutil -q host -a name probe.wayfork.internal` →
      172.19.0.2 and `<office host>` → fake IP; Wi-Fi → Ethernet switch keeps the
      override; `kill -9` of the daemon → resolver restored at next launch; a manual DNS
      entry made before Turn On comes back after Turn Off.
      Two dead ends on 2026-08-26: the TUN's own address 172.19.0.1 (mDNSResponder treats
      it as loopback) and `State:` (resolver scoped to en0 by `if_index`); both left
      OpenVPN unable to resolve its server.

### M6 — Hardening (field findings, 2026-09-01)

Phase 1 above, § "Hardening (field findings, 2026-09-01)"; design in
[design/03-routing.md](design/03-routing.md) ("Startup verification") and
[design/05-daemon.md](design/05-daemon.md) ("Engine failure recovery"). The Windows half
is tracked in [ROADMAP-windows.md](ROADMAP-windows.md) § WM7 and lands together with it.

- [x] H1: `SingBoxEngine.start` polls the startup check every 500 ms for up to 12 s
      (`startupPoll` / `startupTimeout`) instead of checking once after `startupGrace`, and
      retries the start once before `singbox.startFailed`; `abortStartup()` from
      `Supervisor.apply` / `stop` so a user's Turn Off never waits out a doomed start.
- [x] H2: `RecoveryBackoff` (WayforkCore, 5, 15, 30, 60, 120, 300 s) drives an automatic
      re-apply while the engine is failed and the user wants routing on; one notification
      per failure streak ("Wayfork keeps retrying"), no alert per retry, backoff reset when
      the engine runs and on Turn On / Turn Off. The `error` menu bar icon and the summary
      line were already derived from `GlobalState.error`.
- [x] H3: dead-UDP detector in Traffic and the diagnostics report. `TrafficAccumulator`
      counts, per exit, UDP flows with cumulative up > 0, down == 0 and an age ≥ 10 s;
      the count crosses XPC as `TrafficCounters.oneWayUDPFlows` (aggregate only — the F9
      privacy rule stands, no protocol change needed), shows as an orange ⚠ with a hint
      on the tunnel card, logs one daemon WARNING per tunnel per streak, and lands in a
      `## traffic` section of the diagnostics `system.txt`. Tested on the extended
      `fixtures/clash/connections.json` (design: 05-daemon.md, 02-ux.md).
- [x] H4: `reverse_mapping` dropped from the generator **except when a default tunnel is
      set** — there it is what keeps unsniffable flows to Direct exceptions out of the
      default tunnel (the 2026-08-26 gitlab regression), and the fake-ip catch-all shrinks
      the poisoning surface to the user's own exception domains; without a default tunnel
      it could only mislabel (03-routing.md records the decision). Goldens regenerated
      once; the Swift, Dart and Go suites pass, cross-client plan-hash pin re-pinned.
- [ ] Manual check: a slow `utun100` bring-up is not killed any more (start with a cold
      TUN and watch the log); with another VPN holding the interface, the menu bar goes to
      error, one notification arrives, and Wayfork comes back on its own once that VPN is
      off; Turn Off during a failing start answers immediately.

### M7 — Actionable dead-UDP hint (H5)

Phase 1 above, § "Hardening", H5. Stages, decisions and per-step checkboxes live in
[roadmap/dead-udp-suggestions.md](roadmap/dead-udp-suggestions.md); this milestone tracks
only the shipped outcome. The Windows half is [ROADMAP-windows.md](ROADMAP-windows.md)
§ WM8 and lands together with it.

- [ ] Design notes: the details request in [design/05-daemon.md](design/05-daemon.md)
      (amending the F9 privacy note), the flyout and its wording in
      [design/02-ux.md](design/02-ux.md).
- [ ] Daemon: a user-initiated `oneWayUDPDetails(tunnelID)` over XPC — aggregated rows,
      capped, nothing streamed and nothing logged.
- [ ] App: the ⚠ opens the details, each row offers **Try Direct** with an editable `/32`
      prefill; the affordance disappears when the request fails or comes back empty.
- [ ] Manual check: with a tunnel whose server drops UDP, the hint names the process and
      the destination, and **Try Direct** lands a working rule.

### M8 — More tunnel types (F13)

Phase 1 above, § F13. Stages, decisions and per-step checkboxes live in
[roadmap/more-tunnel-types.md](roadmap/more-tunnel-types.md); this milestone tracks only
the shipped outcome. The Windows half is [ROADMAP-windows.md](ROADMAP-windows.md) § WM9
and follows kind by kind, on the fixtures this milestone produces.

- [ ] Design notes: per-kind sections (grammar → meta → sing-box JSON → validation) in
      [design/04-tunnels.md](design/04-tunnels.md), DNS per kind in
      [design/03-routing.md](design/03-routing.md), kinds and secret keys in
      [design/01-data-model.md](design/01-data-model.md), the add flows and per-kind card
      fields in [design/02-ux.md](design/02-ux.md).
- [x] Core: `TunnelKind` cases and metas, `WireGuardConfParser` and `ProxyLinkParser` with
      their fixtures, the shared TLS/transport helpers split out of `vlessOutbound`,
      generator builders (WireGuard as an `endpoints[]` entry), the golden variants
      `wireguard`, `default-wireguard` and `proxy-links`, `RuntimePlanBuilder` secrets,
      `wayforkctl --link` / `--wireguard`. Also new: `everyReferencedTagIsDefined`, which
      catches the dangling tags `sing-box check` silently accepts.
- [x] App: **Add** menu with *Add WireGuard…* and *Add from link…*, `.conf` accepted by the
      drop target and the seed importer, per-kind card fields and badges, masked link
      **Copy** for every link kind (`AddLinkSheet` replaces the VLESS-only sheet;
      `AddWireGuardSheet` takes a file or pasted text and warns on a narrow `AllowedIPs`).
- [x] Subscriptions (stage 7): `SubscriptionDecoder` + `SubscriptionFetcher`, the
      *Add from link…* sheet fetching a URL into a checklist, `AppModel.addLinks`
      (2026-09-12; the live check is in the plan file).
- [ ] Manual check: one tunnel per kind the maintainer has a server for carries traffic
      through a domain rule; WireGuard as the default tunnel resolves DNS through the
      endpoint with no leak.

### M9 — Tunnel latency (F14)

Phase 1 above, § F14. Design first: measurement, sampling and the snapshot field in
[design/05-daemon.md](design/05-daemon.md), the card, sparkline and *unreachable* state in
[design/02-ux.md](design/02-ux.md), the Windows deltas in
[design/08-windows.md](design/08-windows.md). Not started; the design is written and
approved before any of the boxes below.

- [x] Design notes as listed above (written 2026-09-15; 03-routing.md § Tunnel latency
      probe, 05-daemon.md § Tunnel latency, 07-rule-testing.md § Probe).
- [ ] Daemon: periodic probe per connected tunnel, latency and probe failures in the
      traffic snapshot.
- [ ] App: current latency next to the rates, sparkline on the card, *unreachable* state —
      the card of variant C board C1 (number + unit, band colour, 2-minute sparkline at
      24 pt); the Probe line of board C5 in rule testing.
- [ ] Windows: the same in the Go service and the Flutter card
      ([ROADMAP-windows.md](ROADMAP-windows.md)).
- [ ] Manual check: the number tracks a known-slow tunnel; pulling the server's plug turns
      the card *unreachable* within the designed window and back on reconnect.

### M10 — Friendlier screens (variant C, existing features only)

The variant C redraw applied to what already ships, before any F15–F18 code: the fixes in
the friction audit at the top of
[design/prototype/variant-c.html](design/prototype/variant-c.html). Design notes first
([design/02-ux.md](design/02-ux.md): strings, states, empty states), then the views.
Boards C1, C2, C3 (light), C4 (without the Recent strip and the group section), C6
(without the Blocking section).

- [x] 02-ux.md: wording table (old → new), status words per tunnel state, empty states
      (no tunnels yet, tunnel with no rules), the popover summary lines, the General rows.
      — § Variant C (2026-09-15).
- [ ] Popover: 360 pt wide, section headers, card line 2 = status word + at most two facts,
      *Idle* instead of zero rates, Retry only on a card with something to retry, *Fix…* on
      a failed tunnel, "Not via any tunnel" row, off / can't-connect / first-run states.
- [ ] Settings › Tunnels: row = status in words + protocol demoted to the subtitle, expanded
      form per C3 (Login + password on one line, "From the tunnel", "Everything else",
      "Imported ‹date›").
- [ ] Settings › Rules: group headers say what they mean, "Not via any tunnel" for the
      Direct group, match kinds "and subdomains / exactly this / pattern / the app",
      "+ Add site", shadowed chip as a sentence, empty state per group.
- [ ] Settings › General: rows reworded per C6, "Service/Helper up to date".
- [ ] README screenshots re-rendered from variant C.
- [ ] Manual check: the maintainer walks the popover and the three Settings pages against
      the boards; strings match the 02-ux.md table.

### M11 — Recent domains → rule (F15)

Phase 1 above, § F15; stage 3 of [roadmap/next-features.md](roadmap/next-features.md)
writes the design (05-daemon.md: the recent-hosts list in the snapshot;
00-architecture.md § 7 amended for per-connection hosts crossing to the app; 02-ux.md:
the Recent section and strip, boards C1 and C4).

- [x] Design notes as listed above (2026-09-15).
- [ ] `WayforkCore`: snapshot field `recentHosts` (host, process, tunnel, lastSeen),
      capped at 200, cleared when the state leaves *on*; never written to disk or logged
      at `info`.
- [ ] Daemon: fill it from the F9 `/connections` poll — default-route flows only, domains
      covered by a rule excluded.
- [ ] App: the Recent section in the popover (five rows, *Route via ▾*, hide for the
      session, empty state) and the strip on the Rules page (three rows, *Show all*).
- [ ] *Route via* creates a suffix rule for the registrable domain and removes the row.
- [ ] Manual check: open a site in Safari, it appears within one poll; route it, it leaves
      the list and the next request goes through the chosen tunnel.

### M12 — Tunnel groups (F16)

Phase 1 above, § F16. The only feature of the wave that changes the model: rule targets
become tunnel-or-group. Design in 01-data-model.md (`TunnelGroup`), 03-routing.md
(`urltest` / `selector`, new goldens), 05-daemon.md (*first live* switching, or the
decision that `urltest` with `tolerance` covers it), 02-ux.md (boards C1, C3, C7).

- [x] Design notes as listed above; the *first live* vs `urltest` question decided there
      (2026-09-15: both kept, *first live* = daemon-driven `selector`).
- [ ] `WayforkCore`: `TunnelGroup` (name, ordered members, policy) in `store.json`, rule
      and default-tunnel targets widened, validation (no nested groups, ≥ 2 members).
- [ ] Generator: `urltest` (fastest) / `selector` (first live) outbounds, goldens.
- [ ] Daemon: active member in the snapshot; the *first live* switch if the design keeps it.
- [ ] App: group card (popover and Settings) with members and the member in use, *New
      group…* sheet (C7), group in every tunnel picker, group section on the Rules page.
- [ ] Manual check: a two-member group with one member unplugged serves its rules through
      the other; both up, *fastest* follows the lower F14 number.

### M13 — Local proxy port per tunnel (F17)

Phase 1 above, § F17. Design in 01-data-model.md (port fields), 03-routing.md (`mixed`
inbounds, `inbound → outbound` rules, DNS through the tunnel's resolver — verified with the
generator before the design is final), 02-ux.md (board C3). LAN sharing is out unless
approved separately.

- [x] Design notes as listed above (2026-09-15).
- [ ] `WayforkCore`: `localProxy` (enabled, port) per tunnel and group; port chosen by the
      app (stable, starting at 1081), editable, unique.
- [ ] Generator: one `mixed` inbound per enabled port, one route rule, DNS detour; goldens.
- [ ] App: the *Local proxy* row in the expanded card — switch, `127.0.0.1:‹port›`, Copy,
      one-line hint.
- [ ] Manual check: `curl --proxy socks5h://127.0.0.1:‹port› https://ifconfig.me` shows the
      tunnel's exit address with no rule for that host; the DNS query does not go direct.

### M14 — Block lists (F18)

Phase 1 above, § F18. Design in 03-routing.md (`block` outbound + rule-set), 05-daemon.md
(list source and refresh job — lean: bundled list + optional refresh from a pinned URL,
decided in the design note), 01-data-model.md (switch and exceptions in `store.json`),
02-ux.md (boards C5 "Blocked" result and C6).

- [x] Design notes as listed above; list source decided (2026-09-15: bundled OISD small,
      refresh deferred to L1).
- [ ] List: bundled with the app, refresh job in the daemon if the design keeps it.
- [ ] Generator: `block` rule-set, exceptions as a rule ahead of it, NXDOMAIN from the
      fake-ip resolver; goldens.
- [ ] Daemon: blocked-flow counter in the F9 snapshot.
- [ ] App: the *Blocking* section in General (switch, "Blocked N today", list age,
      *Update now*, *Never block* chips), the *Blocked* result in the Probe line.
- [ ] Manual check: a known ad host fails fast in the browser with the switch on and loads
      with it in *Never block*; the counter moves.
