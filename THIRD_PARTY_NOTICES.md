# Third-party notices

Wayfork's own source code is licensed under the GNU General Public License v3.0 or later
(see [LICENSE](LICENSE)). Release builds also ship the third-party components below. They
run as separate programs (or, for the block list, as data) and remain under their own
licences. Exact versions and checksums are pinned in
[scripts/versions.env](scripts/versions.env); the corresponding source code is available
at the links below for the pinned version.

The full licence texts are in [licenses/](licenses/), copied verbatim from upstream at the
pinned versions, and ship with every build next to this file: `Wayfork.app/Contents/Resources/licenses/`
on macOS, `<install folder>\licenses\` on Windows.

| Component | Licence text |
|---|---|
| sing-box | `licenses/sing-box.txt` (notice and extra term; full GPL-3.0 text in `LICENSE`) |
| OpenVPN, LZO | `licenses/openvpn-COPYING.txt`, `licenses/openvpn-COPYRIGHT.GPL.txt` (GPL-2.0 text) |
| OpenSSL | `licenses/openssl.txt` |
| LZ4 | `licenses/lz4.txt` |
| pkcs11-helper | `licenses/pkcs11-helper.txt` |
| ovpn-dco | `licenses/ovpn-dco-win.txt` |
| oisd block list | GPL-3.0, same text as `LICENSE` |
| `golang.org/x/sys` | `licenses/golang-x-sys.txt` |
| `golang.zx2c4.com/wireguard/windows` | `licenses/wireguard-windows.txt` |

## sing-box

- Shipped as: `sing-box` (macOS), `sing-box.exe` with embedded wintun (Windows)
- Version: `SING_BOX_VERSION` in `scripts/versions.env`, official release binaries
- Licence: GNU General Public License v3.0 or later, with an additional term: "no
  derivative work may use the name or imply association with this application without
  prior consent". Wayfork is not affiliated with or endorsed by the sing-box project.
- Copyright (C) 2022 by nekohasekai
- Source: https://github.com/SagerNet/sing-box (tag `v<SING_BOX_VERSION>`)

## OpenVPN

- Shipped as: `openvpn` built from the source tarball (macOS); `openvpn.exe` and
  `tapctl.exe` from the OpenVPN community installer (Windows)
- Version: `OPENVPN_VERSION` in `scripts/versions.env`
- Licence: GNU General Public License v2, with the OpenSSL linking exception; see
  `COPYING` in the OpenVPN source distribution
- Copyright (C) 2002-2026 OpenVPN Inc. "OpenVPN" is a trademark of OpenVPN Inc; Wayfork is
  not affiliated with or endorsed by OpenVPN Inc.
- Source: https://github.com/OpenVPN/openvpn (tag `v<OPENVPN_VERSION>`), also
  https://swupdate.openvpn.org/community/releases/

### Libraries linked into OpenVPN

| Component | Shipped as | Licence | Source |
|---|---|---|---|
| OpenSSL (`OPENSSL_VERSION`) | statically linked (macOS); `libcrypto-3-*.dll`, `libssl-3-*.dll` (Windows) | Apache License 2.0 | https://github.com/openssl/openssl |
| LZ4 (`LZ4_VERSION`) | statically linked (macOS) | BSD 2-Clause (library) | https://github.com/lz4/lz4 |
| LZO (`LZO_VERSION`) | statically linked (macOS) | GNU GPL v2 or later | https://www.oberhumer.com/opensource/lzo/ |
| pkcs11-helper | `libpkcs11-helper-1.dll` (Windows) | BSD 3-Clause or GPL v2 (dual) | https://github.com/OpenSC/pkcs11-helper |
| Microsoft Visual C++ runtime | `vcruntime140.dll` (Windows) | Microsoft Visual C++ Redistributable licence | https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist |

## ovpn-dco (Windows)

- Shipped as: the ovpn-dco driver package (`.inf`, `.sys`, `.cat`) taken from the OpenVPN
  community installer
- Version: `OVPN_DCO_VERSION` in `scripts/versions.env`
- Licence: MIT
- Source: https://github.com/OpenVPN/ovpn-dco-win

## oisd block list

- Shipped as: the compiled `block-ads.srs` rule set (data, not code)
- Version: commit `BLOCKLIST_COMMIT` in `scripts/versions.env`
- Licence: GNU General Public License v3.0
- Source: https://github.com/sjhgvr/oisd, homepage https://oisd.nl

## Go modules (Windows service)

| Module | Licence |
|---|---|
| `golang.org/x/sys` | BSD 3-Clause |
| `golang.zx2c4.com/wireguard/windows` | MIT |

Flutter/Dart packages used by the Windows app are listed in `windows/app/pubspec.lock`
and carry their own licences. The macOS app has no third-party Swift packages.
