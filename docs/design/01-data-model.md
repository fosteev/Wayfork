# Data model and storage

Covers F1 (tunnels), F2 (rules), F6 (settings), F7 (import/export) at the data level.

## Entities

```swift
struct Store: Codable {
    var schemaVersion = 1
    var tunnels: [Tunnel]
    var rules: [Rule]                 // ordered within a tunnel; see "Rule order" below
    var settings: Settings
    var defaultTunnelID: UUID?        // F8: "everything else" exit; nil → direct
}

struct Tunnel: Codable, Identifiable {
    var id: UUID
    var name: String                  // unique, 1…40 chars
    var isEnabled: Bool
    var slot: Int                     // 0…31, unique, stable; OpenVPN interface = utun(101 + slot)
    var kind: TunnelKind
    var createdAt: Date
}

enum TunnelKind: Codable {
    case openVPN(OpenVPNMeta)
    case vless(VLESSMeta)
}

struct OpenVPNMeta: Codable {         // config body itself is in Keychain
    var remotes: [Remote]             // for display: host, port, proto
    var needsCredentials: Bool        // config has `auth-user-pass`
    var needsKeyPassphrase: Bool      // inline key is encrypted
    var dns: TunnelDNS                // resolver used for this tunnel's domains
    var discoveredDNS: [String]       // last `dhcp-option DNS` pushed by the server
    var configHash: String            // SHA-256 of the sanitized body
}

enum TunnelDNS: Codable {
    case auto                         // discoveredDNS if known, else fallback 1.1.1.1 via the tunnel
    case custom([String])             // IPs
}

struct VLESSMeta: Codable {           // UUID is in Keychain
    var server: String
    var port: Int
    var flow: String?                 // "xtls-rprx-vision" or nil
    var security: VLESSSecurity       // none | tls | reality
    var sni: String?
    var fingerprint: String?          // uTLS: chrome, firefox, safari, …
    var alpn: [String]
    var realityPublicKey: String?
    var realityShortID: String?
    var transport: VLESSTransport     // tcp | ws(path, host) | grpc(serviceName)
    var allowInsecure: Bool
}

struct Rule: Codable, Identifiable {
    var id: UUID
    var pattern: String               // normalized: lowercase, punycode, no trailing dot
    var match: RuleMatch              // suffix | exact | wildcard | app (F10) | ip (F11)
    var target: RuleTarget            // F8: .tunnel(id) | .direct (an exception)
    var isEnabled: Bool
    var note: String?
    var tunnelID: UUID? { target.tunnelID }
}

enum RuleTarget: Codable {
    case tunnel(UUID)
    case direct
}

struct Settings: Codable {
    var launchAtLogin = false
    var connectOnLaunch = false
    var autoReconnect = true
    var notifyOnTunnelFailure = true
    var directDNS: DirectDNS = .system   // resolver for non-matched traffic
    var logLevel: LogLevel = .info
    var logRetentionDays = 7
}

enum DirectDNS: Codable { case system; case custom([String]) }
```

VLESS tunnels have no DNS setting: sing-box hands the domain to the VLESS server, which
resolves it remotely. Only OpenVPN tunnels need a resolver reachable through the tunnel.

### Rule matching semantics

| `match`    | Pattern example      | Matches | Does not match |
|------------|----------------------|---------|----------------|
| `suffix`   | `example.com`        | `example.com`, `a.example.com`, `a.b.example.com` | `notexample.com` |
| `exact`    | `api.example.com`    | `api.example.com` | `v2.api.example.com` |
| `wildcard` | `*.cdn.example.com`  | `a.cdn.example.com`, `a.b.cdn.example.com` | `cdn.example.com` |
| `app`      | `/Applications/Telegram.app` | every process inside that bundle, any destination (F10) | other apps |

`*` stands for one or more characters including dots and must be the only special
character. `suffix` is the default; typing `*` switches the row to `wildcard`.

### Rule order

Rules are edited grouped by target. Effective order = the **Direct** group first
(exceptions always win), then tunnels in store order, and within a group the rules in list
order. A pattern that also appears in an earlier group is **shadowed** (never matches) and
flagged in the UI; the generator drops it.

### Default tunnel and exceptions (F8)

`Store.defaultTunnelID` names the tunnel that takes everything no rule matched; nil (the
default) keeps unmatched traffic direct. It must reference an existing tunnel; if that
tunnel is disabled or lacks its secret, the plan behaves as if no default were set and the
UI warns. Exceptions are ordinary rules with `target: .direct`; they are meaningful with a
default tunnel (carve-outs) and without one (override a broader tunnel rule). Duplicates
are rejected per group like everywhere else.

JSON stays schema 1: a tunnel rule keeps `"tunnelID": "<uuid>"`, a direct rule has
`"target": "direct"` and no `tunnelID`; a rule with neither (or an unknown `target`) is
invalid. `defaultTunnelID` is optional. In code `Rule.target: RuleTarget` is the stored
field and `tunnelID` a computed accessor; `Store.exceptions` / `rules(for: RuleTarget)`
address the groups, `Store.effectiveDefaultTunnel` applies the enabled check. Export files carry both fields the same way; on import a `defaultTunnelID`
pointing at a skipped tunnel is dropped with a warning, and on Merge the file's value
replaces the current one only when it is non-nil.

Validation: pattern is a hostname (labels of `[a-z0-9-]`, IDNA converted to punycode) with
`*` allowed only for wildcard; no scheme, path or port (the UI strips `https://…/` when
pasting a URL). Duplicates (same pattern + match under the same tunnel) are rejected; the
same pattern + match under a *different* tunnel is legal and simply shadowed when that
tunnel comes later (`RuleValidator`). A rule pointing at a
disabled or missing tunnel is shown greyed and does not match anything (traffic goes
direct; kill switch is L7).

### Application rules (F10)

`RuleMatch.app` marks a rule whose `pattern` is the absolute path of an application bundle
(`/Applications/Telegram.app`) instead of a hostname. It matches every process whose
executable lives inside the bundle — the main binary and all helpers
(`…/Contents/Frameworks/… Helper.app/…`), which is where most apps do their networking.

Normalization: trimmed, a `file://` URL turned into a path, trailing `/` removed, must be
absolute and end in `.app`; no lowercasing (paths are case-preserving), no punycode. The
bundle *path* is stored, not the bundle identifier: it is what sing-box matches, it needs
no lookup inside the daemon, and a moved app shows up in the UI as "not found" instead of
silently changing meaning. Existence is not checked in Core (tests, portability); the UI
shows a chip when the path does not exist, and the rule matches again once the app is back.

Ordering, duplicates and shadowing are the same as for domains: group order decides, an
identical `pattern` + `match` in one group is a duplicate, in a later group it is shadowed.
Domain and application rules of one group are peers — either one matches. When an app rule
and a domain rule of *different* groups disagree, the earlier group wins (tunnel order), as
for any two overlapping domain rules.

`store.json` becomes schema **2** with a no-op migration from 1: the data does not change,
but a build that does not know `"match": "app"` must refuse the file rather than fail on
the first app rule — `newerSchema` does exactly that. Export files carry app rules unchanged;
`ExportDocument.currentVersion` is bumped for the same reason.

### IP rules (F11)

`RuleMatch.ip` marks a rule whose `pattern` is an IPv4 address (`203.0.113.7`) or a subnet
in CIDR form (`10.8.0.0/24`). Normalization: trimmed, URL parts stripped as for domains
(`http://10.8.0.5:8080/x` → `10.8.0.5`), four decimal octets, optional `/1`…`/32`; host
bits are cleared (`10.8.0.5/24` → `10.8.0.0/24`) and `/32` is stored as the bare address.
Rejected: IPv6 (the TUN is IPv4-only until Later), `/0` (that is what the default tunnel is
for) and anything *inside* a reserved range — `0.0.0.0/8`, `127.0.0.0/8`, `169.254.0.0/16`,
`224.0.0.0/4`, `240.0.0.0/4`, the fake-IP range `198.18.0.0/15` and the TUN subnet
`172.19.0.0/30`. A wider pattern that merely overlaps a reserved range is accepted; the
generator carves the reserved part out. `RulePattern.inferMatch` returns `ip` when the
input parses as an address or CIDR, so the UI needs no separate entry point; `normalize`
with a domain match and IP-looking input fails with a dedicated reason so the UI can point
at the IP match. `IPv4Prefix` (already used by the generator) is the parsed form and moves
to `Support`.

Duplicates and shadowing: identical `pattern` + `match`, as for domains. Overlapping ranges
in different groups resolve by group order like overlapping domain patterns
(`10.0.0.0/8 → Office`, `10.1.2.0/24 → Direct`: Direct wins because its group comes first).
An IP rule matches connections opened to an address in its range and never a hostname
(`RulePattern.matches` is false for hosts), so it does not cover a site reached by name
whose address happens to fall into the range — see [03-routing.md](03-routing.md).

Validation issues: `coversTunnelServer` when a tunnel's server is an IP literal inside the
range; `coversLocalNetwork(interface:)` when the range overlaps one of the Mac's own IPv4
networks (passed in by the app from `getifaddrs`; Core stays free of network lookups).
Neither blocks the rule. `store.json` uses the same schema 2 as F10 (a build that does not
know `"match": "ip"` refuses the file); export files carry IP rules unchanged.

## Persistence

- `store.json` at `~/Library/Application Support/Wayfork/`. Pretty-printed JSON, written
  atomically (`Data.write(options: .atomic)`), debounced 300 ms after the last change.
- Loading: `schemaVersion` drives migrations (`Migration` list, applied in order). Unknown
  newer version → refuse to load, alert "store was written by a newer Wayfork". Corrupt
  file → renamed to `store.json.corrupt-<timestamp>`, start empty, alert.
- `slot` is assigned at creation (lowest free); it never changes, so the interface name
  stays stable across reconnects and app restarts.

## Keychain

All secrets are generic password items in the login keychain, service `com.wayfork`,
one item per secret so they can be rotated independently:

| Account                       | Value |
|-------------------------------|-------|
| `tunnel/<id>/ovpn`            | sanitized `.ovpn` body (contains inline key/certs) |
| `tunnel/<id>/credentials`     | JSON `{"username":…,"password":…}` |
| `tunnel/<id>/keyPassphrase`   | passphrase for an encrypted inline key |
| `tunnel/<id>/uuid`            | VLESS UUID |

Default ACL (accessible to the signed app only). Deleting a tunnel deletes its items;
on launch, orphan items whose tunnel no longer exists are removed. The daemon never touches
the Keychain; the app reads secrets when building the `RuntimePlan`.

Export files may contain secrets only when the user explicitly asks (see below).

## Import / export (F7)

File: `wayfork-export.json`

```json
{
  "format": "wayfork-export",
  "version": 1,
  "exportedAt": "2026-08-25T12:00:00Z",
  "includesSecrets": false,
  "tunnels": [
    { "id": "…", "name": "Work", "isEnabled": true, "kind": { "openVPN": { … } },
      "secrets": { "ovpn": null, "credentials": null, "keyPassphrase": null } },
    { "id": "…", "name": "Home", "kind": { "vless": { … } }, "secrets": { "uuid": null } }
  ],
  "rules": [ … ],
  "settings": { … }
}
```

- Export sheet: checkbox "Include secrets (keys, passwords, UUIDs)" — off by default, with a
  warning when on. Without secrets, imported OpenVPN tunnels need their config re-attached
  and VLESS tunnels their UUID before they can be enabled; the UI flags them.
- Import sheet shows a summary (N tunnels, M rules, secrets present or not) and two
  actions: **Replace all** or **Merge** (add new, update existing by `id`; rules referencing
  unknown tunnels are skipped with a warning). `settings` are imported only on Replace.
- `slot` values from the file are ignored; slots are re-assigned on import.
- `defaultTunnelID` and `target: "direct"` rules are exported and imported as described in
  "Default tunnel and exceptions".
- `examples/` ships `export.example.json`, `tunnel.example.ovpn` and `vless.example.txt`
  with placeholders only.
