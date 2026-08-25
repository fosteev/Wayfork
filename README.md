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

## License

TBD
