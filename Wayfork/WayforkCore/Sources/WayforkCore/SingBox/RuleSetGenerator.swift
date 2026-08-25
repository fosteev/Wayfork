import Foundation

/// Produces `rules-t-<id>.json` contents (docs/design/03-routing.md, "Rule-set files").
public enum RuleSetGenerator {
    public static let version = 3

    /// One rule-set file per tunnel: `Tunnel.ruleSetFileName` → JSON text. Every tunnel in
    /// `tunnels` gets a file, even with no rules, so the main config stays unchanged when
    /// rules come and go.
    public static func generate(tunnels: [Tunnel], activeRules: [UUID: [Rule]]) -> [String: String]
    {
        var files: [String: String] = [:]
        for tunnel in tunnels {
            files[tunnel.ruleSetFileName] = render(rules: activeRules[tunnel.id] ?? [])
        }
        return files
    }

    /// Rule-set JSON for one tunnel's rules, grouped into a single rule object.
    public static func render(rules: [Rule]) -> String {
        var domain: [String] = []
        var domainSuffix: [String] = []
        var domainRegex: [String] = []
        for rule in rules {
            switch rule.match {
            case .exact:
                domain.append(rule.pattern)
            case .suffix:
                domain.append(rule.pattern)
                domainSuffix.append("." + rule.pattern)
            case .wildcard:
                domainRegex.append(RulePattern.wildcardRegex(rule.pattern))
            }
        }
        var rule: [String: Any] = [:]
        if !domain.isEmpty { rule["domain"] = domain }
        if !domainSuffix.isEmpty { rule["domain_suffix"] = domainSuffix }
        if !domainRegex.isEmpty { rule["domain_regex"] = domainRegex }
        let document: [String: Any] = [
            "version": version,
            "rules": rule.isEmpty ? [] : [rule],
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
