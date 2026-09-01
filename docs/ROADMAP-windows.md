# Roadmap — Windows

Windows client of Wayfork. Same product, same rules and tunnels, same `sing-box.json`
contract as the macOS app; a second native client, not a port. The macOS roadmap is
[ROADMAP.md](ROADMAP.md); feature numbers (F1–F12) below refer to it.

Work proceeds phase by phase exactly as on macOS: a phase is closed only after explicit
maintainer approval.

| Phase | Deliverable | Status |
|---|---|---|
| W0. Decisions | Stack, layout, parity target — the table below | approved 2026-08-27 |
| W1. Features | Per-feature Windows deltas against F1–F12 | approved 2026-08-27 |
| W2a. Feasibility spike | Manual run of the routing scheme on a Windows machine, go/no-go | **done 2026-08-27 — GO** (results in [design/08-windows.md](design/08-windows.md) § Spike); `bind_interface` + a metric-9999 scoped default on the dco/TAP adapter routes per tunnel without touching the system default, NRPT `.` is the airtight resolver override, job objects kill children with the parent |
| W2b. Design | `docs/design/08-windows.md` — every platform delta, written after the spike | approved 2026-08-27 (all 10 sections from the W2a results) |
| W2c. UI prototype | `docs/design/prototype/windows.html` — tray flyout + context menu, main window (Dashboard/Tunnels/Rules/General/Logs), first-run, service-missing | approved 2026-08-27 (8 boards, ported from variant-b.html) |
| W3. Implementation | Milestones WM0–WM5 below | WM0/WM1/WM2 done and pushed, WM2 verified in the VM 2026-08-28; WM3 (Flutter app) in progress — WM3a-WM3f done (WM3a-WM3c VM-verified), full VM run of the UI left |

## Phase W0 — Decisions

| Topic | Decision | Why |
|---|---|---|
| Engine | sing-box (TUN via wintun, fake-ip, sniff, DNS `detour`, `bind_interface`) + one `openvpn.exe --route-nopull` per OpenVPN tunnel on its own adapter | identical to macOS; the config contract is shared |
| UI | Flutter (Dart), Windows target only | maintainer's stack; tray + one main window is a proven shape (Hiddify) |
| Privileged part | Go Windows service (`golang.org/x/sys/windows/svc`), installed by the MSI | Dart cannot host a service; Go has `winipcfg` (routes, DNS, metrics) and native service/pipe support |
| App ↔ service IPC | named pipe, newline-delimited JSON, versioned payloads mirroring the XPC ones | no ffi in Dart for a pipe client beyond `win32`; JSON keeps the plan human-readable in `--dev-apply` |
| Where logic lives | Dart = `WayforkCore` (models, rule normalization, `.ovpn` / VLESS parsers, generator, plan builder); Go = `WayforkDaemonCore` (plan validation, supervisor, routes, DNS, management client, sampler) | same split as macOS, so the design docs apply file by file |
| Secrets | DPAPI (user scope) blobs under `%LOCALAPPDATA%\Wayfork\secrets\`; decrypted by the app and sent in the plan | Credential Manager caps blobs at 2.5 KB — inline certs do not fit; the service runs as SYSTEM and cannot use user DPAPI anyway |
| Repo | monorepo: `WayforkWindows/{app,service}`, shared `fixtures/` | one design, one changelog, one version per release |
| Parity target | F1–F12 except where the table in W1 says otherwise; Later items stay Later | ship the same product, then diverge only where Windows forces it |
| Not doing | WinUI 3, C#, Swift on Windows, embedding sing-box as libbox, a macOS Flutter rewrite | see chat 2026-08-27; revisit only with a reason |

## Phase W1 — Features

What changes for the user compared with the macOS feature list. Everything not listed
behaves as on macOS.

**F1. Tunnel configs** — same. Secrets go to DPAPI-protected files instead of Keychain.

**F2. Rules: domain → tunnel** — same, including quick add from the tray menu.

**F3. Start / stop**
- The privileged helper is a Windows service installed by the MSI; the one UAC prompt is
  the installer's. No Login Items step, no approval polling.
- Off restores routes and DNS; so does service start after a crash or reboot.

**F4. Status**
- Tray icon with the same four states; a *tray menu* (native context menu) instead of the
  popover: global switch, tunnels with state and rule count, quick add, Open Wayfork, Quit.
- The main window opens on a **Dashboard** page that holds the popover content (tunnel
  cards, rates, Direct row); Tunnels / Rules / General / Logs are sidebar pages.

**F5. Logs and diagnostics** — same. App log under `%LOCALAPPDATA%\Wayfork\Logs`, service
and child logs under `%ProgramData%\Wayfork\`; diagnostics zip covers both.

**F6. Settings** — launch at login via `HKCU\…\Run`; everything else identical.

**F7. Import / export** — same file format, so an export from the Mac imports on Windows and
back. Application rules (F10) carry platform paths and are imported as *not found*.

**F8. Default tunnel and exceptions** — same.

**F9. Traffic rates** — same (Clash API), shown on the Dashboard cards.

**F10. Rules: application → tunnel** — an application is an `.exe`; the rule covers that
executable only (there is no bundle to enclose helpers). *Application…* opens a picker that
lists what is **running right now** — one entry per executable, named by the version info's
`FileDescription` — with *Browse…* falling back to the file dialog for an app that is not
started. Display name comes from the file's version info; there is no icon (see
[08-windows.md](design/08-windows.md) § Flutter app).

**F11. Rules by IP address / subnet** — same; the "covers your LAN" warning reads the
adapters through `GetAdaptersAddresses`.

**F12. System resolver override**
- While On, the DNS servers of every active non-Wayfork adapter are replaced with
  Wayfork's resolver and restored when Off, on crash recovery and at service start.
- Why the TUN's own DNS entry is not enough: Windows queries the resolvers of *all*
  adapters in parallel (multi-homed name resolution), so a physical adapter that still
  points at the router leaks and races. The spike decides between per-adapter override
  and an NRPT catch-all rule; the design doc records the outcome.
- Same setting, same default (on).

### Windows-only notes

- IPv4-only while On, as on macOS: no AAAA answers, IPv6 stays outside the TUN.
- Browser DoH, no kill switch, F10/F11 caveats — the README limitations apply verbatim.
- SmartScreen warns on an unsigned or new-certificate build; documented like the macOS
  quarantine step until an EV/OV certificate has reputation.

### Later (Windows)

- **LW1.** Rule by folder: "every `.exe` under this directory" — the helper-process case
  F10 loses without bundles.
- **LW2.** Auto-update (MSI major upgrade from a GitHub release).
- **LW3.** Linux client on the same Flutter + Go code (the only reason Flutter has a
  Linux target checkbox; not planned).

## Phase W2a — Feasibility spike

Manual, on a Windows 11 machine, before a line of Dart or Go. Every item ends with a
yes/no and a note; a "no" changes the design, not the roadmap. Uses the pinned sing-box
Windows release and the official OpenVPN MSI (files extracted with `msiexec /a`).

- [x] **sing-box TUN.** `sing-box run` as Administrator with the golden config adapted
      (`interface_name: Wayfork`, `inet4_address`, `auto_route`, fake-ip, `hijack-dns`):
      adapter appears, default route goes through it, `curl` to a public host works,
      `sing-box check` passes. Then the same under `psexec -s` (session 0, SYSTEM) — the
      service's situation.
- [x] **OpenVPN adapters.** Which driver the pinned `openvpn.exe` still supports
      (`--windows-driver ovpn-dco` is the 2.6 default; `wintun` may be gone; `tap-windows6`
      is the fallback). How a named adapter is created (`tapctl create --name Wayfork-1
      --hwid <driver>`), whether it survives reboot, and whether Windows ever renames it
      (`Wayfork-1 2`). Driver installation needs `pnputil` — record whether the MSI can do
      it silently.
- [x] **OpenVPN with `--route-nopull`.** `openvpn --route-nopull --dev-node Wayfork-1
      --management 127.0.0.1 <port> --management-hold`: connects while the sing-box TUN is
      up (its own traffic must stay direct — same process-path rule as on macOS), the
      management protocol matches [04-tunnels.md](design/04-tunnels.md) (`state`, `log`,
      password queries, `Opened … device` line differs — record the Windows wording).
- [x] **`bind_interface` on Windows.** A `direct` outbound with `bind_interface:
      Wayfork-1` and no routes pushed: does the packet leave through the tunnel? If not,
      find the smallest route that makes it work (expected: a default route on the
      adapter with metric 9999 via `winipcfg` / `route add … IF <idx>`) and confirm it does
      not disturb the system default. This is the go/no-go item.
- [x] **Two OpenVPN tunnels + one VLESS** at once, rules pointing at each, `curl --resolve`
      style checks show the right exit per domain. Clash API `/connections` reports per
      outbound.
- [x] **DNS.** With the physical adapter still pointing at the router: do queries leak
      (Wireshark on the LAN side)? Then with the adapter's DNS set to the TUN resolver, and
      separately with an NRPT rule — which one is airtight, which one survives a
      Wi-Fi ↔ Ethernet switch, what `Get-DnsClientServerAddress` shows for restore.
- [x] **Teardown.** Kill sing-box and openvpn mid-run: what is left (routes, adapter DNS,
      adapters) and what a service would have to clean at start.
- [x] **Job objects.** Children started under a job with `KILL_ON_JOB_CLOSE` die with the
      parent — the Windows replacement for pid files.
- [x] Write the results into `docs/design/08-windows.md` § Spike and close the phase.

## Phase W2b — Design

`docs/design/08-windows.md`, one document that lists the deltas against
[00](design/00-architecture.md)–[06](design/06-logging.md) section by section; anything
not mentioned there applies unchanged. Contents:

- Components and trust boundary: service (SYSTEM), app (user), children under a job
  object; pipe ACL and client verification (`GetNamedPipeClientProcessId` → image path
  inside the install directory + Authenticode check, the counterpart of the code-signing
  requirement).
- Filesystem: `%ProgramFiles%\Wayfork\` (exe, dlls, `bin\`), `%ProgramData%\Wayfork\run\`
  (config, rule-sets, `cache.db`, records, logs), `%LOCALAPPDATA%\Wayfork\`
  (`store.json`, secrets, app log); permissions per directory.
- IPC: pipe name, framing, `getInfo` / `getStatus` / `subscribe` / `apply` / `stop` /
  `reconnect` / `collectDiagnostics` as JSON messages; version handshake; reconnect.
- Adapters: names (`Wayfork`, `Wayfork-1`…`Wayfork-32`), creation/removal, driver choice
  from the spike, how the plan carries the adapter name instead of a `utun` unit.
- Routes: what replaces `route -ifscope`, table cleanup at start.
- Resolver override: mechanism from the spike, record file, restore on every exit path,
  re-apply on adapter changes (`NotifyIpInterfaceChange`).
- Lifecycle: service starts at boot idle, app connects, app quit stops everything (as on
  macOS), service stop restores networking, MSI upgrade stops and restarts the service.
- Logging: paths, rotation, what the diagnostics zip includes on Windows.
- Installer: WiX authoring, service registration, driver install, upgrade and uninstall
  (restore DNS, delete adapters, keep user data).
- Open items marked *(verify)* with fallbacks, like the macOS docs.

## Phase W2c — UI prototype

`docs/design/prototype/windows.html`, static like variant B: tray menu, main window with
Dashboard / Tunnels / Rules / General / Logs, first-run state, service-missing alert.
Content and copy copied from [variant-b.html](design/prototype/variant-b.html); only the
window chrome, sidebar and tray menu are new. Approved before WM3.

## Phase W3 — Implementation

Targets: `WayforkWindows/app` (Flutter), `WayforkWindows/service` (Go, module
`wayfork/service`) with `internal/core` (the `WayforkDaemonCore` counterpart, no
privileges, fully testable) and `cmd/wayfork-service`, `cmd/wayforkctl`. Shared
`fixtures/` are read by the Swift, Dart and Go tests.

### WM0 — Scaffolding

- [x] Move the golden inputs/outputs of the Swift tests (tunnels + rules → `sing-box.json`
      and rule-set files, `.ovpn` fixtures, VLESS URIs, Clash API samples) to `fixtures/`;
      Swift tests read them from there; CI still green. *(2026-08-27: `fixtures/{singbox,
      ovpn,vless,clash}` + README; each sing-box variant now records its `input.json`;
      `vless/links.json` holds accepted links with results and rejected ones.)*
- [x] `WayforkWindows/app`: `flutter create --platforms=windows`, pinned Flutter/Dart
      versions in `WayforkWindows/versions.env`, dependencies pinned to exact versions
      (`tray_manager`, `window_manager`, `fluent_ui`, `win32`, `path_provider`); `dart
      format` + `dart analyze` clean. *(Windows runner rendered from Flutter's template —
      `flutter create` skips it on macOS; Fluent shell + smoke test in place.)*
- [x] `WayforkWindows/service`: Go module, pinned Go version, `golang.org/x/sys`,
      `golang.zx2c4.com/wireguard/windows` (`winipcfg`); `gofmt` + `go vet` clean;
      `go test ./...` runs on macOS for the pure packages (build tags keep Win32 out).
- [x] `scripts/fetch-win-bins.ps1`: sing-box Windows amd64 zip (wintun is embedded in the
      binary — no separate `wintun.dll`), OpenVPN files extracted from the pinned MSI
      (`openvpn.exe`, `tapctl.exe`, driver package); checksums in `scripts/versions.env`.
      *(Verified in the spike VM: the driver comes out of the MSI's embedded cabinet, see
      08-windows.md § Installer.)*
- [x] GitHub Actions: `windows-latest` job (flutter build, dart tests, go tests, go vet)
      with path filters so it runs only on `WayforkWindows/`, `fixtures/`, `scripts/`
      changes; the macOS job gets the mirror filter. *(`ci-windows.yml`; first real run
      happens on push.)*
- [x] `.gitignore`: `.dart_tool/`, `ephemeral/`, Flutter `build/`, Go `bin/`.
- [x] CLAUDE.md: Layout gains `WayforkWindows/` and `fixtures/`; formatting rule per
      language (`swift-format`, `dart format`, `gofmt`); commit scopes `win`, `win-service`.

### WM1 — Core in Dart (`app/lib/core`)

One file per Swift counterpart where it makes sense; tests against `fixtures/`.
*(2026-08-27: done — 101 Dart tests; deltas recorded in
[08-windows.md](design/08-windows.md) § Dart core.)*

- [x] Models (`Store`, `Tunnel`, `Rule`, `RuleMatch`, `RuleTarget`, `Settings`) with
      the same JSON schema and version as `store.json` v2, migration hook; tests.
      *(`JsonText` reproduces Foundation's pretty/sorted JSON so the files stay byte-identical;
      `fixtures/singbox/*/input.json` re-encodes byte for byte.)*
- [x] `StoreRepository`: atomic debounced writes, corrupt-file recovery, slot allocation.
- [x] `SecretStore`: DPAPI via `win32` (`CryptProtectData` / `CryptUnprotectData`),
      one blob per secret, orphan cleanup; tests with a fake backend. *(`secrets.dat`;
      the Win32 backend is exercised on a Windows machine in WM3.)*
- [x] Rule pattern normalization and validation (lowercase, IDNA, wildcard, IPv4/CIDR,
      duplicates, shadowing, `coversTunnelServer`, `coversLocalNetwork`); tests.
      *(App rules are `.exe` paths → `(?i)^…$` regex; NFC not applied; `LocalNetwork.current()`
      moves to WM3 with the other Win32 enumerations.)*
- [x] OpenVPN config parser (directives, inline blocks, file inlining, strip list,
      rejects, credentials/passphrase detection, remotes); tests on the shared fixtures.
      *(Windows strip list adds compression and Windows-only directives.)*
- [x] VLESS URI parser; tests.
- [x] sing-box config generator + rule-set generator: golden tests byte-for-byte against
      `fixtures/`, including F8/F10/F11 variants; a test that runs `sing-box check` when
      the binary is present. *(`WayforkPlatform` injects the interface names; golden with
      `macOS`, `sing-box check` on the `windows` output — runs on this Mac.)*
- [x] `RuntimePlan` builder and plan hash; IPC payload types (`DaemonInfo`,
      `RuntimeStatus`, `TunnelState`, `LogLine`, `ApplyResult`, `DaemonError`,
      `TrafficSnapshot`) as JSON. *(Swift `Codable` wire form; `installPath` for `bundlePath`.)*
- [x] Diagnostics sanitizer; tests. *(Also abbreviates `X:\Users\<name>\…`.)*

### WM2 — Service in Go

*(2026-08-28: the whole shell ran end to end in the `wf-win` VM via `wayfork-service
--dev-apply` on a plan the Dart core generated from the maintainer's real export (sing-box
TUN + one VLESS + two OpenVPN on `ovpn-dco`). Confirmed: startup cleanup, NRPT override with
the probe, scoped 9999 routes, `tapctl` create/duplicate, `wayforkctl info/status/stop/
reconnect/diagnostics`, rule-set hot reload without a sing-box restart, and a clean teardown
that restores DNS and routes. **One fix landed:** the named pipe now uses overlapped I/O on
both ends (a synchronous handle serialised read vs. write, so every `wayforkctl` call hung) —
`internal/ipc/pipe_windows.go`. Still not exercised (skipped by `--dev-apply` / needs the
installer): the real `svc` SCM handler, `WinVerifyTrust` on binaries/clients, the event-log
source, sing-box crash-restart counting, and the on-link route fallback when no `route-gateway`
is pushed (all servers pushed one). Deltas in [08-windows.md](design/08-windows.md) § Service
shell.)*

- [x] `internal/core`: plan validation (`PlanValidator`, adapter-name validation),
      `RunLayout`, OpenVPN argv builder, management protocol parser (Windows device line),
      `OpenVPNSessionReducer`, `ResolverOverridePlanner`, Clash API decoding,
      `TrafficAccumulator`, log ring buffers; tests on `fixtures/`. *(2026-08-27: done —
      81 Go tests, also reconcile planner, rule-set selectors, rotating log, atomic file;
      deltas in [08-windows.md](design/08-windows.md) § Go core.)*
- [x] Service shell: `svc` handler, start idle, stop restores networking; event log
      entries for start/stop/crash. *(VM: `--dev-apply` start-idle → apply, `wayforkctl stop`
      restores networking; the SCM `svc` path and the event-log source stay for the installed
      service in WM3/WM4.)*
- [x] Named pipe listener with ACL and client verification; JSON framing; `getInfo`,
      `getStatus`, `subscribe`. *(VM: pipe + hello handshake + all three, after the
      overlapped-I/O fix; ACL set, client verification skipped in dev mode.)*
- [x] Binary signature validation (`WinVerifyTrust`) before spawning `sing-box.exe` /
      `openvpn.exe`. *(code in `winnet`; not exercised — `--dev-apply` skips trust checks by
      design, verified with a signed install in WM4.)*
- [x] `ManagedProcess`: `CreateProcess` under a job object (`KILL_ON_JOB_CLOSE`),
      stdout/stderr line readers, exit watch, backoff restart policy. *(VM: children ran under
      the job and all died on stop; t2 exercised the permanent-failure/no-retry path.)*
- [x] Run directory: `%ProgramData%\Wayfork
un\` with SYSTEM/Administrators ACL, temp
      file + rename writes, wipe on stop, keep `cache.db`, startup cleanup (routes, DNS
      records, stray adapters). *(VM: DACL set, wiped to `cache.db` on stop, startup cleanup
      restored a stale NRPT rule + `Wayfork-*` default route left by a prior crash.)*
- [x] sing-box lifecycle: write config + rule-sets, Clash API injection (loopback port +
      secret), `sing-box check`, start/stop/restart, startup verification (adapter up,
      public address routes through it), crash counting, hot reload of rule-set files.
      *(VM: check + start + startup verification + hot reload confirmed; crash counting not
      injected.)*
- [x] Adapters: create/delete named adapters per the spike (`tapctl` or driver API),
      reconcile with the plan's slot list. *(VM: created `Wayfork-3`, treated an existing
      `Wayfork-2` as present, duplicate `tapctl create` prints `already exists` / exit 1;
      runtime keeps adapters, delete is uninstall-only.)*
- [x] Routes: interface-scoped default add/delete via `winipcfg`, validated adapter names.
      *(VM: `0.0.0.0/0` via `route-gateway` metric 9999 on `Wayfork-3`, removed on stop.)*
- [x] OpenVPN session: argv, management client over TCP with password, hold release,
      `state`/`log`, password queries, `PUSH_REPLY` DNS discovery, permanent-failure
      rules. *(VM: t1 CONNECTED with a private-key passphrase prompt; `PUSH_REPLY`
      route-gateway parsed; t2 hit the permanent auth-failure path.)*
- [x] `Supervisor.apply` reconcile (diff by id + hash, restart vs rule-set rewrite),
      `stop`, `reconnect`, status coalescing, log batching. *(VM: apply, `rewriteRuleSets`
      reconcile, stop and reconnect all confirmed.)*
- [x] Resolver override: mechanism from the spike, `run\dns-override.json` record,
      `getaddrinfo` probe with back-out, re-apply on adapter change, restore on stop,
      crash and service start. *(VM: NRPT applied + record written + probe verified;
      restore on stop and re-apply on service start confirmed; adapter-change re-apply not
      separately triggered.)*
- [x] `TrafficSampler` (1 Hz Clash API GET), totals across sing-box restarts. *(VM: per-tunnel
      and Direct rates/connection counts streamed.)*
- [x] `collectDiagnostics`. *(VM: ~64 KB dump returned.)*
- [x] `wayfork-service --dev-apply <plan.json>` and `wayforkctl plan|status|stop` for
      running the service without the app (the macOS developer mode). *(VM: `wayforkctl plan`
      reproduced the Dart core's plan hash byte-for-byte; the full driver flow ran.)*

### WM3 — App in Flutter

Sub-steps agreed 2026-08-28: **WM3a** pure app core (`core/app/`) + `ServiceClient` +
Win32 halves → **WM3b** `AppModel` + apply pipeline + service states (no UI) → **WM3c**
tray + window lifecycle → **WM3d** Dashboard + Tunnels → **WM3e** Rules + General + Logs →
**WM3f** import/export + diagnostics + full VM run. WM3a-WM3f are done; the full VM run —
all five pages, the dialogs, import/export and diagnostics on the console — is what is
left. Deltas in
[08-windows.md](design/08-windows.md) § Flutter app.

- [x] `AppModel`: store, settings, runtime status, derived global state; `ServiceClient`
      over the pipe with reconnect, version handshake, status/log/traffic subscription.
      *(WM3a 2026-08-28: `ServiceClient` + `NamedPipeTransport` (overlapped, reader
      isolate), `core/app/` ports of GlobalState/StatusText/TrafficFormat/RuleEditing/
      ImportExport/LogFile, `LocalNetwork.current()` + `SystemDns.snapshot()` over
      `GetAdaptersAddresses`; 141 Dart tests. WM3b 2026-08-28: `AppModel` over
      `StoreStorage` / `SecretStore` / `ServiceClient` / `LogCenter` — store, settings,
      status, traffic, derived state, tunnels/rules CRUD, service states with the
      "repair installation" hint; 191 Dart tests, all on the fake service. WM3c
      2026-08-28: `main.dart` composes the model from the real parts and starts
      `bootstrap()` without blocking the first frame.)*
- [x] Tray: icon per state (4 variants, pulse while transitioning), menu per the prototype,
      quick add dialog.
      *(WM3c 2026-08-28: `assets/tray/{light,dark}/*.ico` from
      `scripts/make-win-tray-icons.py` (two taskbar themes, 16-48 px), `TrayMenu` +
      `TrayController` over a `TrayBackend`; left click toggles the window, right click
      pops the menu. Deltas: `degraded` dims the failing branch instead of hollowing it
      (a ring is mud at 16 px) and quick add jumps to the Dashboard field — a Win32 menu
      holds no text box. VM 2026-08-28: `flutter test` 222/222 and
      `flutter build windows --release` on the VM toolchain; `LoadImage` reads every
      generated `.ico` at 16-48 px. The icon in the notification area itself is an eyeball
      check — an ssh session has no interactive desktop.)*
- [x] Main window: sidebar, Dashboard (cards, rates, Direct row, actions), Tunnels (inline
      expansion, OpenVPN/VLESS forms, `.ovpn` import via picker and drop, Add VLESS with
      live preview, delete with rules), Rules (groups, inline editing, reorder, chips,
      search, empty state, live apply with inline errors), General (toggles, service
      status block, About, Export Diagnostics), Logs (ring buffer, filters, search,
      follow, copy/clear).
      *(WM3c 2026-08-28: the `NavigationView` shell, the service banner and the alert
      dialog. WM3d 2026-08-28: Dashboard (toggle, tiles, cards with rates and actions,
      Direct row, quick add) and Tunnels (rows with inline expansion, the OpenVPN and VLESS
      panes, F8 default, delete with its rules, `.ovpn` import through the picker and
      through a drop anywhere in the window, Add VLESS with live preview) — new pins
      `file_selector_windows 0.9.3+6`, `file_selector_platform_interface 2.7.0`,
      `desktop_drop 0.8.2`; 245 Dart tests. WM3e 2026-08-28: Rules (groups with the Direct
      exceptions on top, inline editing with live match inference, drag to reorder or move
      between groups, the `RuleValidator` chips, search, `.exe` app rules through the
      picker), General (the toggles, the DNS block, log level and retention, the service
      block with *Repair…* pointing at the installer, About with the versions the service
      reports) and Logs (source and level filters, search, follow, copy/clear, the
      preselected source of "Show Log") — no new dependencies, 273 Dart tests. Deltas:
      rules are deleted and moved from the right-click menu instead of a list selection
      plus the Delete key, app rules show no executable icon, and the MSI repair itself
      stays WM4. The five pages are not eyeballed on the VM console yet.)*
- [x] Apply pipeline: store change → plan rebuild → `apply` (debounced); reconnect-only and
      hot-reload paths as in [03-routing.md](design/03-routing.md).
      *(WM3b: debounce → `HostResolver` → `SystemDns.snapshot` → `RuntimePlanBuilder` →
      `apply`, serialised; re-apply on reconnect when the service is idle or runs another
      `planHash`; the reconnect-only / hot-reload split is the service's reconcile, VM-verified
      in WM2. WM3c: `SystemNetworkWatcher` polls `SystemDns.snapshot()` every 5 s and feeds
      `systemDNSChanged()` — the event APIs miss a resolver-only change, see
      [08-windows.md](design/08-windows.md).)*
- [x] Service-missing / version-mismatch states with a "repair installation" hint.
      *(WM3b: `ServiceIssue` + `summary` + the Turn On alert in the model. WM3c: the
      `ServiceBanner` on every page and the tray's "Repair Installation" entry, both
      through `AppActionHandler`. WM3e: the General service block with *Repair…*, which
      explains the Installed apps → Modify → Repair route and opens
      `ms-settings:appsfeatures`; running the MSI repair from the app is WM4.)*
- [x] Windows toast notifications for permanent failures and engine errors.
      *(WM3b: `Notifier` interface + console backend, posted by the model. WM3c:
      `ToastNotifier` over the new pin `local_notifier 0.1.6`; a shell that refuses the
      setup downgrades to `SilentNotifier`.)*
- [x] Import/export (`wayfork-export.json`, secrets checkbox, Replace/Merge; foreign app
      rules flagged).
      *(WM3f 2026-08-28: the Backup block on General — the export sheet with its secrets
      checkbox over `FilePicker.saveFile`, the import sheet over `StoreImporter.preview`
      with *Replace all* behind a confirmation, and the count of app rules made on another
      platform, which are imported but flagged. Export Diagnostics writes the macOS bundle
      through a zip writer of our own (`core/diagnostics/zip_writer.dart`) instead of
      `ditto`/PowerShell, with `ipconfig` / `route print` / `netsh` in `system.txt`;
      298 Dart tests, no new dependencies. Deltas in
      [08-windows.md](design/08-windows.md).)*
- [x] Launch at login (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`), connect on
      launch, quit stops everything; single-instance guard.
      *(WM3b: connect on launch and `shutdown()` (stop + flush) in the model. WM3c:
      `RegistryLaunchAtLogin` writes `"<exe>" --minimized`, the runner honours the flag
      without flashing a window, closing hides to the tray and Quit unwinds
      hide → tray → `shutdown()` → window; the guard is a session-local named event plus
      `FindWindowEx` on the running instance. VM 2026-08-28: the app connects to
      `wayfork-service --dev-apply`, a second launch exits 0 and leaves the first alone,
      and the log distinguishes `main window shown` from `launched into the tray`.)*
- [x] Log files with rotation and retention, mirroring `runtime.log` / `wayfork.log`.
      *(WM3b: `LogCenter` over `AppLogFile` — ring, replay de-duplication, prune at launch /
      daily / on setting change.)*

### WM4 — Installer and release

Sub-steps agreed 2026-08-28: **WM4a** the payload both architectures need (arm64 pins,
`--install-driver` / `--uninstall-cleanup` in the service) → **WM4b** WiX authoring +
`scripts/release-windows.ps1` → **WM4c** the release workflow, README and CHANGELOG →
install / upgrade / uninstall run in the VM (done on arm64 2026-08-28; the amd64 run is
owed with WM5). Decisions: two MSIs (x64 and arm64, the app
x64 in both), a thin installer over service subcommands, and unsigned artefacts until
there is a certificate — see [08-windows.md](design/08-windows.md) § Installer.

- [x] WiX authoring: files, `bin\`, service install/start/stop, driver install
      (`pnputil`) if the spike says so, upgrade (stop service → replace → start),
      uninstall (stop, restore DNS, delete adapters, remove `%ProgramData%\Wayfork\run`,
      keep `%LOCALAPPDATA%\Wayfork`).
      *(WM4a/WM4b 2026-08-28: `WayforkWindows/installer/Wayfork.wxs` (WiX 6.0.2) lays down
      the payload, registers the LocalSystem service with delayed auto-start and calls
      `wayfork-service --install-driver` / `--uninstall-cleanup` from two deferred custom
      actions; the cleanup is skipped for the removal half of an upgrade. Install,
      uninstall and a 0.1.0 → 0.1.1 upgrade were run on the arm64 VM — see
      [08-windows.md](design/08-windows.md) § Installer for the results and the traps.)*
- [x] `scripts/release-windows.ps1`: flutter build, go build with version stamp,
      Authenticode signing of every exe/dll/msi (timestamped), MSI, `.sha256`.
      *(WM4b 2026-08-28: one x64 app build, then per architecture the pinned binaries, the
      cross-built service, the staged payload and `wix build` →
      `build\release-windows\Wayfork-<version>-<arch>.msi` + `.sha256`. Signing is
      opt-in — `-CertificatePath` — because there is no certificate yet.)*
- [x] CI: release workflow builds the MSI on tag; artefacts named
      `Wayfork-<version>.msi` next to the DMG.
      *(WM4c 2026-08-28: `.github/workflows/release-windows.yml` builds both MSIs on a `v*`
      tag (the x64 runner cross-builds the arm64 service), checks the tag against the built
      version, uploads the artefacts and attaches them to the release. A `workflow_dispatch`
      run on 2026-08-28 produced both packages on the x64 runner (`Wayfork-0.1.0-amd64.msi`
      31.6 MB, `-arm64.msi` 29.4 MB); the tag path itself is exercised by the first tag.)*
- [x] One `.exe` installer over the two MSIs, so the download page asks nobody about
      architectures.
      *(WM4d 2026-08-28: `WayforkWindows/installer/WayforkBundle.wxs`, a WiX Burn bundle with
      both packages embedded and `NativeMachine` picking one, built `-arch x86` so it starts
      on every supported Windows; `scripts/release-windows.ps1` builds and (given a
      certificate) signs it through detach/reattach, the release workflow attaches
      `Wayfork-<version>.exe` + `.sha256` alongside the MSIs.)*
- [x] README: Windows install, first run, SmartScreen note, troubleshooting, limitations;
      CHANGELOG entry.
      *(WM4c 2026-08-28: a Windows section under Install (which package, the SmartScreen
      warning, what the MSI registers, Repair and what uninstall keeps), the Windows build
      and release commands under Development, and an Unreleased entry in the CHANGELOG.)*

### WM5 — End-to-end check

Manual, on a clean Windows 11 user account; results recorded in `08-windows.md`.

- [ ] Fresh MSI install → service running → one OpenVPN + one VLESS tunnel → rules →
      domains reach the right exit (`curl --resolve` checks + Logs) → Off restores routes
      and DNS.
- [ ] F8: unmatched through the default tunnel, exception direct, default down → blocked.
- [ ] F9: rates on both cards, Direct row moves for an exception.
- [ ] F10: the picker lists running apps (a store app and an elevated one included), the
      chosen `.exe` routes its traffic; removed exe leaves the rule flagged.
- [ ] F11: public IP through a tunnel, office subnet through OpenVPN, LAN untouched.
- [ ] F12: `Get-DnsClientServerAddress` shows the override while On and the original
      after Off; Wi-Fi ↔ Ethernet keeps it; service kill → restored at next start.
- [ ] Reboot with connect-on-launch; MSI upgrade over a running install; uninstall leaves
      no adapters, routes or DNS override behind.
- [ ] Mac export → Windows import → same routing (minus app rules).

### WM6 — Application picker (F10)

Delta agreed 2026-08-29: *Application…* stopped at a file dialog, which asks the user to
know where an app is installed. Design in [08-windows.md](design/08-windows.md) § Flutter
app, "App rules (F10) on Windows".

- [ ] `RunningApps` Win32 half: visible top-level windows → PID → full `.exe` path
      (`EnumWindows` + `QueryFullProcessImageNameW`), store apps resolved through the
      `ApplicationFrameHost` child `CoreWindow`, background processes behind a toggle
      (`EnumProcesses`), display name from `FileDescription`.
- [ ] `core/app/running_app.dart`: dedupe by path, windowed before background, search —
      pure and unit-tested; the Win32 half stays behind the interface for the fakes.
- [ ] Picker dialog on *Application…*: search, list, *Show background processes*,
      *Browse…* into the existing `FilePicker`, chosen path into the same `addRule`.
- [ ] VM run: the list matches Task Manager's *Apps*, a rule added from it routes.

### WM7 — Hardening (field findings, 2026-09-01)

Windows half of ROADMAP.md § "Hardening (field findings, 2026-09-01)" (H1–H4), found
while debugging Discord voice on the maintainer's PC, plus one Windows-only item.

- [x] H1: `verifyStartup` in `service/internal/service/engine.go` polls the adapter +
      route check every ~500 ms for up to 10–15 s instead of one shot after
      `singBoxStartupGrace`; one start retry before `startFailed`. Implemented as a
      500 ms poll over a 12 s window (`singBoxStartupPoll` / `singBoxStartupTimeout` /
      `singBoxStartAttempts`), the grace kept as the floor; `engine.AbortStartup()` from
      `Apply`/`Stop` before `opMu` so an operation never waits out a doomed start. Tests:
      slow adapter, silent sing-box, retry that succeeds, retry that gives up, aborting stop.
- [x] H2: `startFailed` surfaces in the tray icon, a Windows notification, and an
      automatic re-apply with backoff. Icon and toast were already wired; new is
      `core/app/recovery_backoff.dart` (5, 15, 30, 60, 120, 300 s) driving `AppModel`'s
      retry timer — one notification per streak, no alert storm from the retries, reset on
      `running` and on Turn On / Turn Off.
- [x] H3: dead-UDP detector — tunnel UDP flows with `up > 0, down = 0` for ~10 s
      highlighted in Traffic and listed in the diagnostics zip. The Go
      `TrafficAccumulator` mirrors the Swift one; the count crosses the pipe as
      `TrafficCounters.oneWayUDPFlows` (additive, read as zero when absent — no protocol
      bump), shows as an orange warning glyph on the dashboard tunnel row, logs one
      service WARNING per tunnel per streak, and lands in `system.txt`'s `## traffic`
      section (design: 08-windows.md "Hardening (WM7)").
- [x] H4: `reverse_mapping` dropped from the Dart generator except when a default tunnel
      is set, same condition as the Swift one (03-routing.md records the reasoning).
      `fixtures/singbox` regenerated once; Swift, Dart and Go suites pass, the
      cross-client plan-hash pin in `plan_test.go` re-pinned.
- [ ] VM run for H1/H2: a start that is slow to bring the `Wayfork` adapter up is not
      killed; a start that cannot work (another VPN holding the TUN) ends in the error
      tray icon plus one toast, and comes back on its own once the blocker is gone.
- [ ] WH1 (Windows-only): version-agnostic app rules. The picker stores
      `...\Discord\app-1.0.9255\Discord.exe`; a Squirrel auto-update silently unmatches
      the rule. Normalize `app-<version>` path segments to a version pattern when a rule
      is created from the picker, and warn in Rules when a rule matches no installed
      binary.
