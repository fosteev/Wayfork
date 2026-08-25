import Foundation

/// Produces `rules-t-<id>.json` and `rules-direct.json` contents
/// (docs/design/03-routing.md, "Rule-set files").
public enum RuleSetGenerator {
    public static let version = 3

    /// Tag and file of the Direct rule-set: user exceptions plus the built-in local names.
    public static let directTag = "rules-direct"
    public static let directFileName = "rules-direct.json"

    /// Built-in exceptions: names that must never leave the local network (F8).
    public static let builtInDirectSuffixes = [
        ".local", ".lan", ".internal", ".home.arpa", ".localhost",
    ]
    public static let builtInDirectDomains = ["localhost"]

    /// One rule-set file per tunnel plus the Direct file: file name → JSON text. Every
    /// tunnel in `tunnels` gets a file, even with no rules, and the Direct file is always
    /// present, so the main config stays unchanged when rules come and go.
    public static func generate(
        tunnels: [Tunnel], activeRules: [UUID: [Rule]], exceptions: [Rule] = []
    ) -> [String: String] {
        var files: [String: String] = [directFileName: renderDirect(exceptions: exceptions)]
        for tunnel in tunnels {
            files[tunnel.ruleSetFileName] = render(rules: activeRules[tunnel.id] ?? [])
        }
        return files
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
