# Roadmap

Work proceeds strictly phase by phase. A phase is closed only after explicit maintainer
approval; the next phase is not started before that.

| Phase | Deliverable | Status |
|---|---|---|
| 1. Features | Feature list below, split into MVP / Later | approved 2026-08-25 |
| 2. Design | `docs/design/*.md` — UX + technical design per feature | approved 2026-08-25 |
| 2b. UI prototype | `docs/design/prototype/index.html` — static HTML mockups of every MVP screen, approved before implementation | variant B approved 2026-08-25 |
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
- A resolver typed by hand in System Settings › Network › DNS takes precedence over the
  override; Wayfork warns and leaves it alone.
- Setting "Use Wayfork as the system resolver while On" (on by default) turns it off for
  people who run their own resolver setup.

### Later

**L1. Rule sources beyond a single domain**
- Domain lists from a URL or file (e.g. GeoSite-style lists), auto-refreshed.
- Import rules from a Surge / Clash / sing-box rule-set.

**L2. Rule testing**
- "Where does `<domain>` go?" — resolve which rule/tunnel matches and why. Design:
  [design/07-rule-testing.md](design/07-rule-testing.md) (2026-08-25, not scheduled).
- Live connection view: active connections with domain, tunnel, bytes.

**L3. More tunnel types**
- WireGuard configs, Shadowsocks, Trojan, Hysteria2 (all native to sing-box).
- Subscription URLs that yield a list of servers.
- VLESS over XHTTP via a bundled Xray-core: sing-box has no XHTTP transport (1.13.19
  rejects `xhttp`/`splithttp`; upstream declined it), so each XHTTP tunnel runs its own
  `xray` process with a local SOCKS5 inbound and sing-box reaches it through a `socks`
  outbound — the OpenVPN per-process model with a port instead of a `utun`. Needs a pinned,
  signed `xray` binary (`com.wayfork.bin.xray`), an `XrayRuntime` entry in the plan, an
  xray config generator, `type=xhttp` in the URI parser and a process-path direct rule for
  xray's own traffic. See [design/04-tunnels.md](design/04-tunnels.md).

**L4. Tunnel health**
- Periodic latency/availability checks per tunnel.
- Failover: a rule can list a fallback tunnel used when the primary is down.
- Traffic history per tunnel (sparkline, totals per day) on top of the F9 rates.

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

Scripts and docs written 2026-08-25; the first notarized build and the tag wait for the
maintainer (Developer ID identity and notarytool profile are not on the build machine).

- [x] `scripts/release.sh`: archive, Developer ID signing, notarization, stapling, DMG
      (smoke-tested with `--skip-notarize` and an Apple Development identity: archive,
      inside-out re-signing with timestamps + hardened runtime, DMG, checksum).
- [x] README: install, first run, adding tunnels and rules, troubleshooting, limitations
      (browser DoH, IPv4-only while on — no AAAA answers, no kill switch yet, F10/F11
      caveats), releasing.
- [x] `CHANGELOG.md` for 0.1.0 (date filled in at tagging).
- [ ] First notarized build (`scripts/release.sh --version 0.1.0`), tag `v0.1.0`, GitHub
      release with the DMG and its `.sha256`.

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
- [x] Daemon: `ResolverOverride` actor — `State:/Network/Service/<primary>/DNS` via
      `SCDynamicStore`, `run/dns-override.json` record, re-applied on configd rewrites and
      primary-service changes, restored on stop, crash backoff, SIGTERM and at bootstrap.
- [x] App: plan flag from Settings, status logging (active / shadowed by manual DNS /
      failed), toggle in Settings › General › DNS.
- [ ] Manual check: `scutil --dns` shows 172.19.0.1 while On and the DHCP resolver after
      Off; `dscacheutil -q host -a name <office host>` → fake IP; Wi-Fi → Ethernet switch
      keeps the override; `kill -9` of the daemon → resolver restored at next launch;
      manual DNS in System Settings → warning in the log and `scutil --dns` unchanged.
