# Tunnels

Technical side of F1 and F13. Six kinds in two runtime shapes:

| Shape | Kinds | In the sing-box config | Process | Interface |
|-------|-------|------------------------|---------|-----------|
| External process | OpenVPN | `direct` outbound with `bind_interface` | `openvpn`, one per tunnel | own `utun` |
| Native | VLESS, Shadowsocks, Trojan, VMess | one entry in `outbounds[]` | — | — |
| Native | WireGuard | one entry in `endpoints[]` | — | userspace (gVisor) |

Everything native is "ready whenever sing-box runs": nothing to start, nothing to
supervise, no route to install. The tag is `t-<id>` in every case, so route rules, DNS
detours, rule-sets and the traffic counters do not care which kind is behind it — the one
exception is `endpoints[]` being a second array the generator has to fill (see
"What the pinned sing-box accepts").

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

## Shared TLS and transport (F13)

VLESS, Trojan and VMess carry the same `tls` and `transport` blocks, so the generator has
one builder for each, extracted from `vlessOutbound` unchanged (the VLESS goldens must not
move when it lands):

```swift
static func tlsBlock(security:server:sni:fingerprint:alpn:
                     realityPublicKey:realityShortID:allowInsecure:) -> [String: Any]?
static func transportBlock(_ transport: ProxyTransport) -> [String: Any]?
```

`VLESSSecurity` and `VLESSTransport` are renamed `TLSSecurity` and `ProxyTransport` and
shared by the three metas. Renaming changes no JSON: neither type name appears in
`store.json` (the enums encode by case name and payload), so no store migration and no
fixture churn.

**The metas stay flat and per-kind.** `TrojanMeta` and `VMessMeta` repeat the seven TLS
fields rather than embedding a shared `ProxyTLS` struct, because embedding would nest
`VLESSMeta`'s existing keys one level deeper — a store migration and a rewrite of every
golden `input.json` for no user-visible gain. Duplication in three structs, shared code in
one generator helper.

## WireGuard

### Import (app)

Input: a `.conf` file (`Add WireGuard…`, drag & drop, paste). wg-quick INI, one
`[Interface]` and one or more `[Peer]` sections; keys are case-insensitive, values may be
comma-separated lists, `#`/`;` start a comment.

| Key | Section | Meaning | Mapping |
|-----|---------|---------|---------|
| `PrivateKey` | Interface | 32-byte base64 | Keychain `tunnel/<id>/privateKey`; required, else `import.wireguard.invalid` |
| `Address` | Interface | tunnel addresses | `WireGuardMeta.addresses`; required; a bare IP is normalized to `/32` (sing-box rejects an address without a prefix); IPv6 entries dropped |
| `DNS` | Interface | resolvers inside the tunnel | first IPv4 entry → `discoveredDNS`, used by `TunnelDNS.auto`; IPv6 entries dropped |
| `MTU` | Interface | link MTU | `mtu`; absent → key omitted, sing-box defaults to 1408 |
| `ListenPort`, `Table`, `PreUp`, `PostUp`, `PreDown`, `PostDown`, `SaveConfig`, `FwMark` | Interface | wg-quick / kernel | ignored (nothing to do inside a userspace stack) |
| `PublicKey` | Peer | 32-byte base64 | `peer.publicKey`; required |
| `PresharedKey` | Peer | 32-byte base64 | Keychain `tunnel/<id>/presharedKey`; optional |
| `Endpoint` | Peer | `host:port` | `peer.host`, `peer.port`; required — a peer with no endpoint is a listener, which a client tunnel cannot use |
| `AllowedIPs` | Peer | prefixes routed into the tunnel | `peer.allowedIPs`; required (sing-box: `missing allowed ips for peer 0`); IPv6 entries dropped; warning badge when the result is not `0.0.0.0/0` |
| `PersistentKeepalive` | Peer | seconds | `peer.keepalive`; `0`/absent → omitted |

Unknown keys are ignored with a note in the import log, not refused: wg-quick confs pick up
distribution-specific extras and none of them change how the tunnel dials.

Validation at import (sing-box only notices some of this at start, and a start that fails
is a dead tunnel, so the parser is the gate): both keys decode to exactly 32 bytes;
`Address` holds at least one IPv4 prefix; every peer has `PublicKey`, `Endpoint` and
`AllowedIPs`; the port is 1…65535. Multiple peers are kept as written — sing-box picks by
`allowed_ips` — and the tunnel card shows the first peer's endpoint as its server.

**IPv6 is dropped on purpose**, matching the IPv4-only TUN (03-routing.md): a `::/0` in
`AllowedIPs` or an `fd00::/64` interface address would only offer sing-box a path it can
never be handed traffic for.

### sing-box endpoint mapping

```json
"endpoints": [{
  "type": "wireguard", "tag": "t-<id>",
  "system": false,                          // userspace stack (gVisor), never a real interface
  "mtu": 1420,                              // omitted when the conf has none
  "address": ["10.9.0.2/32"],
  "private_key": "<base64>",
  "domain_resolver": { "server": "dns-t-<id>", "strategy": "ipv4_only" },
  "peers": [{
    "address": "203.0.113.7",               // literal IP whenever the app knows one
    "port": 51820,
    "public_key": "<base64>",
    "pre_shared_key": "<base64>",           // omitted when the conf has none
    "allowed_ips": ["0.0.0.0/0"],
    "persistent_keepalive_interval": 25     // omitted when 0/absent
  }]
}]
```

`system: false` is explicit even though it is the default: a system interface would need
privileges the config generator has no business asking for.

### The peer address and `domain_resolver`

A WireGuard endpoint is an IP tunnel, so — exactly like OpenVPN and unlike a proxy
protocol — it has to resolve the destination name itself before it can put a packet on the
wire. That is what `domain_resolver` is for, and it must be the tunnel's own resolver
(`dns-t-<id>`), or every name routed into the tunnel would be resolved by the ISP and the
whole point of the tunnel is lost.

**But the same `domain_resolver` also resolves the peer's own hostname**, and a resolver
detoured through the endpoint that is trying to come up is a deadlock. Verified 2026-09-07
against 1.13.19 — peer `wg.example.net`, `domain_resolver: dns-t-<id>`:

```
ERROR dns: lookup failed for wg.example.net: dial UDP connection: WireGuard is not ready yet
FATAL start service: post-start endpoint/wireguard[wg]: resolve endpoint domain for peer[0]
```

So the generator emits, per tunnel:

- every peer address it can as a **literal IP**, taken from `Input.resolvedServerAddresses`
  (the map the app already fills for OpenVPN `remote` hosts, extended to WireGuard peers);
  with the peer given by IP, `domain_resolver: dns-t-<id>` starts and runs (verified).
  `HostResolver` drops answers inside the fake-IP range before they get there: a lookup made
  while Wayfork is On goes through Wayfork's own resolver, which returns a fake IP for every
  name the *currently applied* config does not send to `dns-direct` — which is exactly the
  case on the first apply after a WireGuard tunnel is added. Pinning that as the peer would
  dial the TUN in circles. Filtered, the host simply counts as unresolved and takes the
  fallback below; the next apply, with the host now in the DNS rule, resolves it for real;
- when a peer host is not resolved yet (first apply, offline, resolver down) the hostname
  goes in as written and the endpoint's `domain_resolver` degrades to `"dns-direct"`, so
  the tunnel comes up with direct name resolution instead of not at all; the next apply,
  once the address is known, promotes it back;
- peer hostnames join the existing `{"domain": [...], "server": "dns-direct"}` DNS rule
  next to the OpenVPN server names, so the app's own `getaddrinfo` — which goes through
  Wayfork while the F12 override is on — gets a real address instead of a fake IP. They get
  no *route* rule: sing-box dials its peers through its own dialer, which never passes
  through route rules.

DNS otherwise follows OpenVPN's shape (03-routing.md): `{"type": "udp", "tag": "dns-t-<id>",
"server": "<DNS from the conf, else 1.1.1.1>", "detour": "t-<id>"}`, `TunnelDNS.auto` /
`.custom` reused verbatim, and a WireGuard default tunnel gets that server as `dns.final`
instead of the DoT server the proxy kinds get.

### Throughput and MTU

The userspace stack costs throughput next to a kernel WireGuard; for split tunnelling that
is an acceptable trade and it is the only option without a Network Extension. sing-box's
default MTU is 1408, lower than wg-quick's 1420 — the conf's `MTU` wins when it has one.

## Shadowsocks

### Link parsing (app)

SIP002: `ss://<base64url(method:password)>@<host>:<port>/?<query>#<name>`. The legacy
whole-URI form `ss://<base64(method:password@host:port)>#<name>` is accepted too — panels
still emit it and detecting it is one `@` check after decoding. Userinfo that is not
base64 is treated as percent-encoded `method:password`, which some clients emit.

| Element | Meaning | Mapping |
|---------|---------|---------|
| userinfo | `method:password` | `ShadowsocksMeta.method`, Keychain `tunnel/<id>/password` |
| host, port | server | `server`, `port` |
| `plugin` | SIP003 plugin and its options | **rejected**, `import.link.unsupported` (see below) |
| fragment | name | tunnel name, falls back to `host` |

Accepted methods: `aes-128-gcm`, `aes-256-gcm`, `chacha20-ietf-poly1305`,
`xchacha20-ietf-poly1305`, `2022-blake3-aes-128-gcm`, `2022-blake3-aes-256-gcm`,
`2022-blake3-chacha20-poly1305`, and `none`. Anything else — `aes-256-cfb`, `rc4-md5`, the
rest of the pre-AEAD family — is `import.link.unsupported`.

Both rejections are **Wayfork policy, not a sing-box limitation** (checked 2026-09-07:
1.13.19 initializes `aes-256-cfb` happily, and ships `obfs-local` and `v2ray-plugin`
built in). They stand because F13's fence is "a kind ships only if a live server can prove
it", and the panel this was built against serves neither: shipping a code path nobody can
test is how silent breakage gets in. Lifting either is a whitelist entry plus two
pass-through fields in the generator on the day a server exists.

For a `2022-blake3-*` method the password is a base64 key of exactly the cipher's key
length (16 or 32 bytes); the parser checks it, because sing-box only fails at start
(`decode key: illegal base64 data`).

### sing-box outbound mapping

```json
{ "type": "shadowsocks", "tag": "t-<id>",
  "server": "<host>", "server_port": <port>,
  "method": "<method>", "password": "<password>" }
```

No TLS, no transport: the simplest outbound there is.

## Trojan

### Link parsing (app)

`trojan://<password>@<host>:<port>?<query>#<name>`; the password is percent-decoded from
the userinfo. The query is the VLESS query minus `encryption`, `flow` and `pbk`-only
concerns, and it maps through the same code:

| Query key | Meaning | Mapping |
|-----------|---------|---------|
| `security` | `tls` (default when absent), `reality` | `TLSSecurity`; `none` → `import.link.unsupported` (a plaintext Trojan is a Trojan with its one defence removed) |
| `sni`, `fp`, `alpn` | TLS | as VLESS (`sni` defaults to host; `fp` defaults to `chrome` under `reality`, which sing-box requires) |
| `pbk`, `sid` | REALITY | as VLESS; `pbk` required when `security=reality` |
| `type` | `tcp` (default), `ws`, `grpc` | `ProxyTransport`; others unsupported |
| `path`, `host`, `serviceName` | transport parameters | as VLESS |
| `allowInsecure` / `insecure` | skip cert verify | `allowInsecure`, warning badge |

### sing-box outbound mapping

```json
{ "type": "trojan", "tag": "t-<id>",
  "server": "<host>", "server_port": <port>, "password": "<password>",
  "tls": { … }, "transport": { … } }
```

`tls` and `transport` come from the shared builders, so Trojan is the first proof that the
extraction was faithful.

## VMess

### Link parsing (app)

`vmess://<base64(JSON)>` in the V2RayN form — the de-facto standard. Other forms
(Shadowrocket's `vmess://uuid@host:port?…`) are rejected with
`import.link.unsupported`: guessing between incompatible dialects is how a tunnel ends up
silently misconfigured.

| JSON key | Meaning | Mapping |
|----------|---------|---------|
| `add`, `port` | server | `server`, `port` — `port` may be a number or a string |
| `id` | uuid | Keychain `tunnel/<id>/uuid`; must parse as a UUID (sing-box accepts *any* string here and hashes it, so an invalid link would otherwise become a tunnel that connects to nothing) |
| `aid` | alterId | must be `0` (number or string), else `import.link.unsupported` — the legacy MD5 handshake is broken and no current server needs it |
| `scy` / `security` | cipher | `auto` (default), `none`, `zero`, `aes-128-gcm`, `chacha20-poly1305`; others rejected (`vmess: unsupported security type`) |
| `net` | transport | `tcp`, `ws`, `grpc`; `kcp`, `h2`, `quic`, `httpupgrade`, `xhttp` → unsupported |
| `type` | header obfuscation | anything but `none`/empty → unsupported |
| `tls` | `""`, `tls`, `reality` | `TLSSecurity` |
| `sni`, `fp`, `alpn` | TLS | as VLESS; `alpn` is comma-separated |
| `host`, `path` | ws Host / path, grpc authority | `ProxyTransport` |
| `ps` | name | tunnel name, falls back to `add` |
| `v` | link version (`2`) | ignored |

### sing-box outbound mapping

```json
{ "type": "vmess", "tag": "t-<id>",
  "server": "<host>", "server_port": <port>,
  "uuid": "<uuid>", "security": "auto", "alter_id": 0,
  "tls": { … }, "transport": { … } }
```

## Subscriptions (F13 stage 7)

Not a tunnel kind: a delivery mechanism for the four link kinds above. A subscription is
an `https://` URL whose body is a list of sharing links, and the whole feature is
"fetch, decode, run each line through `ProxyLinkParser`, let the user pick". Nothing new
reaches the store, the secrets or the generator — the result of an import is N ordinary
tunnels, indistinguishable from N pasted links.

### Fetch (app)

`SubscriptionFetcher.fetch(_ url: URL) async throws -> String` in WayforkCore (URLSession;
Dart: `dart:io` `HttpClient`). Policy, in the order it is applied:

| Rule | Why |
|------|-----|
| Scheme must be `https` (`http://` → `unsupported("subscriptions must use https")`) | the body carries the password / UUID of every server on it |
| Redirects followed, final URL must still be `https` | converters commonly 302 to a CDN |
| `User-Agent: Wayfork/<version>`, `Accept: text/plain, */*;q=0.1` | subscription converters key the *format* on the UA — Clash UAs get YAML, the rest get raw links; a neutral UA gets the links |
| 15 s timeout, body ≤ 1 MiB (`invalid("subscription is larger than 1 MiB")`) | a list of links is a few KB; anything bigger is not one |
| Non-2xx → `invalid("server answered <status>")` | shown verbatim in the sheet |
| Body decoded as UTF-8; invalid UTF-8 → `invalid("subscription is not text")` | |

The URL is a bearer token: it is not logged (`logs.app` gets the host only), not stored,
and not part of any diagnostics bundle. The fetch runs in the app process — the
daemon/service never sees it.

### Decode (pure, fixture-tested)

`SubscriptionDecoder.decode(_ body: String) throws -> [SubscriptionEntry]`,
`SubscriptionEntry = .link(ProxyLink, line: Int, uri: String) | .skipped(line: Int, reason: String)`:

1. Normalise line endings, trim the body. Empty → `invalid("subscription is empty")`.
2. **Plain form**: split into lines; if at least one trimmed line starts with a supported
   scheme (`vless://`, `ss://`, `trojan://`, `vmess://`, case-insensitive) the body is
   taken as is.
3. **Base64 form**: otherwise strip all whitespace, accept standard or URL-safe alphabets,
   add missing padding, decode, require UTF-8, and apply step 2 to the result. The
   PaperVPN body is form 2; V2RayN / 3x-ui exports are form 3.
4. Neither → `invalid("not a list of links")` — a Clash YAML, a sing-box JSON or an HTML
   error page all land here. (Converting those is a different feature.)
5. Every line, in order: blank lines and lines starting with `#` or `//` are dropped
   silently (some exporters write comments); a line with a scheme `ProxyLinkParser` does
   not know is `.skipped(reason: "unsupported scheme <scheme>://")`; a line the parser
   refuses is `.skipped` with the parser's reason. Line numbers are 1-based, counted in
   the decoded text.

Duplicates within one body are kept (the checklist shows them; the user decides).
Unknown-scheme lines are the normal case in the wild — `hysteria2://`, `tuic://`,
`wireguard://` — so they are *skipped*, never fatal.

### Import (app model)

`AppModel.addLinks(_ links: [ProxyLink], from host: String)` = `addLink` in a loop inside **one** store
update, stopping at the slot limit (the sheet already prevents that) and at the first
Keychain / DPAPI failure (the tunnels written so far stay; the alert names how many). Names
are `uniqueName(link.name.isEmpty ? link.server : link.name)` exactly as for one link,
so a subscription that names every server the same yields `NL`, `NL 2`, `NL 3`. A link
whose `TunnelKind` equals an existing tunnel's is the sheet's *already added* case; the
model does not re-check it.

### Fixture

`fixtures/links/subscription.json`: `cases[]` of `{name, body, expected: {links: [{line,
kind, name, server, port}], skipped: [{line, reason}]} | error: {kind, message}}`. Bodies
use the same placeholder servers and reserved UUIDs as `links/*.json`. Cases: `plain-one`
(the PaperVPN shape), `plain-mixed` (four kinds plus `hysteria2://` and a broken `ss://`),
`base64-standard` (with line breaks inside the base64), `base64-urlsafe-unpadded`,
`comments-and-blank-lines`, `empty`, `clash-yaml`, `html`.

## What the pinned sing-box accepts (1.13.19, checked 2026-09-07)

Everything below was run against the bundled binary before the mappings above were
written, because several of them contradict what the plan assumed.

- **An `endpoints[]` tag is a first-class outbound tag.** A WireGuard endpoint referenced
  as `route.final`, as a rule `outbound` and as a DNS server `detour` starts and runs.
  WireGuard therefore needs no process and no interface of its own.
- **`sing-box check` does not resolve tags.** A config whose `route.final` names an
  outbound nobody defines passes `check` with exit 0 and dies at `run` with
  `FATAL start service: default outbound not found`; the same for a DNS `detour`
  (`outbound detour not found`). The golden-fixture `check` in `TrafficTests` and the
  daemon's pre-apply `check` are therefore schema validators, not reference checkers — the
  generator tests carry their own assertion that every referenced tag exists.
- **Unknown keys are refused** (`decode config`), so an experimental key cannot be left in
  the generator by accident.
- **REALITY requires uTLS** (`uTLS is required by reality client`) — `fp` defaults to
  `chrome` wherever REALITY is accepted.
- **REALITY is accepted on `trojan` and `vmess`, and over `ws`/`grpc`.** The last part
  contradicts the VLESS note above ("`ws`/`grpc` with `reality` is rejected"), which is
  older than 1.13; the import rule stays as it is for now — relaxing it is an F1 change
  with its own live check, not something to slip in with F13 *(open)*.
- **WireGuard endpoint validation is thin**: a missing `private_key` and a peer without
  `allowed_ips` are refused, but a missing `address`, a peer with no port and even a peer
  list that is entirely absent all start "successfully" into a tunnel that can never carry
  a packet. Hence the parser-side validation listed under WireGuard.
- **An endpoint's `domain_resolver` resolves the peer's own address**, so it must not point
  at a DNS server detoured through that endpoint (see "The peer address and
  `domain_resolver`"). Both the string form (`"dns-direct"`) and the object form
  (`{"server": …, "strategy": …}`) are accepted.
- **VMess accepts a non-UUID `id`** and **`alter_id > 0`**, and **Shadowsocks accepts
  pre-AEAD ciphers and SIP003 plugins**. Every one of those is refused at import by
  Wayfork, by policy, not because sing-box would object.
