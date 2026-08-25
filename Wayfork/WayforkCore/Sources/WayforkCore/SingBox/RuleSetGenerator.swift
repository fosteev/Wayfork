import Foundation

/// Produces `rules-t-<id>.json` and `rules-direct.json` contents, plus the route-only
/// `…-ip.json` twins holding the IP rules (docs/design/03-routing.md, "Rule-set files").
public enum RuleSetGenerator {
    public static let version = 3

    /// Tag and file of the Direct rule-set: user exceptions plus the built-in local names.
    public static let directTag = "rules-direct"
    public static let directFileName = "rules-direct.json"
    /// Tag and file of the Direct IP rule-set (F11).
    public static let directIPTag = "rules-direct-ip"
    public static let directIPFileName = "rules-direct-ip.json"

    /// Built-in exceptions: names that must never leave the local network (F8).
    public static let builtInDirectSuffixes = [
        ".local", ".lan", ".internal", ".home.arpa", ".localhost",
    ]
    public static let builtInDirectDomains = ["localhost"]

    /// Two rule-set files per tunnel (domains + apps, IPs) plus the two Direct files: file
    /// name → JSON text. Every tunnel in `tunnels` gets its files, even with no rules, and
    /// the Direct files are always present, so the main config stays unchanged when rules
    /// come and go.
    public static func generate(
        tunnels: [Tunnel], activeRules: [UUID: [Rule]], exceptions: [Rule] = []
    ) -> [String: String] {
        var files: [String: String] = [
            directFileName: renderDirect(exceptions: exceptions),
            directIPFileName: renderIP(rules: exceptions),
        ]
        for tunnel in tunnels {
            let rules = activeRules[tunnel.id] ?? []
            files[tunnel.ruleSetFileName] = render(rules: rules)
            files[tunnel.ipRuleSetFileName] = renderIP(rules: rules)
        }
        return files
    }

    /// `…-ip.json` (F11): the group's IP rules as one `ip_cidr` rule, each range minus the
    /// reserved ranges a wide pattern may overlap. Never referenced by DNS rules — there
    /// sing-box would match `ip_cidr` against the answer and skip the domain rules.
    public static func renderIP(rules: [Rule]) -> String {
        let ranges = rules.filter(\.isIP)
            .compactMap { IPv4Prefix($0.pattern) }
            .flatMap { $0.subtracting(all: RulePattern.reservedRanges) }
            .map(\.description)
        let document: [String: Any] = [
            "version": version,
            "rules": ranges.isEmpty ? [] : [["ip_cidr": ranges]],
        ]
        return JSONText.render(document)
    }

    /// Rule-set JSON for one tunnel's rules: one rule object for the domain items and, when
    /// there are app rules (F10), a second one with `process_path_regex` — sing-box ANDs
    /// items of different kinds inside one rule and ORs the rules of a set.
    public static func render(rules: [Rule]) -> String {
        render(rules: rules, domains: [], suffixes: [])
    }

    /// `rules-direct.json`: the built-in local names first, then the user's exceptions.
    public static func renderDirect(exceptions: [Rule]) -> String {
        render(rules: exceptions, domains: builtInDirectDomains, suffixes: builtInDirectSuffixes)
    }

    private static func render(rules: [Rule], domains: [String], suffixes: [String]) -> String {
        var domain = domains
        var domainSuffix = suffixes
        var domainRegex: [String] = []
        var processPathRegex: [String] = []
        for rule in rules {
            switch rule.match {
            case .exact:
                domain.append(rule.pattern)
            case .suffix:
                domain.append(rule.pattern)
                domainSuffix.append("." + rule.pattern)
            case .wildcard:
                domainRegex.append(RulePattern.wildcardRegex(rule.pattern))
            case .app:
                processPathRegex.append(RulePattern.appPathRegex(rule.pattern))
            case .ip:
                continue  // `renderIP`
            }
        }
        var domainRule: [String: Any] = [:]
        if !domain.isEmpty { domainRule["domain"] = domain }
        if !domainSuffix.isEmpty { domainRule["domain_suffix"] = domainSuffix }
        if !domainRegex.isEmpty { domainRule["domain_regex"] = domainRegex }
        var ruleObjects: [[String: Any]] = []
        if !domainRule.isEmpty { ruleObjects.append(domainRule) }
        if !processPathRegex.isEmpty {
            ruleObjects.append(["process_path_regex": processPathRegex])
        }
        let document: [String: Any] = [
            "version": version,
            "rules": ruleObjects,
        ]
        return JSONText.render(document)
    }
}

/// Deterministic JSON rendering for generated files: sorted keys, two-space indent.
enum JSONText {
    static func render(_ object: [String: Any]) -> String {
        // JSONSerialization cannot fail for the plain String/Int/Bool/Array/Dictionary
        // trees the generators build; a failure here would be a programming error.
        let data =
            (try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
