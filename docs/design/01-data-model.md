# Data model and storage

Covers F1 (tunnels), F2 (rules), F6 (settings), F7 (import/export) at the data level.

## Entities

```swift
struct Store: Codable {
    var schemaVersion = 1
    var tunnels: [Tunnel]
    var rules: [Rule]                 // ordered within a tunnel; see "Rule order" below
    var settings: Settings
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
    var match: RuleMatch              // suffix | exact | wildcard
    var tunnelID: UUID
    var isEnabled: Bool
    var note: String?
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

`*` stands for one or more characters including dots and must be the only special
character. `suffix` is the default; typing `*` switches the row to `wildcard`.

### Rule order

Rules are edited grouped by tunnel. Effective order = tunnels in store order, and within
a tunnel the rules in list order. A pattern that also appears under an earlier tunnel is
**shadowed** (never matches) and flagged in the UI; the generator drops it.

Validation: pattern is a hostname (labels of `[a-z0-9-]`, IDNA converted to punycode) with
`*` allowed only for wildcard; no scheme, path or port (the UI strips `https://…/` when
pasting a URL). Duplicates (same pattern + match) are rejected. A rule pointing at a
disabled or missing tunnel is shown greyed and does not match anything (traffic goes
direct; kill switch is L7).

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
- `examples/` ships `export.example.json`, `tunnel.example.ovpn` and `vless.example.txt`
  with placeholders only.
