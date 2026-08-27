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
| W3. Implementation | Milestones WM0–WM5 below | WM0 done 2026-08-27 (pending review); WM1 next |

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

**F10. Rules: application → tunnel** — an application is an `.exe`, picked in a file
dialog; the rule covers that executable only (there is no bundle to enclose helpers).
Display name and icon come from the file's version info.

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

- [ ] Models (`Store`, `Tunnel`, `Rule`, `RuleMatch`, `RuleTarget`, `Settings`) with
      the same JSON schema and version as `store.json` v2, migration hook; tests.
- [ ] `StoreRepository`: atomic debounced writes, corrupt-file recovery, slot allocation.
- [ ] `SecretStore`: DPAPI via `win32` (`CryptProtectData` / `CryptUnprotectData`),
      one blob per secret, orphan cleanup; tests with a fake backend.
- [ ] Rule pattern normalization and validation (lowercase, IDNA, wildcard, IPv4/CIDR,
      duplicates, shadowing, `coversTunnelServer`, `coversLocalNetwork`); tests.
- [ ] OpenVPN config parser (directives, inline blocks, file inlining, strip list,
      rejects, credentials/passphrase detection, remotes); tests on the shared fixtures.
- [ ] VLESS URI parser; tests.
- [ ] sing-box config generator + rule-set generator: golden tests byte-for-byte against
      `fixtures/`, including F8/F10/F11 variants; a test that runs `sing-box check` when
      the binary is present.
- [ ] `RuntimePlan` builder and plan hash; IPC payload types (`DaemonInfo`,
      `RuntimeStatus`, `TunnelState`, `LogLine`, `ApplyResult`, `DaemonError`,
      `TrafficSnapshot`) as JSON.
- [ ] Diagnostics sanitizer; tests.

### WM2 — Service in Go

- [ ] `internal/core`: plan validation (`PlanValidator`, adapter-name validation),
      `RunLayout`, OpenVPN argv builder, management protocol parser (Windows device line),
      `OpenVPNSessionReducer`, `ResolverOverridePlanner`, Clash API decoding,
      `TrafficAccumulator`, log ring buffers; tests on `fixtures/`.
- [ ] Service shell: `svc` handler, start idle, stop restores networking; event log
      entries for start/stop/crash.
- [ ] Named pipe listener with ACL and client verification; JSON framing; `getInfo`,
      `getStatus`, `subscribe`.
- [ ] Binary signature validation (`WinVerifyTrust`) before spawning `sing-box.exe` /
      `openvpn.exe`.
- [ ] `ManagedProcess`: `CreateProcess` under a job object (`KILL_ON_JOB_CLOSE`),
      stdout/stderr line readers, exit watch, backoff restart policy.
- [ ] Run directory: `%ProgramData%\Wayfork\run\` with SYSTEM/Administrators ACL, temp
      file + rename writes, wipe on stop, keep `cache.db`, startup cleanup (routes, DNS
      records, stray adapters).
- [ ] sing-box lifecycle: write config + rule-sets, Clash API injection (loopback port +
      secret), `sing-box check`, start/stop/restart, startup verification (adapter up,
      public address routes through it), crash counting, hot reload of rule-set files.
- [ ] Adapters: create/delete named adapters per the spike (`tapctl` or driver API),
      reconcile with the plan's slot list.
- [ ] Routes: interface-scoped default add/delete via `winipcfg`, validated adapter names.
- [ ] OpenVPN session: argv, management client over TCP with password, hold release,
      `state`/`log`, password queries, `PUSH_REPLY` DNS discovery, permanent-failure
      rules.
- [ ] `Supervisor.apply` reconcile (diff by id + hash, restart vs rule-set rewrite),
      `stop`, `reconnect`, status coalescing, log batching.
- [ ] Resolver override: mechanism from the spike, `run\dns-override.json` record,
      `getaddrinfo` probe with back-out, re-apply on adapter change, restore on stop,
      crash and service start.
- [ ] `TrafficSampler` (1 Hz Clash API GET), totals across sing-box restarts.
- [ ] `collectDiagnostics`.
- [ ] `wayfork-service --dev-apply <plan.json>` and `wayforkctl plan|status|stop` for
      running the service without the app (the macOS developer mode).

### WM3 — App in Flutter

- [ ] `AppModel`: store, settings, runtime status, derived global state; `ServiceClient`
      over the pipe with reconnect, version handshake, status/log/traffic subscription.
- [ ] Tray: icon per state (4 variants, pulse while transitioning), menu per the prototype,
      quick add dialog.
- [ ] Main window: sidebar, Dashboard (cards, rates, Direct row, actions), Tunnels (inline
      expansion, OpenVPN/VLESS forms, `.ovpn` import via picker and drop, Add VLESS with
      live preview, delete with rules), Rules (groups, inline editing, reorder, chips,
      search, empty state, live apply with inline errors), General (toggles, service
      status block, About, Export Diagnostics), Logs (ring buffer, filters, search,
      follow, copy/clear).
- [ ] Apply pipeline: store change → plan rebuild → `apply` (debounced); reconnect-only and
      hot-reload paths as in [03-routing.md](design/03-routing.md).
- [ ] Service-missing / version-mismatch states with a "repair installation" hint.
- [ ] Windows toast notifications for permanent failures and engine errors.
- [ ] Import/export (`wayfork-export.json`, secrets checkbox, Replace/Merge; foreign app
      rules flagged).
- [ ] Launch at login (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`), connect on
      launch, quit stops everything; single-instance guard.
- [ ] Log files with rotation and retention, mirroring `runtime.log` / `wayfork.log`.

### WM4 — Installer and release

- [ ] WiX authoring: files, `bin\`, service install/start/stop, driver install
      (`pnputil`) if the spike says so, upgrade (stop service → replace → start),
      uninstall (stop, restore DNS, delete adapters, remove `%ProgramData%\Wayfork\run`,
      keep `%LOCALAPPDATA%\Wayfork`).
- [ ] `scripts/release-windows.ps1`: flutter build, go build with version stamp,
      Authenticode signing of every exe/dll/msi (timestamped), MSI, `.sha256`.
- [ ] CI: release workflow builds the MSI on tag; artefacts named
      `Wayfork-<version>.msi` next to the DMG.
- [ ] README: Windows install, first run, SmartScreen note, troubleshooting, limitations;
      CHANGELOG entry.

### WM5 — End-to-end check

Manual, on a clean Windows 11 user account; results recorded in `08-windows.md`.

- [ ] Fresh MSI install → service running → one OpenVPN + one VLESS tunnel → rules →
      domains reach the right exit (`curl --resolve` checks + Logs) → Off restores routes
      and DNS.
- [ ] F8: unmatched through the default tunnel, exception direct, default down → blocked.
- [ ] F9: rates on both cards, Direct row moves for an exception.
- [ ] F10: an `.exe` rule routes its traffic; removed exe leaves the rule flagged.
- [ ] F11: public IP through a tunnel, office subnet through OpenVPN, LAN untouched.
- [ ] F12: `Get-DnsClientServerAddress` shows the override while On and the original
      after Off; Wi-Fi ↔ Ethernet keeps it; service kill → restored at next start.
- [ ] Reboot with connect-on-launch; MSI upgrade over a running install; uninstall leaves
      no adapters, routes or DNS override behind.
- [ ] Mac export → Windows import → same routing (minus app rules).
