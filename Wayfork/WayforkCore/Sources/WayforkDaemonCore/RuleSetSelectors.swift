import Foundation
import WayforkCore

/// The matchers of a rule-set file in sing-box's source format, flattened, and the
/// connections they cover (docs/design/05-daemon.md, "Connection cut on rule change").
public struct RuleSetSelectors: Sendable, Equatable {
    public var domain: Set<String>
    public var domainSuffix: Set<String>
    public var domainRegex: Set<String>
    public var processPathRegex: Set<String>
    public var ipCIDR: Set<String>

    public init(
        domain: Set<String> = [], domainSuffix: Set<String> = [], domainRegex: Set<String> = [],
        processPathRegex: Set<String> = [], ipCIDR: Set<String> = []
    ) {
        self.domain = domain
        self.domainSuffix = domainSuffix
        self.domainRegex = domainRegex
        self.processPathRegex = processPathRegex
        self.ipCIDR = ipCIDR
    }

    public var isEmpty: Bool {
        domain.isEmpty && domainSuffix.isEmpty && domainRegex.isEmpty && processPathRegex.isEmpty
            && ipCIDR.isEmpty
    }

    /// The matchers of one file; nil when it is not `{"rules": [{<matcher>: [..]}]}` with
    /// the matchers the generator emits (then nobody can tell what the file covers).
    public static func parse(_ text: String) -> RuleSetSelectors? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any],
            let rules = object["rules"] as? [[String: Any]]
        else { return nil }
        var selectors = RuleSetSelectors()
        for rule in rules {
            for (key, value) in rule {
                let items: [String]
                switch value {
                case let list as [String]: items = list
                case let single as String: items = [single]
                default: return nil
                }
                switch key {
                case "domain": selectors.domain.formUnion(items.map { $0.lowercased() })
                case "domain_suffix": selectors.domainSuffix.formUnion(items.map { $0.lowercased() })
                case "domain_regex": selectors.domainRegex.formUnion(items)
                case "process_path_regex": selectors.processPathRegex.formUnion(items)
                case "ip_cidr": selectors.ipCIDR.formUnion(items)
                default: return nil
                }
            }
        }
        return selectors
    }

    /// Matchers present in exactly one of the two.
    public func symmetricDifference(_ other: RuleSetSelectors) -> RuleSetSelectors {
        RuleSetSelectors(
            domain: domain.symmetricDifference(other.domain),
            domainSuffix: domainSuffix.symmetricDifference(other.domainSuffix),
            domainRegex: domainRegex.symmetricDifference(other.domainRegex),
            processPathRegex: processPathRegex.symmetricDifference(other.processPathRegex),
            ipCIDR: ipCIDR.symmetricDifference(other.ipCIDR))
    }

    public mutating func formUnion(_ other: RuleSetSelectors) {
        domain.formUnion(other.domain)
        domainSuffix.formUnion(other.domainSuffix)
        domainRegex.formUnion(other.domainRegex)
        processPathRegex.formUnion(other.processPathRegex)
        ipCIDR.formUnion(other.ipCIDR)
    }

    /// What changed in `files` between two versions of the rule-set files (name → contents).
    /// nil when a file cannot be parsed: the caller then treats every connection as affected.
    public static func change(
        from previous: [String: String], to current: [String: String], files: [String]
    ) -> RuleSetSelectors? {
        var change = RuleSetSelectors()
        for file in files {
            guard let before = selectors(of: previous[file]), let after = selectors(of: current[file])
            else { return nil }
            change.formUnion(before.symmetricDifference(after))
        }
        return change
    }

    private static func selectors(of text: String?) -> RuleSetSelectors? {
        guard let text else { return RuleSetSelectors() }
        return parse(text)
    }

    /// Whether a connection with these Clash API metadata fields is covered by a matcher.
    /// A superset of sing-box's matching on purpose (`domain_suffix` also matches the bare
    /// name); empty fields never match.
    public func matches(host: String, destinationIP: String, processPath: String) -> Bool {
        let host = host.lowercased()
        if !host.isEmpty {
            if domain.contains(host) { return true }
            if domainSuffix.contains(where: {
                host == $0 || host.hasSuffix($0) || host.hasSuffix("." + $0)
            }) {
                return true
            }
            if domainRegex.contains(where: { Self.matches(regex: $0, host) }) { return true }
        }
        if !processPath.isEmpty,
            processPathRegex.contains(where: { Self.matches(regex: $0, processPath) })
        {
            return true
        }
        if let address = IPv4Prefix(destinationIP), address.isHost,
            ipCIDR.contains(where: { IPv4Prefix($0)?.contains(address) == true })
        {
            return true
        }
        return false
    }

    private static func matches(regex pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
