# Wayfork

macOS menu bar app for per-domain split tunneling across several VPNs at once. Add your
tunnels (OpenVPN `.ovpn`, VLESS `vless://`), write rules like "`*.example.com` → Work",
pick which tunnel takes everything else — or none. All tunnels stay up simultaneously;
there is no switching.

![Popover](docs/screenshots/popover.png)

## Features

- **Tunnels**: OpenVPN profiles (inline certs, username/password asked once) and VLESS URIs
  (TCP, WebSocket, gRPC; TLS and REALITY). Enable, disable, rename, reconnect. Secrets go to
  the Keychain, never to disk.
- **Rules**: `domain → tunnel`, first match wins. Exact (`api.example.com`), suffix
  (`example.com` covers subdomains) and wildcard (`*.cdn.example.com`) patterns. Quick add
  straight from the menu bar.
- **Default tunnel**: route everything not matched by a rule through one tunnel. Without
  one, unmatched traffic goes direct.
- **Exceptions**: rules that target *Direct*. They win over everything, so they carve
  domains out of the default tunnel or out of a broader rule. `.local`, `.lan`,
  `.internal`, `.home.arpa` are always direct.
- **Live edits**: changing rules while On is a hot reload; changing a tunnel reconnects only
  that tunnel.
- **Status**: menu bar icon (off / connecting / on / degraded / error), a card per enabled
  tunnel with its state and rule count.
- **Logs and diagnostics**: one window for the app, sing-box and per-tunnel OpenVPN logs;
  "Export Diagnostics" zips logs and a sanitized config for bug reports.
- **Settings**: launch at login, connect on launch, auto-reconnect with backoff, resolver
  for direct traffic (system / custom), log level and retention, JSON export/import of
  tunnels and rules (with or without secrets).

Next up: per-tunnel traffic rates in the popover. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Install

Requires macOS 14 or later. No signed release yet — build from source (see
[Development](#development)) and copy `Wayfork.app` to `/Applications`.

**First run**: click the menu bar icon and flip the switch. Wayfork registers a small
privileged helper; macOS asks you to approve it once in *System Settings › General › Login
Items & Extensions*. There is no password prompt — the helper is what starts `sing-box` and
`openvpn` for you.

## Tunnels

![Settings › Tunnels](docs/screenshots/settings-tunnels.png)

- **OpenVPN**: *Settings › Tunnels › + Add › OpenVPN…* or drop a `.ovpn` onto the window.
  Profiles with inline `<ca>`/`<cert>`/`<key>` blocks work as they are; if the profile needs
  a username/password you are asked once. `up`/`down` scripts are never executed.
- **VLESS**: *+ Add › VLESS…* and paste a `vless://` URI (the sheet shows what was parsed).
  REALITY is supported over TCP; XHTTP is not (see the roadmap).
- Turn on *Route everything else through this tunnel* to make it the default exit. If that
  tunnel goes down, unmatched traffic is blocked rather than leaked.

## Rules

![Settings › Rules](docs/screenshots/settings-rules.png)

| Pattern | Matches |
|---|---|
| `api.example.com` | that host only |
| `example.com` | the host and every subdomain |
| `*.cdn.example.com` | one label under `cdn.example.com` |

Rules are grouped by tunnel; the *Direct* group holds exceptions and always comes first.
A rule that can never fire (shadowed by an earlier one, or pointing at a disabled tunnel)
gets a warning chip. Quick add in the popover: type a domain, pick a tunnel or *Direct*.

## How it works

- [sing-box](https://github.com/SagerNet/sing-box) owns a TUN interface and the default
  route, answers DNS with fake IPs so every connection is routed by domain, and hosts the
  VLESS outbounds.
- Each OpenVPN profile runs as its own `openvpn --route-nopull` process on its own `utun`;
  sing-box reaches it through an interface-bound outbound.
- A launchd daemon (`WayforkDaemon`, registered with `SMAppService`) is the only privileged
  part: it spawns the bundled binaries, adds routes and streams logs to the app over XPC.
  The app itself is unprivileged and keeps `store.json` and the Keychain.
- Everything is bundled: `sing-box` and a static `openvpn` (pinned in
  `scripts/versions.env`). No kernel extensions, no Network Extension.

Files: `~/Library/Application Support/Wayfork/store.json` (tunnels, rules, settings — no
secrets), `~/Library/Logs/Wayfork/` (app and mirrored runtime logs),
`/Library/Application Support/Wayfork/run/` and `/Library/Logs/Wayfork/` (daemon, root-only).

## Troubleshooting

- **"Helper requires approval"** — open *System Settings › General › Login Items &
  Extensions* and enable Wayfork under *Allow in the Background*, then Turn On again.
- **A domain does not go where expected** — check the rule's warning chip (shadowed /
  tunnel disabled), then `dig +short <domain>`: while On, matched domains resolve to
  `198.18.x.x`–`198.19.x.x` fake IPs. Browsers with their own DNS-over-HTTPS bypass
  Wayfork's DNS — turn off "secure DNS" in the browser or point it at the system resolver.
- **Tunnel failed** — the card shows the reason (bad credentials, key passphrase, config
  error); the pencil jumps to the field to fix. Everything else is in *Logs* (⌘L).
- **Bug report** — *Settings › General › Export Diagnostics* produces a zip with secrets
  stripped.

Limitations (0.1): IPv4 only while On (no AAAA answers); no kill switch for tunnel rules —
a matched domain whose tunnel is down fails to connect rather than leaking, but there is no
global block; no per-app routing or rule lists yet.

## Development

Xcode 26 is required (Swift 6 language mode, strict concurrency).

```sh
scripts/fetch-bins.sh            # download pinned sing-box, build static openvpn (universal)
scripts/dev-sign.sh              # build signed with your Apple Development identity
swift test --package-path Wayfork/WayforkCore
scripts/format.sh --lint         # swift-format check (scripts/format.sh to fix)
```

`Wayfork/Wayfork.xcodeproj` holds the `Wayfork` app and `WayforkDaemon` targets;
`Wayfork/WayforkCore` is a local Swift package shared by both. Plain `xcodebuild` and
Xcode's Run produce ad-hoc signed builds that work for UI work but cannot register the
privileged helper — use `scripts/dev-sign.sh` for that. Pinned versions live in
`scripts/versions.env`; bundled binaries go to `Wayfork/Resources/bin/` (git-ignored).
Design notes are in [docs/design/](docs/design/), the UI prototype the screenshots come
from is [docs/design/prototype/variant-b.html](docs/design/prototype/variant-b.html).

## License

TBD
