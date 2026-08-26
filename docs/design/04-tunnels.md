# Tunnels: OpenVPN and VLESS

Technical side of F1. Two tunnel kinds with very different shapes: OpenVPN is an external
process the daemon babysits; VLESS is a few fields in the sing-box config.

## OpenVPN

### Import (app)

Input: a `.ovpn` file (drag & drop, file picker, or `Replace Config…`).

1. Parse line-by-line into directives; support inline blocks (`<ca>…</ca>`, `<cert>`,
   `<key>`, `<tls-auth>`, `<tls-crypt>`, `<tls-crypt-v2>`, `<dh>`, `<pkcs12>`,
   `<crl-verify>`).
2. Inline referenced files: for `ca`, `cert`, `key`, `tls-auth`, `tls-crypt`,
   `tls-crypt-v2`, `dh`, `pkcs12`, `crl-verify` with a file argument, read the file relative
   to the `.ovpn` location and convert to an inline block (`pkcs12` is base64-encoded).
   Missing → `import.ovpn.missingFiles` listing the names.
   `auth-user-pass <file>` → read the two lines as credentials (offered prefilled), the
   directive becomes bare `auth-user-pass`.
3. Strip directives we control or refuse:
   - interface/route/DNS: `dev`, `dev-type`, `dev-node`, `route`, `route-ipv6`,
     `redirect-gateway`, `redirect-private`, `dhcp-option`, `route-nopull`, `pull-filter`,
     `block-outside-dns`, `ifconfig-noexec`, `route-noexec`
   - process/scripting: `daemon`, `management*`, `up`, `down`, `route-up`, `route-pre-down`,
     `ipchange`, `client-connect`, `client-disconnect`, `learn-address`, `auth-user-pass-verify`,
     `tls-verify`, `script-security`, `plugin`, `log`, `log-append`, `writepid`, `status`,
     `user`, `group`, `chroot`, `verb`, `mute`
   Stripped lines are reported in the import preview ("12 directives ignored: …").
4. Reject: `dev tap` / `dev-type tap` (`import.ovpn.unsupported`), no `remote`, `mode server`.
5. Detect `needsCredentials` (`auth-user-pass` present) and `needsKeyPassphrase` (inline
   key contains `ENCRYPTED`). Collect `remotes` (`remote host [port] [proto]`, plus global
   `port`/`proto` defaults) for display.
6. Store the sanitized body in Keychain, metadata in the store. The body is exactly what the
   daemon later writes to `run/t-<id>.ovpn`; the daemon adds nothing to it.

### Runtime (daemon)

Spawned via `posix_spawn`, no shell:

```
<bundle>/Contents/Resources/bin/openvpn
  --config      <run>/t-<id>.ovpn
  --dev         tun
  --dev-type    tun
  --dev-node    utun<101+slot>
  --route-nopull
  --script-security 1
  --management  <run>/t-<id>.sock unix
  --management-hold
  --management-query-passwords
  --auth-nocache
  --auth-retry  interact
  --persist-tun --persist-key
  --resolv-retry infinite
  --connect-retry 2 60
  --verb 3
  --machine-readable-output
  --suppress-timestamps
  --dns-updown disable
```

- `--dns-updown disable`: OpenVPN 2.7 ships a `dns-updown` script that would rewrite the
  system resolver from pushed `dhcp-option DNS`. The bundled binary is built with
  `--disable-dns-updown-by-default` (see `scripts/fetch-bins.sh`) and the flag makes the
  intent explicit — DNS is sing-box's job.
- `--route-nopull` ignores pushed routes and DHCP options (DNS), leaving the default route
  alone; the interface still gets its `ifconfig` from the server.
- `--dev-node utunN` with a fixed high unit number avoids collisions with system VPNs and
  other clients, and makes the interface name known before the process starts, so the
  sing-box config can be generated up front. Unit numbers ≥ 100 work (verified 2026-08-25).
  Implementation note (2026-08-25, first e2e): on Darwin OpenVPN reads the unit from
  `--dev-node utunN` only — `--dev utunN` means "any utun" and the process silently took
  `utun4` while sing-box bound `t-<id>` to `utun105` ("route ip+net: no such network
  interface" on every dial, "route: bad interface name" from the scoped route). The daemon
  now also checks OpenVPN's `Opened utun device utunN` line against the planned name and
  fails the tunnel (`ovpn.configError`) on a mismatch instead of reporting it connected.
- Runs as root for MVP. Dropping to `nobody` conflicts with re-`ifconfig` on reconnect;
  revisit in Later.
- The management socket lives in the root-only `run/` directory. Credentials go through
  it, never to disk.

### Management protocol handling

The daemon connects to the unix socket (retry every 100 ms, up to 5 s), then:

```
state on
log on
bytecount 5          (for L4 counters; harmless now)
hold release
```

Events handled:

| Line | Action |
|------|--------|
| `>HOLD:Waiting for hold release` | `hold release` — `--management-hold` is persistent, openvpn hibernates again after every soft restart (`server_poll`, `ping-restart`); the initial release on connect stays as a belt-and-braces |
| `>PASSWORD:Need 'Auth' username/password` | `username "Auth" <u>` / `password "Auth" <p>`; if none stored → `failed(needsCredentials, permanent)` |
| `>PASSWORD:Need 'Private Key' password` | `password "Private Key" <pp>`; none → `failed(needsKeyPassphrase, permanent)` |
| `>PASSWORD:Verification Failed: 'Auth'` | `failed(authRejected, permanent)`, send `signal SIGTERM` |
| `>STATE:<t>,CONNECTED,SUCCESS,<local ip>,<remote ip>,…` | `connected`; add scoped route (below); record ip |
| `>STATE:<t>,RECONNECTING,<reason>` | `reconnecting`; `reason` in status |
| `>STATE:<t>,EXITING,…` | wait for process exit |
| `>LOG:<t>,<flags>,<msg>` | forward to log stream; parse `PUSH_REPLY` for `dhcp-option DNS` → `discoveredDNS` |
| `>FATAL:<msg>` | `failed(<msg>)`; permanent if it's an options/config error |
| socket closed without EXITING | treat as crash → supervisor restart policy |
| stdout/stderr before the socket is up | forwarded to the log; a `F`-flagged `Options error` / certificate load error → `failed(configError, permanent)` |

`reconnect(tunnelID:)` terminates the current attempt, resets backoff and respawns with
attempt 1 — also for permanently failed tunnels and with `autoReconnect` off (it is the
user's explicit request). Stopping a tunnel sends `signal SIGTERM` through the management
socket and `SIGTERM` to the process, waits 5 s, then `SIGKILL`.

Quoting for `username`/`password` follows the management spec (backslash-escape `"` and
`\`). Passwords never appear in logs: the management client redacts its own writes.

### Interface-scoped default route

Sockets bound to `utun101` with `IP_BOUND_IF` use macOS scoped routing, which requires a
route in that interface's scope for arbitrary destinations. After CONNECTED the daemon runs:

```
/sbin/route -n add -inet default -ifscope utun101 -interface utun101
```

This does not touch the unscoped (system) routing table, so nothing else on the machine
notices the tunnel. Removed on tunnel stop (`route delete -ifscope …`); the kernel drops it
anyway when the interface goes away. IPv6 is not routed through OpenVPN tunnels in MVP.

### Pushed DNS discovery

`route-nopull` ignores pushed `dhcp-option DNS`, but openvpn still logs the whole
`PUSH_REPLY` at verb 3. The daemon parses it and reports `discoveredDNS` in the tunnel
status. The app persists it into `OpenVPNMeta.discoveredDNS`; if the tunnel's DNS mode is
`.auto` and the value differs from what the current sing-box config uses, the plan changes
and sing-box restarts once. Until a server has pushed anything, `.auto` falls back to
`1.1.1.1` through the tunnel.

## VLESS

### URI parsing (app)

Format (de-facto XTLS sharing-link standard):

```
vless://<uuid>@<host>:<port>?<query>#<name>
```

| Query key | Meaning | Mapping |
|-----------|---------|---------|
| `encryption` | must be `none` (or absent) | else `import.vless.invalid` |
| `type` | transport: `tcp` (default), `ws`, `grpc` | `VLESSTransport`; `kcp`, `http`, `httpupgrade`, `xhttp` → `import.vless.unsupported` (XHTTP is planned via a bundled Xray-core, ROADMAP L3; the pinned sing-box has no such transport) |
| `security` | `none`, `tls`, `reality` | `VLESSSecurity` |
| `sni` | TLS server name | `sni` (defaults to host) |
| `fp` | uTLS fingerprint | `fingerprint` |
| `alpn` | comma-separated | `alpn` |
| `pbk`, `sid` | REALITY public key / short id | `pbk` required when `security=reality`; `sid` optional (sing-box accepts an empty short id) |
| `spx` | REALITY spider | ignored |
| `flow` | `xtls-rprx-vision` | `flow`; other values → unsupported |
| `path`, `host` | WebSocket path / Host header | `.ws(path:host:)` |
| `serviceName` | gRPC service | `.grpc(serviceName:)` |
| `headerType` | TCP HTTP obfuscation | anything but `none` → unsupported |
| `allowInsecure` / `insecure` | `1` → skip cert verify | `allowInsecure` (UI shows a warning badge) |

Fragment (percent-decoded) becomes the tunnel name; falls back to `host`. The UUID goes to
Keychain, everything else to `VLESSMeta`. The URL shown in the UI has the UUID masked; `Copy`
reconstructs the full URL from meta + Keychain.

### sing-box outbound mapping

```json
{
  "type": "vless", "tag": "t-<id>",
  "server": "<host>", "server_port": <port>,
  "uuid": "<uuid>",
  "flow": "xtls-rprx-vision",                      // omitted when nil
  "tls": {                                         // omitted when security=none
    "enabled": true,
    "server_name": "<sni>",
    "insecure": false,
    "alpn": ["h2", "http/1.1"],                    // omitted when empty
    "utls": { "enabled": true, "fingerprint": "chrome" },      // when fp set
    "reality": { "enabled": true, "public_key": "<pbk>", "short_id": "<sid>" }  // when reality
  },
  "transport": { "type": "ws", "path": "/x", "headers": { "Host": "<host>" } }
  // or { "type": "grpc", "service_name": "<name>" }; omitted for tcp
}
```

Validation at import: `flow` requires `security=tls|reality` and `type=tcp`; `reality`
requires `pbk`; `ws`/`grpc` with `reality` is rejected (sing-box does not support it).

No process, no routes, no DNS entry: the tunnel is "ready" whenever sing-box runs.
Reachability is only observed per connection until L4 adds health checks.
