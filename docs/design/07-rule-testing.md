# Rule testing — "Where does `<domain>` go?" (L2)

Status: design only (2026-08-25), not scheduled; nothing in the code yet. Covers the first
bullet of L2 in [ROADMAP.md](../ROADMAP.md). The second bullet (live connection view) is
sketched under "Out of scope".

## Goal

Answer, inside the app and without asking the daemon, *which exit takes this and why*:
the rule that wins, the rules that were considered and skipped, and the caveats that make
the real-world answer differ (browser DoH, connecting by IP instead of by name, a tunnel
that is down). The answer must be the one sing-box would give, so the resolver walks the
rules in exactly the order the generator emits them
([03-routing.md](03-routing.md), "Rule-set files", "Default tunnel and exceptions").

## Query

One free-text field. The text is classified like a rule pattern (`RulePattern.inferMatch`):

| Input | Facet | Notes |
|---|---|---|
| `example.com`, `https://a.example.com/x` | `host` | URL reduced to its host; lowercased, punycode, trailing dot stripped |
| `203.0.113.7` | `address` | IPv4 literal |
| `/Applications/Telegram.app`, `file://…` | `app` | bundle path, as in F10 rules |
| `example.com from /Applications/Telegram.app` | `host` + `app` | optional second facet, ` from ` separator |

```swift
public struct RouteQuery: Sendable, Hashable {
    public var host: String?        // normalized hostname
    public var address: IPv4Prefix? // /32
    public var app: String?         // bundle path
}
```

At least one facet is required. A query with `host` never carries `address`: a connection
opened by name gets a fake IP, so IP rules cannot see it — that is the single most useful
thing the tester explains, and the resolver models it by *skipping* IP rules for host
queries (with a trace line saying so) rather than by refusing the combination.

## Resolution

```swift
public enum RuleResolver {
    public static func resolve(
        _ query: RouteQuery, store: Store, missingSecrets: Set<UUID> = [],
        status: RuntimeStatus? = nil
    ) -> Resolution
}

public struct Resolution: Sendable, Hashable {
    public enum Exit: Hashable { case tunnel(UUID), direct, notRouted }
    public enum Reason: Hashable {
        case rule(UUID, group: RuleTarget)      // the winning rule and its group
        case builtInLocal                        // `.local`, `.lan`, `.internal`, `.home.arpa`, `localhost`
        case excludedFromTUN(IPv4Prefix)         // private / reserved range, never enters Wayfork
        case defaultTunnel(UUID)
        case unmatched                           // no rule, no default → direct
    }
    public struct Step: Hashable {               // one line of the trace, in evaluation order
        public var group: RuleTarget
        public var rule: UUID?
        public var outcome: Outcome              // matched, noMatch, skipped(RuleIssue), ipRuleIgnoredForHost, groupInactive(why)
    }
    public enum Caveat: Hashable {
        case dohBypass                           // host queries: a browser with its own DoH is seen by IP only
        case wouldMatchByAddress(UUID)           // host queries: an IP rule would catch this if a client connects by address
        case appSeenAsProxy                      // app queries
        case tunnelDown(UUID)                    // from `status`: the exit's tunnel is not connected → connection fails
        case defaultTunnelDown(UUID)             // from `status`: unmatched traffic is blocked right now
        case defaultTunnelIneffective(DefaultTunnelIssue)
    }
    public var exit: Exit
    public var reason: Reason
    public var trace: [Step]
    public var caveats: [Caveat]
}
```

Evaluation order — the same as the emitted `route.rules`:

1. **Reserved addresses** (`address` facet): loopback, link-local, multicast, the TUN
   subnet and the fake-ip range → `notRouted`, reason `excludedFromTUN`. Same set that
   `RulePattern.normalize` rejects for IP rules.
2. **Private ranges** (`address` facet): `route_exclude_address` minus the active tunnel IP
   rules carved out of it (`SingBoxConfigGenerator.routeExcludeAddresses(carving:)`). An
   address still inside an exclusion never reaches sing-box → `direct`, reason
   `excludedFromTUN(prefix)`. This is decided by the route table, which is why it comes
   before every rule.
3. **Built-in local names** (`host` facet) → `direct`, `builtInLocal`.
4. **Direct group** — active exceptions (`RuleValidator.activeExceptions`), in list order:
   domain rules against `host`, app rules against `app`, IP rules against `address`
   (ignored with `ipRuleIgnoredForHost` when the query has a host).
5. **Tunnel groups in store order** (`RuleValidator.activeRules`, `store.tunnels` order):
   same matching per rule. Skipped rules are still listed in the trace with the issue that
   removed them from the config (`duplicate`, `shadowed`, `tunnelDisabled`, disabled rule);
   an inactive group (tunnel disabled or without its secret) is one `groupInactive` line.
6. **Default tunnel** — `StatusText.effectiveDefaultTunnel(store, missingSecrets:)` →
   `tunnel`, `defaultTunnel`; a set-but-ineffective default adds
   `defaultTunnelIneffective`. Otherwise `direct`, `unmatched`.

Matching reuses the production code paths: `RulePattern.matches(host:pattern:match:)` for
domains, `IPv4Prefix.contains` for IP rules, prefix comparison on the normalized bundle
path (`RulePattern.appPathRegex` semantics: the app path plus `/`) for app rules. Nothing
in the resolver duplicates pattern logic; if it did, the tester could lie.

Caveats are computed after the exit is known: `dohBypass` for every host query that ends
in a tunnel or an exception; `wouldMatchByAddress` when a host query is decided by a domain
rule (or unmatched) and some active IP rule is *plausibly* relevant — the resolver cannot
resolve names, so this fires only when the user also typed an address (`host` + `address`
is accepted for this purpose alone and evaluated as two separate queries whose exits
differ); `appSeenAsProxy` for app queries; `tunnelDown` / `defaultTunnelDown` when
`status` says the exit's OpenVPN tunnel is not connected.

## UX

Settings › Rules gets one line under the page title, above the groups:

```
Rules                                        [🔍 Search rules     ]
Where does [ example.com                          ] go?   [Test]
→ Work · rule example.com (Suffix) in Work · 1 caveat ▾
```

- The field accepts the same input as the rule editor; ⏎ or **Test** resolves. Invalid
  input shows the editor's error copy under the field (red outline, one line).
- Result line: exit in bold (`Work`, `Direct`, `Not routed`), then the reason:
  - `rule <pattern> (<Match>) in <group>` — clicking the pattern scrolls to the rule and
    flashes its row (the same highlight used when a tunnel card opens Settings).
  - `exception <pattern> (<Match>)` for the Direct group.
  - `built-in local name`, `private range — never enters Wayfork`, `reserved address`,
    `everything else → <tunnel> (default)`, `no rule matches — goes direct`.
- `N caveats ▾` opens a disclosure with one line per caveat:
  - "A browser with its own secure DNS (DoH) never asks Wayfork — it is seen by IP only."
  - "A client that connects by address instead of name would hit `10.8.0.0/24 → Office`."
  - "Only what the app sends itself: through a local proxy it is seen as the proxy."
  - "Work is not connected right now — this connection fails until it reconnects."
  - "Work (default) is down — unmatched traffic is blocked right now."
  - "The default tunnel is disabled / has no config — everything else goes direct."
- `Trace ▾` (second disclosure, collapsed by default): the `Step` list as a small
  monospaced table — `group · rule · outcome` — so a "why not Home?" question has an
  answer on screen.
- The popover stays as it is. Quick add already answers the narrow version of the question
  ("Update" instead of "Add" when the pattern exists); no new UI there.
- Prototype: add a board to `docs/design/prototype/variant-b.html` (Rules page with the
  tester line and both disclosures open) before implementation, per the usual gate.

## Tests

Pure logic, swift-testing in `WayforkCoreTests/RuleResolverTests.swift`:

- exception beats a tunnel rule for the same host; store order decides between tunnels;
  exact under a later tunnel loses to a suffix under an earlier one (and the trace shows the
  loser as `noMatch`, not `skipped`); a shadowed duplicate is `skipped(.shadowed)`;
- a disabled tunnel's group is `groupInactive`; a tunnel without its secret likewise;
- default tunnel set / disabled / missing secret → `defaultTunnel` vs `unmatched` +
  `defaultTunnelIneffective`;
- IP query inside `192.168.0.0/16` → `excludedFromTUN`; the same with a tunnel IP rule
  carving `192.168.50.0/24` → that tunnel; a Direct IP rule under a default tunnel;
- host query with an IP rule in an earlier group → the IP rule is `ipRuleIgnoredForHost`
  and the domain rule wins; app query vs a domain rule in an earlier group → the app rule
  wins only for hosts that no earlier domain rule covers (the resolver says so via the
  combined `host from app` query);
- built-in local names, URL and `file://` inputs, invalid input.

Cross-check against the generator: for every golden variant in
`Tests/WayforkCoreTests/Golden/`, a tiny interpreter of the emitted `route.rules` +
rule-set files resolves a fixed list of hosts / addresses / app paths and must agree with
`RuleResolver`. This is what keeps the tester honest when the generator changes.

## Out of scope

- **Live connection view** (second L2 bullet): the daemon already fetches
  `/connections` for F9 but forwards aggregates only; showing hosts per connection in the
  app is a privacy decision (destination hosts leave the daemon) and a separate design.
- Resolving through the running engine ("ask sing-box"): not needed — the static answer is
  the contract, and the caveats cover where reality diverges.
- IPv6 queries: with IPv6 support (Later).
