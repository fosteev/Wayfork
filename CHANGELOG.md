# Changelog

All notable changes to Wayfork are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.4.0] — 2026-09-02

Hardening from a day of field debugging (Discord voice through a UDP-filtering VPS,
a poisoned ISP resolver, and a daemon that had died silently).

### Added

- **One-way UDP warning.** A tunnel whose UDP connections keep sending but have received
  nothing for 10 seconds gets an orange ⚠ next to its traffic rate — the signature of a
  VPN server dropping UDP, which is how broken voice chat and gaming look. The counts are
  also logged and included in Export Diagnostics, which now carries a traffic summary.

### Fixed

- **A slow TUN bring-up no longer kills a healthy start.** The startup check polls for up
  to 12 seconds and retries the start once, instead of a single check after 3 seconds
  that could declare a working sing-box failed. Turn Off during a failing start answers
  immediately.
- **A routing engine that cannot start is loud now.** The menu bar / tray icon shows the
  error state, one notification per failure streak says Wayfork keeps retrying, and the
  app re-applies on its own with growing backoff (5 s … 5 min) until the engine is back —
  previously the app looked On while everything routed direct.
- **Traffic labels no longer trust a poisoned resolver.** `reverse_mapping` is emitted
  only when a default tunnel needs it for routing, so a spoofed ISP answer for a blocked
  domain can no longer tag unrelated raw-IP connections with that domain.

## [0.3.0] — 2026-08-29

### Added

- **Windows: pick an application rule from what is running.** *Rules → + → Application…*
  now lists the running applications by their real names (Google Chrome, not `chrome`),
  with a search box, an optional view of background processes and *Browse…* for an app
  that is not started.

### Fixed

- The service client could throw "Future already completed" when a reconnect wait ended
  at the same moment as *Retry* or shutdown.

## [0.2.0] — 2026-08-28

### Added

- **Windows client** (preview): the same features on Windows 10/11, x64 and ARM64 — a
  Fluent UI app in the notification area over a LocalSystem service that owns sing-box,
  the OpenVPN processes, the adapters, the routes and the DNS override. Tunnels, rules
  (domain, application, IP), the default tunnel, traffic rates, logs, import/export and
  Export Diagnostics all work as they do on macOS; `wayfork-export.json` carries a
  configuration between the two, minus the application rules, which name a path per
  platform. Shipped as `Wayfork-<version>-<arch>.msi`, unsigned until the project has an
  Authenticode certificate.

### Known limitations

- The Windows packages carry no Authenticode signature, so SmartScreen warns on the
  installer and on the first run ("More info" → "Run anyway"); the bundled sing-box is
  unsigned upstream and is trusted by its install location instead.
- The macOS build in this release is still signed with an Apple Development certificate,
  with the same quarantine step as 0.1.0 (README, "Install"); every 0.1.0 limitation below
  still stands on both platforms.

## [0.1.0] — 2026-08-26

First release: per-domain split tunneling across several VPNs at once from the menu bar.

### Added

- **System resolver override**: while On, the Mac's DNS points at Wayfork's own resolver
  and is restored when Off (also after a crash), so every application that asks the
  system resolver is routed by domain — including hosts whose public record is a private
  address. A resolver entered by hand in System Settings is replaced and put back when
  Off; a setting turns the override off. Encrypted-DNS discovery (DDR) is refused and
  port 443/853 to the resolvers is rejected so that macOS cannot sidestep it.
- **Fake IPs in rules**: pasting a `198.18.x.x` address from the logs into a rule field
  turns it into the wildcard rule of the name it was issued to (`*.example.com`); a
  rule on the address itself could never match.
- **Tunnels**: OpenVPN profiles (`.ovpn` with inline certs and keys, username/password and
  key passphrase asked once and kept in the Keychain) and VLESS URIs (TCP, WebSocket, gRPC;
  TLS and REALITY). Rename, enable/disable, reconnect, replace the config.
- **Rules**: domain → tunnel with exact, suffix and wildcard patterns; first match wins;
  grouped by tunnel, reorder by drag, warnings for shadowed and duplicate rules.
- **Application rules**: an `.app` bundle → tunnel or Direct, covering every process inside
  the bundle.
- **IP rules**: an IPv4 address or subnet → tunnel or Direct; a tunnel rule inside a private
  range pulls that subnet into the tunnel (OpenVPN office networks); warning when a rule
  covers the Mac's own LAN.
- **Default tunnel** ("route everything else") and **exceptions** (rules that target Direct,
  highest priority); `.local`, `.lan`, `.internal`, `.home.arpa` always direct; unmatched
  traffic is blocked while the default tunnel is down.
- **Quick add** from the popover: domain or IP → tunnel or Direct, applied immediately.
- **Start / stop** with one switch; rule edits hot-reload, tunnel edits reconnect only that
  tunnel; the privileged helper is registered through `SMAppService` and approved once in
  System Settings — no password prompts.
- **Status**: menu bar icon (off / connecting / on / degraded / error), a card per enabled
  tunnel with its state and rule count, notifications on tunnel failure.
- **Traffic rates**: live download / upload per tunnel and for Direct in the popover, session
  totals and open connections on hover.
- **Logs**: app, sing-box and per-tunnel OpenVPN logs in one window, filter by source and
  level, log level and retention settings; **Export Diagnostics** zips logs and a sanitized
  config with secrets stripped.
- **Settings**: launch at login, connect on launch, auto-reconnect with backoff, resolver for
  direct traffic (system / custom), JSON export / import of tunnels and rules (secrets
  optional), reinstall helper.
- Bundled, pinned binaries: sing-box 1.13.19 and a static OpenVPN 2.7.6 (OpenSSL 3.5),
  universal (Apple silicon and Intel).

### Known limitations

- Not notarized: the download is signed with an Apple Development certificate, so
  Gatekeeper blocks it until `xattr -dr com.apple.quarantine /Applications/Wayfork.app`
  (README, "Install").
- IPv4 only while On: no IPv6 address on the TUN and no AAAA answers.
- Browsers using their own DNS-over-HTTPS bypass domain rules (they are seen by IP only).
- No kill switch: a matched domain whose tunnel is down fails to connect instead of leaking,
  but there is no global block.
- Application rules see only traffic that enters the TUN; an app behind a local proxy is
  matched as the proxy. IP rules are IPv4, destination-address only.
- No rule lists / subscriptions, no WireGuard, Shadowsocks or XHTTP transports yet.

[0.4.0]: https://github.com/fosteev/Wayfork/releases/tag/v0.4.0
[0.3.0]: https://github.com/fosteev/Wayfork/releases/tag/v0.3.0
[0.2.0]: https://github.com/fosteev/Wayfork/releases/tag/v0.2.0
[0.1.0]: https://github.com/fosteev/Wayfork/releases/tag/v0.1.0
