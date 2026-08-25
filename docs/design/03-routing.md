# Routing engine: sing-box configuration

Covers the technical side of F2 (rules), F3 (hot reload) and the DNS part of F6. The app
generates `sing-box.json` plus one rule-set file per tunnel from the store; the daemon
writes them to `run/` and runs `sing-box run -D <run> -c sing-box.json`.

## Principles

1. **Everything enters TUN.** sing-box's `auto_route` makes `utun100` the default route.
   Non-matched traffic exits through the `direct` outbound on the physical interface
   (`auto_detect_interface`), so latency cost for direct traffic is one userspace hop.
2. **Matched domains get fake IPs.** DNS queries for domains covered by a rule are answered
   from the fake-ip range, so sing-box knows the domain for every connection regardless of
   protocol (no reliance on SNI). Unmatched domains are resolved for real.
3. **Sniffing is the safety net.** TLS SNI / HTTP Host sniffing routes connections whose
   domain was resolved outside our DNS (browser DoH, cached answers, newly added rules).
4. **Per-tunnel resolvers for OpenVPN.** The `direct` outbound bound to `utun10N` resolves
   its domains via a DNS server detoured through that same tunnel: no DNS leak, and answers
   are geo-consistent with the exit.
5. **OpenVPN's own control traffic goes direct**, matched by process path, so it never
   loops through a tunnel.
6. **Exceptions come first, the default tunnel last** (F8). `rules-direct` (user
   exceptions + built-in local names) is the first route and DNS rule; `route.final` is
   the default tunnel's outbound when one is set, `direct` otherwise.

## Generated config

Two tunnels: `Work` (OpenVPN, slot 0 → `utun101`, pushed DNS `10.8.0.1`) and `Home` (VLESS,
REALITY, vision). Placeholders in angle brackets.

```json
{
  "log": { "level": "info", "timestamp": true },

  "dns": {
    "servers": [
      { "type": "local", "tag": "dns-direct" },
      { "type": "udp",   "tag": "dns-t-<work>", "server": "10.8.0.1", "detour": "t-<work>" },
      { "type": "fakeip","tag": "fakeip",
        "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18" }
    ],
    "rules": [
      { "rule_set": ["rules-t-<work>", "rules-t-<home>"],
        "query_type": ["A", "AAAA"], "server": "fakeip" }
    ],
    "final": "dns-direct",
    "strategy": "ipv4_only",
    "independent_cache": true
  },

  "inbounds": [{
    "type": "tun", "tag": "tun-in",
    "interface_name": "utun100",
    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
    "mtu": 1500,
    "auto_route": true,
    "strict_route": false,
    "route_exclude_address": [
      "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
      "169.254.0.0/16", "224.0.0.0/4", "fe80::/10", "ff00::/8"
    ],
    "stack": "system"
  }],

  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "direct", "tag": "t-<work>",
      "bind_interface": "utun101",
      "domain_resolver": { "server": "dns-t-<work>", "strategy": "ipv4_only" } },
    { "type": "vless", "tag": "t-<home>",
      "server": "<host>", "server_port": 443, "uuid": "<uuid>", "flow": "xtls-rprx-vision",
      "tls": { "enabled": true, "server_name": "<sni>",
               "utls": { "enabled": true, "fingerprint": "chrome" },
               "reality": { "enabled": true, "public_key": "<pbk>", "short_id": "<sid>" } } }
  ],

  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "process_path": ["<bundle>/Contents/Resources/bin/openvpn"], "outbound": "direct" },
      { "rule_set": "rules-t-<work>", "outbound": "t-<work>" },
      { "rule_set": "rules-t-<home>", "outbound": "t-<home>" },
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "rule_set": [
      { "type": "local", "tag": "rules-t-<work>", "format": "source", "path": "rules-t-<work>.json" },
      { "type": "local", "tag": "rules-t-<home>", "format": "source", "path": "rules-t-<home>.json" }
    ],
    "final": "direct",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-direct",
    "find_process": true
  },

  "experimental": {
    "cache_file": { "enabled": true, "path": "cache.db", "store_fakeip": true }
  }
}
```

The daemon adds `experimental.clash_api` (loopback controller + per-start secret) to this
config before writing it — traffic rates for F9, see [05-daemon.md](05-daemon.md), "Traffic
sampling". The generator and the golden files do not contain it. Enabling the Clash API
turns on sing-box's per-connection byte counting; it has no effect on routing.

Notes on specific choices:

- `route_exclude_address` keeps LAN, link-local and multicast out of TUN entirely. ULA
  (`fc00::/7`) is deliberately *not* excluded because the fake-ip v6 range lives there.
  For the same reason the `ip_is_private` rule comes **after** the rule-set rules: a
  fake-ip v6 address is "private" and would otherwise short-circuit to direct.
- `strict_route: false`: strict mode on macOS breaks some local services and is unnecessary
  since we route by domain, not by "block everything else".
- `stack: "system"` is the conservative choice; `gvisor`/`mixed` can be revisited for
  performance in Later.
- `strategy: ipv4_only` for OpenVPN outbounds: tunnels are IPv4-only in MVP. VLESS gets
  the raw domain and resolves server-side.
- `dns-direct` of type `local` uses the OS resolvers through sing-box's own socket, which
  is bound to the physical interface, so there is no loop through the hijack rule.
  `settings.directDNS = .custom` replaces it with `{"type":"udp","server":"<ip>","detour":"direct"}`
  entries (first is primary; sing-box has no fallback list, so only the first is used —
  the UI says so).
- `hijack-dns` captures every plain-DNS packet that enters TUN, i.e. the system resolver's
  queries to the router. System DNS settings are never modified.
- `process_path` for openvpn: sing-box's `find_process` resolves the owning process of a
  new connection via `libproc`. If lookup fails the packet still goes `direct` by `final`,
  so the worst case is a tunnel domain rule matching the VPN server's hostname — the
  importer warns when a rule pattern covers a tunnel's own server host.
- `dns.strategy: ipv4_only`: every AAAA query that sing-box answers (hijacked system
  queries included) gets an empty NOERROR reply, so applications only ever connect over
  IPv4 while Wayfork is on. Without this, `auto_route` installs an IPv6 default route into
  the TUN and on an IPv4-only network every AAAA from the upstream resolver ends in a
  `direct` dial failing with "no route to host" (seen 2026-08-25: Safari/Telegram retried
  over v4 after the RST, but each connection paid for the failed attempt). Verified against
  sing-box 1.13.19 with a hijacked TCP query. Literal-IPv6 destinations still go through
  TUN → `direct`. Native IPv6 for direct traffic on dual-stack networks is a Later item; the
  fake-ip `inet6_range` stays configured for that.

## Default tunnel and exceptions (F8)

With `Store.defaultTunnelID` set to `Work` the config above changes as follows:

```json
"dns": {
  "servers": [ …, { "type": "tls", "tag": "dns-t-<home>", "server": "1.1.1.1", "detour": "t-<home>" } ],
  "rules": [
    { "rule_set": "rules-direct", "server": "dns-direct" },
    { "rule_set": ["rules-t-<work>", "rules-t-<home>"], "query_type": ["A", "AAAA"], "server": "fakeip" },
    { "query_type": ["A", "AAAA"], "server": "fakeip" }
  ],
  "final": "dns-t-<work>"
},
"route": {
  "rules": [
    { "action": "sniff" },
    { "protocol": "dns", "action": "hijack-dns" },
    { "process_path": ["<bundle>/Contents/Resources/bin/openvpn"], "outbound": "direct" },
    { "rule_set": "rules-direct", "outbound": "direct" },
    { "rule_set": "rules-t-<work>", "outbound": "t-<work>" },
    { "rule_set": "rules-t-<home>", "outbound": "t-<home>" },
    { "ip_is_private": true, "outbound": "direct" }
  ],
  "rule_set": [ { "type": "local", "tag": "rules-direct", "format": "source", "path": "rules-direct.json" }, … ],
  "final": "t-<work>"
}
```

- `rules-direct.json` is always emitted (possibly holding only the built-in entries) and
  the `rules-direct` route/DNS rules are always present, so adding or editing an exception
  is a rule-set rewrite (hot reload), not a restart. Built-in entries: `domain_suffix`
  `.local`, `.lan`, `.internal`, `.home.arpa`, `.localhost`, plus `localhost`.
- Every A/AAAA query that is not an exception gets a fake IP, so the default outbound dials
  by domain: VLESS resolves server-side, an OpenVPN default resolves through its own
  `domain_resolver` (pushed/custom DNS via the tunnel). Other query types (HTTPS, MX, …)
  go to `dns.final`, which is the default tunnel's resolver: `dns-t-<id>` for OpenVPN; for
  a VLESS default a DoT server (`1.1.1.1:853`) detoured through the VLESS outbound. Without
  a default tunnel the DNS section is exactly the M3 one.
- `ip_is_private` stays after the rule-sets and still sends LAN IPs direct; LAN *names* are
  covered by the built-in exceptions (resolved by `dns-direct`, routed `direct`).
- Kill-switch by construction: if the default OpenVPN tunnel is down, `bind_interface`
  dials on `utun10N` fail and unmatched connections are refused instead of leaking direct;
  a VLESS default that is unreachable fails per connection the same way. The popover says
  so while the default tunnel is not connected.
- `rules-direct` also carries user exceptions when there is no default tunnel: then it only
  overrides broader tunnel rules; `route.final` stays `direct`.
- Implementation notes (2026-08-25): `rules-direct.json` is emitted even with no tunnels at
  all, so the daemon's `PlanValidator` accepts that one extra name next to
  `rules-t-<id>.json`. `dns.strategy: ipv4_only` applies to the catch-all fake-ip rule too,
  so a default tunnel only ever sees fake v4 addresses. A default tunnel that is disabled
  or lacks its secret is dropped by the generator (`route.final` = `direct`), matching the
  UI warning. Golden variants `default-openvpn` and `default-vless` pass `sing-box check`.

## Rule-set files

One file per tunnel, `format: source`, regenerated whenever rules change:

```json
{
  "version": 3,
  "rules": [
    { "domain": ["example.com"], "domain_suffix": [".example.com"] },
    { "domain": ["api.other.com"] },
    { "domain_regex": ["^.+\\.cdn\\.example\\.com$"] }
  ]
}
```

Mapping from `RuleMatch`:

| `match`    | Emitted |
|------------|---------|
| `suffix`   | `domain: [p]` + `domain_suffix: [".p"]` (explicit, independent of sing-box's suffix semantics) |
| `exact`    | `domain: [p]` |
| `wildcard` | `domain_regex: ["^" + escape(p).replace("\\*", ".+") + "$"]` |

Entries are grouped by kind into a single rule object per tunnel (sing-box ORs them).
Disabled rules and rules whose tunnel is disabled are omitted. A tunnel with zero active
rules still gets an (empty) rule-set file so the main config doesn't change.

Order between groups: `rules-direct` first, then one route rule per tunnel in store order,
and each rule-set keeps its group's rule order. Identical patterns under a later tunnel are shadowed
and dropped (the UI flags them). Overlaps between different patterns (`a.example.com` exact
under Home, `example.com` suffix under Work) resolve by tunnel order — Work wins if it
comes first. L2 "where does this domain go?" makes this inspectable.

## Hot reload vs restart

| Change | Action |
|--------|--------|
| Rule added/edited/removed/reordered/toggled | rewrite `rules-*.json` → sing-box reloads local rule-sets on file change (verify; else restart) |
| Exception (Direct rule) added/edited/removed | rewrite `rules-direct.json` → same hot reload |
| Default tunnel set/cleared/changed | `route.final` / `dns.final` change → restart |
| Tunnel enabled/disabled, added, removed | outbounds change → `sing-box check` → restart sing-box (< 1 s) |
| Tunnel DNS changed, `discoveredDNS` updated | dns section changes → restart |
| `directDNS`, log level | restart |
| Tunnel credentials / OpenVPN config body | no sing-box change; openvpn process restarted |

Existing fake-ip mappings survive restarts through `cache.db`. Newly added rules for domains
that clients already resolved to real IPs are still honored through sniffing (SNI/Host).

## Startup verification

After `apply`, the daemon waits for sing-box to log its "started" line (or 3 s of survival)
and then verifies `utun100` exists (`if_nametoindex`) and that a public address leaves
through it (`route -n get -inet 1.1.1.1` → `interface: utun100`). `route -n get default`
is not used: `auto_route` with `route_exclude_address` installs split ranges, so the
unscoped default route still names the physical interface. Failure → the process is
killed, `engine = failed("singbox.startFailed")` and `apply` returns
`singbox.startFailed` with the last 20 log lines attached.
