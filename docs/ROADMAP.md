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

### Later

**L1. Rule sources beyond a single domain**
- Domain lists from a URL or file (e.g. GeoSite-style lists), auto-refreshed.
- Rules by IP / CIDR and by process (application-based routing).
- Import rules from a Surge / Clash / sing-box rule-set.

**L2. Rule testing**
- "Where does `<domain>` go?" — resolve which rule/tunnel matches and why.
- Live connection view: active connections with domain, tunnel, bytes.

**L3. More tunnel types**
- WireGuard configs, Shadowsocks, Trojan, Hysteria2 (all native to sing-box).
- Subscription URLs that yield a list of servers.

**L4. Tunnel health**
- Periodic latency/availability checks per tunnel.
- Failover: a rule can list a fallback tunnel used when the primary is down.
- Traffic counters per tunnel.

**L5. Profiles**
- Named sets of rules (e.g. "work", "home") switchable from the menu bar.

**L6. Distribution and updates**
- Signed and notarized builds, Homebrew cask, in-app updates (Sparkle).
- Update bundled sing-box / openvpn independently of the app.

**L7. Nice-to-haves**
- Global hotkey for the main switch.
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

- [ ] Models from [01-data-model.md](design/01-data-model.md) (`Store`, `Tunnel`, `Rule`,
      `Settings`, …), `Codable` with schema version and a migration hook; tests.
- [ ] `StoreRepository`: atomic debounced writes, corrupt-file recovery, slot allocation.
- [ ] `KeychainStore`: generic-password CRUD per [01-data-model.md](design/01-data-model.md),
      orphan cleanup.
- [ ] Rule pattern normalization and validation (lowercase, IDNA/punycode, wildcard rules,
      duplicates, shadowing detection); tests.
- [ ] OpenVPN config parser: directives, inline blocks, file inlining, strip list, rejects,
      `needsCredentials` / `needsKeyPassphrase` / remotes; tests with fixtures.
- [ ] VLESS URI parser → `VLESSMeta` + UUID, validation of unsupported combos; tests.
- [ ] sing-box config generator + rule-set generator from [03-routing.md](design/03-routing.md);
      golden-file tests; a test that runs `sing-box check` on every golden config when the
      binary is present.
- [ ] `RuntimePlan` builder (store + Keychain → plan), plan/config hashing.
- [ ] XPC payload types (`DaemonInfo`, `RuntimeStatus`, `TunnelState`, `LogLine`,
      `ApplyResult`, `DaemonError`) and the two `@objc` protocols.
- [ ] Diagnostics sanitizer; tests.

### M2 — Daemon

- [ ] Listener with code-signing requirement; `getInfo`, `getStatus`, `subscribe`.
- [ ] Bundle path resolution and binary signature validation before spawn.
- [ ] `ManagedProcess`: `posix_spawn`, stdout/stderr line readers, exit source, pid files,
      backoff restart policy.
- [ ] Run directory management (`run/` 0700, temp-file + rename writes, wipe on stop, keep
      `cache.db`), startup cleanup of leftovers and stale routes.
- [ ] sing-box lifecycle: write config + rule-sets, `sing-box check`, start/stop/restart,
      startup verification (`utun100` up, default route), crash counting.
- [ ] Route helper: scoped default route add/delete with interface-name validation.
- [ ] OpenVPN session: argv from [04-tunnels.md](design/04-tunnels.md), management socket
      client (hold release, `state`/`log`, password queries, verification failures,
      CONNECTED/RECONNECTING/EXITING), `PUSH_REPLY` DNS discovery, permanent-failure rules.
- [ ] `Supervisor.apply` reconcile (diff OpenVPN by id+hash, sing-box restart vs rule-set
      rewrite), `stop`, `reconnect`, status coalescing, log batching and ring buffers.
- [ ] `collectDiagnostics`.
- [ ] Verify on a real machine and record results in the design docs:
      local rule-set hot reload on file change; `utun` unit numbers ≥ 100 accepted by
      `openvpn --dev` and sing-box `interface_name`; `bind_interface` to a not-yet-existing
      interface fails per-dial, not at startup. Apply the documented fallback for any that
      fails.

### M3 — App

- [ ] `AppModel` (`@MainActor`): store, settings, runtime status, derived global state.
- [ ] `DaemonClient`: `NSXPCConnection`, reconnect on invalidation, version handshake,
      status/log subscription.
- [ ] Helper installation flow: `SMAppService` register/status polling, approval alert,
      re-register on version/path mismatch.
- [ ] Menu bar icon assets (4 variants) and state mapping with pulse while transitioning.
- [ ] Popover: header + toggle + summary, tunnel cards with actions, quick add, footer.
- [ ] Settings window shell: sidebar, section title, window sizing.
- [ ] Settings › Tunnels: rows with inline expansion, OpenVPN/VLESS forms, `+ Add` menu,
      `.ovpn` import (picker + drop), Add VLESS sheet with live preview, delete with rules.
- [ ] Settings › Rules: groups per tunnel, inline editing, drag reorder/move, shadowed and
      warning chips, search, empty state, live apply with inline errors.
- [ ] Settings › General: all toggles and fields wired to `Settings`, helper status block,
      About, Export Diagnostics.
- [ ] Apply pipeline: store change → plan rebuild → `apply` (debounced), reconnect-only and
      hot-reload paths behave per [03-routing.md](design/03-routing.md).
- [ ] Logs window: ring buffer, filters, search, follow, copy/clear; `runtime.log` and
      `wayfork.log` mirroring with rotation and retention.
- [ ] Notifications for permanent failures and engine errors.
- [ ] Import/export (`wayfork-export.json`, secrets checkbox, Replace/Merge).
- [ ] Launch at login (`SMAppService.mainApp`), connect on launch, quit stops everything.
- [ ] Manual end-to-end check on a clean user account: fresh install → approve helper →
      one OpenVPN + one VLESS tunnel → rules → domains reach the right exit (`curl
      --resolve`-style checks + Logs), Off restores networking.

### M4 — Release

- [ ] `scripts/release.sh`: archive, Developer ID signing, notarization, stapling, DMG.
- [ ] README: install, first run, adding tunnels and rules, troubleshooting, limitations
      (browser DoH, IPv4-only OpenVPN, no kill switch yet).
- [ ] `CHANGELOG.md`, version tagging `v0.1.0`.
