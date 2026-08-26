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
      { "type": "fakeip","tag": "fakeip", "inet4_range": "198.18.0.0/15" }
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
    "address": ["172.19.0.1/30"],
    "mtu": 1500,
    "auto_route": true,
    "strict_route": false,
    "route_exclude_address": [
      "10.0.0.0/8", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "224.0.0.0/4",
      "172.16.0.0/15", "172.18.0.0/16", "172.19.0.4/30", "…", "172.24.0.0/13"
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

- The `process_path` rule for the bundled `openvpn` is followed by a rule that sends the
  OpenVPN servers' own addresses and names direct (`ip_cidr` for IPv4 `remote`s, `domain`
  for the rest, one rule for all routed OpenVPN tunnels), and their names get real answers
  from `dns-direct` instead of a fake IP. Added 2026-08-25 after the first e2e run: the
  process match missed the very first UDP flow after start, and the whole OpenVPN control
  channel then ran through the VLESS default tunnel (tunnel-in-tunnel). Emitted only when
  an OpenVPN tunnel is routed; goldens regenerated.
- The `domain` half of that rule never matches openvpn's own packets: sing-box learns a
  flow's domain only from sniffing, fake-ip or `dns.reverse_mapping`, and openvpn's resolver
  query goes to the LAN router past the TUN (2026-08-26: a hostname `remote` fell through to
  the VLESS default tunnel while a literal one worked). So the app resolves the hostname
  `remote`s itself before building the plan (`HostResolver`, `getaddrinfo`, off the main
  actor) and adds every A record to the `ip_cidr` half; the name stays for flows that do
  carry it. A host that fails to resolve is logged and matched by name only. New addresses
  change the plan hash, so a DNS change re-applies on the next apply.

- `route_exclude_address` keeps LAN, CGNAT, link-local and multicast out of TUN entirely,
  **except the TUN's own subnet** `172.19.0.0/30`: `172.16.0.0/12` is emitted as the 18
  prefixes that cover it minus that /30 (`IPv4Prefix.subtracting`). sing-tun subtracts the
  exclusions from the auto-route split ranges, and on Darwin a point-to-point utun only gets
  a host route for its own address, so an exclusion covering the TUN subnet leaves
  `172.19.0.2` — where the system stack's TCP redirect sends its replies — with no route
  into the TUN. Symptom (2026-08-25): sing-box logs the process lookup for every SYN but
  never an `inbound connection`; UDP (DNS, QUIC) works, every TCP connection hangs.
  The `ip_is_private` rule comes **after** the rule-set rules so that a rule-set match
  always wins over the private-range short-circuit to direct.
- The TUN is **IPv4-only** (no `inet6` address, no fake-ip `inet6_range`). An IPv6 address on
  the TUN makes `auto_route` install an IPv6 default route, and from that moment every
  application believes the host is dual-stack: anything that resolves AAAA records outside
  sing-box's DNS (browser DoH, other proxy clients, cached answers) dials literal IPv6
  destinations into the TUN, and on an IPv4-only network each of those ends in `direct`
  failing with "no route to host" (seen 2026-08-25 — a whole evening of "nothing works").
  Without a v6 address the host's IPv6 state is whatever the physical interface provides;
  on a dual-stack network IPv6 traffic bypasses Wayfork (see Later, native IPv6).
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
  queries included) gets an empty NOERROR reply, so applications that use the system
  resolver only ever connect over IPv4 while Wayfork is on. Verified against sing-box
  1.13.19 with a hijacked TCP query. This alone was not enough (2026-08-25: Safari/Telegram
  retried over v4 after the RST, but each connection paid for the failed attempt, and
  DoH/other clients never fell back) — hence the IPv4-only TUN above. Native IPv6 for
  direct traffic on dual-stack networks is a Later item; it needs the v6 address and
  `inet6_range` back plus a way to tell whether the physical interface has IPv6.

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
| `app`      | `process_path_regex: ["^" + escape(p) + "/"]` in a **separate** rule object (F10) |
| `ip`       | `ip_cidr: [p]` in the separate `rules-…-ip.json` file, referenced by route rules only (F11) |

Domain entries are grouped by kind into a single rule object per tunnel (sing-box ORs the
domain items of one rule).
Disabled rules and rules whose tunnel is disabled are omitted. A tunnel with zero active
rules still gets an (empty) rule-set file so the main config doesn't change.

Order between groups: `rules-direct` first, then one route rule per tunnel in store order,
and each rule-set keeps its group's rule order. Identical patterns under a later tunnel are shadowed
and dropped (the UI flags them). Overlaps between different patterns (`a.example.com` exact
under Home, `example.com` suffix under Work) resolve by tunnel order — Work wins if it
comes first. L2 "where does this domain go?" makes this inspectable.

### Application rules (F10)

An app rule becomes a second headless rule in the same rule-set file. It must not share an
object with the domain items: within one rule sing-box ANDs items of different kinds and
ORs only the rules of the set.

```json
{ "process_path_regex": ["^/Applications/Telegram\\.app/"] }
```

`^` + RE2-escaped bundle path + `/`: every executable inside the bundle, helpers included,
and not `Telegram.app 2`. `find_process` is already on for the openvpn rule, so the
lookup costs nothing extra. DNS rules that reference the same rule-set are unaffected: the
process behind a hijacked DNS query is `mDNSResponder`, which never matches a bundle, so an
app's DNS follows the domain rules and the fake-ip catch-all as before; the connection is
then matched by process and its fake-ip destination is resolved by the outbound exactly
like a domain-routed connection. An app exception in `rules-direct.json` works the same way
(`default_domain_resolver` resolves for `direct`). Process lookup can fail for very
short-lived processes; such a connection falls through to the domain rules and the default —
sing-box logs the failed lookup at debug level, nothing else changes.

### IP rules (F11)

IP rules live in their own rule-set files, `rules-t-<id>-ip.json` and `rules-direct-ip.json`:
one rule object holding every active range of the group, always with a prefix length.

```json
{ "version": 3, "rules": [ { "ip_cidr": ["10.8.0.0/24", "203.0.113.7/32"] } ] }
```

Why a second file rather than another headless rule in `rules-t-<id>.json`: the DNS rules
reference the domain rule-sets, and in a DNS rule sing-box treats `ip_cidr` items of a
rule-set as an address filter on the *answer* — the query is performed first and the rule
is skipped when the answer does not match. With fake-ip answers the tunnel DNS rule would
then never match and every domain rule would silently stop working. Route-only files leave
DNS exactly as it is. Each route rule references both sets —
`{ "rule_set": ["rules-t-<id>", "rules-t-<id>-ip"], "outbound": "t-<id>" }`; rule-sets of
one rule are ORed — and the `rules-direct` rule gets `rules-direct-ip` the same way. Both
files are always emitted (possibly with `"rules": []`), so a rule change is a rewrite, not a
restart; the daemon's `PlanValidator` / `RunLayout` accept the `-ip` names.

What matches: the connection's destination address — connections opened to an IP literal,
or to a name resolved outside sing-box (browser DoH, another client's cache). A connection
opened by name through the system resolver carries a fake IP and is decided by the domain
rules alone; an IP rule does not apply to it even when the real address is in the range.
Resolving every unmatched name before the IP rules (sing-box's `resolve` action) would cost
a direct lookup per connection and leak the names — not done. Because `sniff` runs first,
an IP-literal connection with a TLS SNI is also offered to the domain rules; whichever
group comes first wins, as always.

Private ranges: `route_exclude_address` keeps `10.0.0.0/8`, `172.16.0.0/12`,
`192.168.0.0/16` and `100.64.0.0/10` out of the TUN, so an IP rule inside them would never
be seen. The generator therefore subtracts the ranges of the **active tunnel IP rules** from
the exclusion list with `IPv4Prefix.subtracting` — the mechanism of the TUN /30 carve-out:
`10.8.0.0/24 → Office` turns `10.0.0.0/8` into the prefixes that cover it minus that /24,
the subnet enters the TUN, hits the rule-set and leaves through the tunnel's
`bind_interface` outbound. This is the OpenVPN office case, where `--route-nopull` dropped
the pushed route. Direct IP rules never carve (excluded is direct already); `ip_is_private`
still comes after the rule-sets, so a carved-in address that no rule claims (a Direct
exception inside a carved range) goes direct. Ranges that overlap a reserved range are
emitted minus the reserved part (`172.16.0.0/12 → X` never covers `172.19.0.0/30`,
`198.0.0.0/8` never covers the fake-IP range). A carved-in range that overlaps the Mac's own
LAN is legal but flagged by the UI: the interface's connected route and the TUN's split
routes then compete for those addresses, and LAN devices in the range may be unreachable
while Wayfork is on.

Changing the exclusion list changes `sing-box.json`, so adding, removing or toggling a
tunnel IP rule inside a private range restarts sing-box (< 1 s, the fake-ip cache
survives); every other IP-rule change is a hot reload.

Implementation notes (2026-08-25): `RuleSetGenerator.renderIP` and
`SingBoxConfigGenerator.routeExcludeAddresses(carving:)`; the carve uses
`IPv4Prefix.subtracting(all:)` with the TUN /30 and the active tunnel IP rules as holes, so
`10.8.0.0/24 → Work` turns `10.0.0.0/8` into 16 prefixes. Golden variant `ip-rules` passes
`sing-box check` on 1.13.19. A tunnel that is enabled but unusable (no secret) carves
nothing — its rules are not emitted either.

## Hot reload vs restart

| Change | Action |
|--------|--------|
| Rule added/edited/removed/reordered/toggled | rewrite `rules-*.json` → sing-box reloads local rule-sets on file change (verify; else restart) |
| Exception (Direct rule) added/edited/removed | rewrite `rules-direct.json` → same hot reload |
| IP rule (F11) | rewrite `rules-…-ip.json` → hot reload; a *tunnel* IP rule inside a private range also changes `route_exclude_address` → restart |
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
