# Wayfork

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20·%20arm64%20%7C%20x64-000000?logo=apple&logoColor=white)](#macos)
[![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11%20·%20x64%20%7C%20arm64-0078D4?logo=windows11&logoColor=white)](#windows)
[![OpenVPN](https://img.shields.io/badge/OpenVPN-EA7E20?logo=openvpn&logoColor=white)](#tunnels)
[![VLESS / REALITY](https://img.shields.io/badge/VLESS-REALITY-6E56CF)](#tunnels)
[![WireGuard](https://img.shields.io/badge/WireGuard-88171A?logo=wireguard&logoColor=white)](#tunnels)
[![Release](https://img.shields.io/github/v/release/fosteev/Wayfork?include_prereleases&color=2ea043)](https://github.com/fosteev/Wayfork/releases)

**Per-domain split tunneling across several VPNs at once.** Add your tunnels (OpenVPN
`.ovpn`, WireGuard `.conf`, `vless://`, `ss://`, `trojan://`, `vmess://`), write rules like `*.example.com → Work`, `Telegram → Home`,
`10.8.0.0/24 → Office`, and pick which tunnel takes everything else — or none. All tunnels
stay up simultaneously; there is no switching.

Native on both platforms: a **menu bar app on macOS**, a **notification-area app on
Windows**, one repository, one rule model, one export format.

| macOS — menu bar | Windows — system tray |
|---|---|
| ![macOS popover](docs/screenshots/popover.png) | ![Windows tray flyout](docs/screenshots/windows/tray.png) |

## Features

- **Tunnels** — OpenVPN profiles (inline certs, credentials asked once), WireGuard configs,
  VLESS / Shadowsocks / Trojan / VMess links (TCP, WebSocket, gRPC; TLS and REALITY) and
  subscription URLs. Secrets go to the Keychain (macOS) or DPAPI (Windows), never to disk
  in the clear.
- **Tunnel groups** — several tunnels behind one name, *Fastest* or *First live*; rules
  and the default exit can point at a group, and the card shows which member is in use.
- **Latency on every card** — measured through each tunnel every 10 s with a 2-minute
  sparkline; a tunnel that stops answering reads *Not reachable*, with a Retry.
- **Rules** — `domain → tunnel`, first match wins. Exact (`api.example.com`), suffix
  (`example.com` covers subdomains), wildcard (`*.cdn.example.com`).
- **Application rules** — route an app, and every process inside it, through a tunnel or
  keep it direct, whatever it talks to.
- **IP rules** — an IPv4 address or subnet instead of a domain: SSH/RDP/DB by IP, an office
  network behind OpenVPN, an internal server with no name.
- **Default tunnel** — everything unmatched through one tunnel; without one it goes direct.
  If that tunnel drops, unmatched traffic is blocked rather than leaked.
- **Exceptions** — rules that target *Direct*. They win over everything, carving domains,
  apps or ranges out of the default tunnel. `.local`, `.lan`, `.internal`, `.home.arpa`
  are always direct.
- **Recent** — the sites that went the default way in the last 5 minutes, with the app
  that opened them; *Route via ▾* turns a row into a rule in one click.
- **Local proxy port** — a `127.0.0.1:‹port›` SOCKS5/HTTP address per tunnel or group,
  for `curl`, a browser profile or any app you want through one exit without a rule.
- **Block ads and trackers** — one switch backed by a bundled, pinned block list compiled
  into a sing-box rule-set; *Never block* exceptions and a *Blocked N today* counter.
- **Live edits** — a rule change is a hot reload; a tunnel change reconnects that tunnel only.
- **Status and traffic** — tray/menu bar icon (off · connecting · on · degraded · error),
  a card per tunnel with state, rule count and live down/up rate, plus a Direct row.
- **Can't reach** — the Logs window lists the connections that could not be established:
  site, app, tries, why (*no answer*, *refused*, *blocked by your list*, *‹tunnel› is
  down*), via which exit; a click filters the log to that site.
- **Connections by exit** — a second view of the Logs window: per tunnel, group and
  *Not via any tunnel*, how many connections opened, reached and failed, with the fail
  rate; an exit expands into its *Can't reach* rows.
- **Logs and diagnostics** — app, sing-box and per-tunnel OpenVPN logs in one window;
  "Export Diagnostics" zips them with a sanitized config.
- **Settings** — launch at login, connect on launch, auto-reconnect with backoff, Wayfork
  as the system resolver while On, resolver for direct traffic, log level and retention,
  JSON export/import (with or without secrets) that moves a setup between macOS and Windows.

Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md) · [docs/ROADMAP-windows.md](docs/ROADMAP-windows.md).
Changes per version: [CHANGELOG.md](CHANGELOG.md).

## Install

Both platforms are built from the same [release](https://github.com/fosteev/Wayfork/releases);
each artefact ships a `.sha256` next to it.

### macOS

Requires macOS 14 (Sonoma) or later, Apple silicon or Intel.

1. Download `Wayfork-<version>.dmg`, verify with
   `shasum -a 256 -c Wayfork-<version>.dmg.sha256`, drag **Wayfork** to **Applications**.
2. Clear the quarantine flag — the builds are signed with an Apple *Development*
   certificate but **not notarized**, so Gatekeeper refuses a downloaded copy:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Wayfork.app
   ```

   Use `-r`: it also covers the privileged helper and the bundled `sing-box` / `openvpn`.
3. Launch it. Wayfork lives in the menu bar, with no Dock icon. Flip the switch; macOS asks
   you once to approve the helper in *System Settings › General › Login Items & Extensions*
   under *Allow in the Background*. There is no password prompt.

Notarization needs a paid Apple Developer Program membership the project does not have yet.
The signature is real (`codesign --verify --deep --strict` passes); only the download check
is missing. To avoid trusting a binary Apple cannot vouch for, build it yourself — a free
Apple ID is enough, see [Development](#development).

### Windows

Requires Windows 10 21H2 or Windows 11, x64 or ARM64.

1. Download `Wayfork-<version>.exe` — it carries both architectures and installs the right
   one. (`Wayfork-<version>-amd64.msi` / `-arm64.msi` are there for MSI-based deployment;
   `$env:PROCESSOR_ARCHITECTURE` says which.) Verify with `Get-FileHash`.
2. Run it. The builds are **unsigned** — no Authenticode certificate yet — so
   SmartScreen shows "Windows protected your PC": *More info* → *Run anyway*. The same
   warning appears on the first launch.
3. The installer puts Wayfork in `%ProgramFiles%\Wayfork`, registers the **Wayfork** service
   (LocalSystem, delayed auto-start) and installs the bundled `ovpn-dco` adapter driver —
   WHQL-signed by OpenVPN Inc., no prompt and no reboot. A machine that already has OpenVPN
   keeps its own copy of the driver.
4. Start **Wayfork** from the Start menu. It lives in the notification area; flip the
   switch — no UAC prompt, the service is already there.

If the app reports the service as missing or mismatched, repair the install: *Settings ›
Apps › Installed apps › Wayfork › Modify → Repair*. Uninstalling removes the service, the
`Wayfork-N` adapters, the driver package Wayfork published (never one belonging to an
OpenVPN install), the DNS rule and `%ProgramData%\Wayfork\run`; logs, tunnels and rules
under `%LOCALAPPDATA%\Wayfork` are kept.

> Running another VPN client at the same time — especially one that also owns the default
> route or a system proxy — is the most common cause of "routing engine failed to start".
> Stop it first.

## Tunnels

| macOS | Windows |
|---|---|
| ![macOS Settings › Tunnels](docs/screenshots/settings-tunnels.png) | ![Windows Tunnels](docs/screenshots/windows/tunnels.png) |

- **OpenVPN** — *+ Add › OpenVPN…*, or drop a `.ovpn` onto the window. Inline
  `<ca>`/`<cert>`/`<key>` blocks work as they are; a profile that needs a username/password
  asks once. `up`/`down` scripts are never executed, and routes pushed by the server are
  ignored (`--route-nopull`) — Wayfork decides what goes where.
- **WireGuard** — *+ Add › Add WireGuard…*, or drop a `.conf` onto the window; the config
  can also be pasted. It runs inside sing-box's userspace stack: no driver, no adapter, and
  the `DNS =` line becomes the tunnel's own resolver. A conf whose `AllowedIPs` is narrower
  than `0.0.0.0/0` is kept as written and flagged — the peer drops whatever falls outside.
- **Links** — *+ Add › Add from link…* takes `vless://`, `ss://`, `trojan://` and
  `vmess://`; the scheme picks the parser and the sheet shows what it understood. REALITY
  over TCP and gRPC is supported, XHTTP is not (see the roadmap). Refused with a reason rather than
  guessed: pre-AEAD Shadowsocks ciphers, SIP003 `plugin=`, VMess `alterId` above 0.
- **Subscriptions** — the same sheet takes an `https://` subscription URL: *Fetch* loads
  it (plain link lines or base64 of them), lists every server with a checkbox and every
  line it could not use with the reason, and adds the checked ones. One-shot: the URL is
  not stored, logged or refreshed — it is a bearer token for every server on it.
- **Groups** — *+ Add › New group…* puts several tunnels behind one name. *Fastest*
  measures the members and switches to the quickest; *First live* uses the first member
  that works and moves on when it fails. Rules and the default exit take a group like a
  tunnel; the card shows the member in use and why the others are skipped.
- **Local proxy** — every tunnel and group can expose `127.0.0.1:‹port›` (SOCKS5 and
  HTTP on one port, from 1081 up) for an app you want through that exit without a rule:
  `curl --proxy socks5h://127.0.0.1:1081 https://ifconfig.me`. Loopback only.
- **Latency** — each connected tunnel is probed every 10 s; the number on the card is
  colour-banded, the sparkline covers 2 minutes, and a tunnel that stops answering reads
  *Not reachable* with a Retry.
- *Route everything else through this tunnel* makes it the default exit.

## Rules

| macOS | Windows |
|---|---|
| ![macOS Settings › Rules](docs/screenshots/settings-rules.png) | ![Windows Rules](docs/screenshots/windows/rules.png) |

| Pattern | Matches |
|---|---|
| `api.example.com` | that host only |
| `example.com` | the host and every subdomain |
| `*.cdn.example.com` | one label under `cdn.example.com` |
| `/Applications/Telegram.app`, `C:\…\Telegram.exe` (via *+ › Application…*) | every process of that app |
| `203.0.113.7`, `10.8.0.0/24` | connections opened to that address / subnet |

Rules are grouped by tunnel; the *Direct* group holds exceptions and always comes first.
Above them, **Recent** lists the sites that went the default way in the last 5 minutes
with the app that opened them — *Route via ▾* on a row writes the suffix rule for you.
*Where does ‹site› go?* tests a name against the rules and, with the tunnel up, probes it
through the exit it would take.
On Windows, *+ › Application…* lists the applications that are running, so an app is picked
by name; *Browse…* there points at an `.exe` that is not started.
Inside a group, domain, application and IP rules are peers. A rule that can never fire —
shadowed by an earlier one, or pointing at a disabled tunnel — gets a warning chip, and so
does an IP rule covering your own LAN.

Worth knowing:

- Domain rules decide by the name a connection was opened with, so a site reached by name
  follows its domain rule even when it resolves into a range covered by an IP rule. IP
  rules catch clients that connect by address or resolve names on their own.
- Private ranges (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`) stay out of Wayfork unless
  a tunnel rule names a subnet inside them — that is how an OpenVPN office network becomes
  reachable.
- Application rules see the process that opens the connection: an app talking through
  another local proxy is seen as that proxy.

## Seeing what happens

| macOS — Can't reach | macOS — Connections by exit | Windows — Connections by exit |
|---|---|---|
| ![macOS Logs › Can't reach](docs/screenshots/logs-cant-reach.png) | ![macOS Logs › Connections](docs/screenshots/logs-connections.png) | ![Windows Logs › Connections](docs/screenshots/windows/logs-connections.png) |

- **Can't reach** — a pane above the log lines with every connection that could not be
  established since Turn On: site (or `ip:port`), the app that opened it, tries, why
  (*no answer* · *refused* · *blocked by your list* · *no such name* · *‹tunnel› is
  down*), the exit, when last. Click a row to filter the log to that site; *Route via ▾*
  fixes a site that only works through a tunnel. The popover shows a red line while
  anything failed in the last 5 minutes.
- **Connections** — the same window's second view: one row per exit with connections
  opened, reached and failed since Turn On (or *Last 5 min*) and a fail-rate bar; an
  exit expands into its *Can't reach* rows. ⇧⌘L from the popover, or *Details* on a
  failing card. Counts are connections, not requests — one page load is dozens — and
  *reached* means the connection opened, not that the site behaved.
- Both read sing-box's own log, so they need log detail *Normal* (Settings › General);
  at *Problems* the counts show `—`. What happens inside a connection (an HTTP 403, a
  stalled download) is invisible here.
- On Windows the same two live on the main window's *Logs* page; *Connections* is also in
  the tray menu.

### From the command line (scripts, coding assistants)

`wayforkctl` ships inside the app (`Wayfork.app/Contents/Resources/bin/wayforkctl`); link
it into your `PATH`:

```sh
ln -s /Applications/Wayfork.app/Contents/Resources/bin/wayforkctl /usr/local/bin/wayforkctl
wayforkctl logs --source sing-box --level warning --since 10m   # filtered, works with the app quit
wayforkctl failed                                               # Can't reach rows, per-exit counters
wayforkctl rules add example.com --via Work                     # undone in 60 s …
wayforkctl confirm                                              # … unless confirmed
```

Changes go through the running app, never around it, and are undone by themselves unless
`wayforkctl confirm` follows within `--confirm-within` seconds (default 60). A coding
assistant whose own traffic runs through Wayfork cannot lock itself out. Server addresses
in `logs` are replaced by `server-N` unless `--raw`; no command prints credentials.
`wayforkctl help` lists everything. On Windows `wayforkctl logs` takes the same filters;
rule changes from the command line are macOS-only for now.

## How it works

- [sing-box](https://github.com/SagerNet/sing-box) owns a TUN interface and the default
  route, answers DNS with fake IPs so every connection is routed by domain, and hosts the
  VLESS / Shadowsocks / Trojan / VMess / WireGuard outbounds, the groups (`urltest` /
  `selector`) and the local proxy inbounds.
- Each OpenVPN profile runs as its own `openvpn --route-nopull` process on its own
  interface (`utun` on macOS, an `ovpn-dco` `Wayfork-N` adapter on Windows); sing-box
  reaches it through an interface-bound outbound.
- One privileged component does the rest: a launchd daemon registered with `SMAppService`
  on macOS, a LocalSystem service on Windows. It spawns the bundled binaries, adds routes,
  samples traffic counters and streams logs to the unprivileged GUI.
- Everything is bundled — `sing-box` and `openvpn`, pinned in `scripts/versions.env` and
  `windows/versions.env`. No kernel extension and no Network Extension on macOS; on
  Windows the only driver installed is OpenVPN's WHQL-signed `ovpn-dco` (sing-box's TUN
  rides the wintun sing-tun already embeds).

| | macOS | Windows |
|---|---|---|
| GUI | SwiftUI menu bar app | Flutter + `fluent_ui`, notification area |
| Privileged half | `WayforkDaemon` (launchd, `SMAppService`), XPC | Go service (LocalSystem), named pipe |
| Config, rules | `~/Library/Application Support/Wayfork/store.json` | `%LOCALAPPDATA%\Wayfork\store.json` |
| Secrets | Keychain | DPAPI (`secrets.dat`) |
| Logs | `~/Library/Logs/Wayfork/` | `%LOCALAPPDATA%\Wayfork\logs\` |
| Package | signed `.dmg` | `.exe` bundle of two `.msi` |

## Troubleshooting

- **"Helper requires approval"** (macOS) — *System Settings › General › Login Items &
  Extensions*, enable Wayfork under *Allow in the Background*, Turn On again.
- **Helper/service out of date** — *Settings › General › Reinstall helper* on macOS;
  *Modify → Repair* in Installed apps on Windows.
- **"Routing engine failed to start"** — another VPN or proxy holds the default route or the
  TUN address range. Stop it, then Turn On; *Logs › sing-box* shows what it complained about.
- **A domain does not go where expected** — check the rule's warning chip, then resolve it
  (`dig +short <domain>` / `Resolve-DnsName <domain>`): while On, matched domains answer
  with `198.18.x.x`–`198.19.x.x` fake IPs. Browsers with their own DNS-over-HTTPS bypass
  Wayfork's resolver — turn off "secure DNS" or point it at the system resolver. A
  system-wide HTTP/SOCKS proxy bypasses the TUN too, for the apps that honour it.
- **Rates show `—`** — the GUI has not heard from the privileged half for 3 s; if traffic is
  flowing, *Logs* will show `traffic: clash api unreachable`.
- **Can't reach / Connections stay empty** — they need log detail *Normal* or above; at
  *Problems* sing-box prints none of the lines they read. After an upgrade, *Reinstall
  helper* once — the counters come from the privileged half.
- **A site works only through a tunnel** — it shows up under *Can't reach* with the exit
  it took; *Route via ▾* on the row writes the rule.
- **Tunnel failed** — the card carries the reason (bad credentials, key passphrase, config
  error) and the pencil jumps to the field to fix.
- **Bug report** — *Settings › General › Export Diagnostics* produces a zip with secrets
  stripped.

## Limitations

- **IPv4 only while On** — the TUN has no IPv6 address and DNS returns no AAAA records, so
  IPv6-only destinations are unreachable until you Turn Off. IPv6 rules come with IPv6 support.
- **Browser DoH bypasses domain rules** — a browser resolving over DNS-over-HTTPS never asks
  Wayfork, so its traffic is seen by IP only. Disable secure DNS, or use IP/application rules.
- **Wayfork owns the DNS setting while On** — an entry you made yourself is restored when
  Off, and editing it while On is undone on the spot. If Wayfork was removed while On and
  macOS still points at `172.19.0.2`, run `networksetup -setdnsservers Wi-Fi empty`.
- **No kill switch** — a tunnel that is down fails its matched connections rather than
  leaking them, but there is no global "block everything when a tunnel drops".
- **Application rules** only see traffic entering the TUN, and are keyed by path — a moved
  app needs a new rule. They do not cross platforms in an export.
- **IP rules** are IPv4 and match the destination address only; no port or protocol conditions.
- Subscriptions are fetched once, not refreshed; no rule lists; no XHTTP (sing-box does
  not implement it).
- *Can't reach* and *Connections* count connections that failed to open; a request that
  reached the server and failed there is invisible inside TLS.
- Neither build is signed for its store: macOS is not notarized, Windows is not Authenticode-signed.

## Development

### macOS — Xcode 26 (Swift 6 language mode, strict concurrency)

```sh
scripts/fetch-bins.sh                 # pinned sing-box, static universal openvpn
scripts/fetch-blocklist.sh            # pinned ads & trackers list, compiled with sing-box
scripts/dev-sign.sh                   # build signed with your Apple Development identity
swift test --package-path macos/WayforkCore
scripts/format.sh --lint              # swift-format check (drop --lint to fix)
```

`macos/Wayfork.xcodeproj` holds the `Wayfork` and `WayforkDaemon` targets;
`macos/WayforkCore` is a local Swift package shared by both. Plain `xcodebuild` and
Xcode's Run produce ad-hoc signed builds — fine for UI work, but they cannot register the
privileged helper; use `scripts/dev-sign.sh` and copy the app to `/Applications`. The script
needs an *Apple Development* identity: sign in to Xcode with any Apple ID (*Settings ›
Accounts*, no paid membership) and it creates one for your personal team. Builds made this
way are trusted on your own Mac, no quarantine step needed.

### Windows — toolchains pinned in `windows/versions.env`

```powershell
scripts\fetch-win-bins.ps1 -Arch amd64   # pinned sing-box, OpenVPN, the ovpn-dco package
cd windows\app;     flutter test; dart analyze --fatal-infos
cd windows\service; go test ./...; go vet ./...
scripts\release-windows.ps1              # both MSIs and the bundle → build\release-windows\
```

`windows/app` is the Flutter app, `windows/service` the Go service
(`internal/core` is the pure, everywhere-tested half; Win32 stays behind `//go:build
windows`, so `go test ./...` passes on macOS too) and `windows/installer` the WiX
source of the MSI.

### Shared

`fixtures/` holds the test inputs and golden outputs used by the Swift, Dart and Go tests
alike. Design notes live in [docs/design/](docs/design/) — Windows deltas in
[08-windows.md](docs/design/08-windows.md) — and the screenshots above come from the UI
prototypes, [variant-b.html](docs/design/prototype/variant-b.html) and
[windows.html](docs/design/prototype/windows.html). Release steps:
[docs/RELEASING.md](docs/RELEASING.md).

## License

TBD
