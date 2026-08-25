# Wayfork

macOS menu bar app for per-domain split tunneling across multiple VPNs at once.
Add your tunnels (OpenVPN `.ovpn`, VLESS `vless://`), write rules like
"`*.example.com` → work VPN", and everything else goes direct. All tunnels stay up
simultaneously — no switching.

Under the hood: [sing-box](https://github.com/SagerNet/sing-box) handles TUN, DNS and
routing; OpenVPN configs run as separate `openvpn` processes; a SwiftUI app ties it together.

## Status

**Early development.** Nothing usable yet. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Requirements

- macOS 14+

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

## License

TBD
