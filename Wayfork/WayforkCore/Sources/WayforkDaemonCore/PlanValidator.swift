import Foundation
import WayforkCore

/// Limits enforced on a `RuntimePlan` before anything is written or spawned
/// (docs/design/00-architecture.md, "Trust boundaries", rule 4).
public enum PlanValidator {
    public static func validate(_ plan: RuntimePlan) throws(DaemonError) {
        guard plan.version == RuntimePlan.currentVersion else {
            throw .planInvalid(
                reason:
                    "unsupported plan version \(plan.version) (expected \(RuntimePlan.currentVersion))"
            )
        }
        try checkSize(plan.singBox.config, name: RunLayout.singBoxConfig, allowEmpty: false)
        for (name, contents) in plan.singBox.ruleSets {
            guard
                name == RunLayout.directRuleSet
                    || ruleSetID(fromFileName: name).map(isTunnelID) == true
            else {
                throw .planInvalid(
                    reason:
                        "rule-set file name \"\(name)\" is not rules-t-<id>.json or \(RunLayout.directRuleSet)"
                )
            }
            try checkSize(contents, name: name, allowEmpty: false)
        }
        guard plan.openVPN.count <= RuntimePlan.maxTunnels else {
            throw .planInvalid(
                reason:
                    "\(plan.openVPN.count) OpenVPN tunnels exceed the limit of \(RuntimePlan.maxTunnels)"
            )
        }
        var ids = Set<String>()
        var interfaces = Set<String>()
        for runtime in plan.openVPN {
            guard isTunnelID(runtime.id) else {
                throw .planInvalid(reason: "tunnel id \"\(runtime.id)\" is not a lowercase UUID")
            }
            guard ids.insert(runtime.id).inserted else {
                throw .planInvalid(reason: "duplicate tunnel id \(runtime.id)")
            }
            guard InterfaceName.isOpenVPNInterface(runtime.interface) else {
                throw .planInvalid(
                    reason:
                        "interface \"\(runtime.interface)\" of tunnel \(runtime.id) is outside utun\(InterfaceName.openVPNUnits.lowerBound)…utun\(InterfaceName.openVPNUnits.upperBound - 1)"
                )
            }
            guard interfaces.insert(runtime.interface).inserted else {
                throw .planInvalid(reason: "interface \(runtime.interface) is used twice")
            }
            try checkSize(
                runtime.config, name: RunLayout.openVPNConfig(runtime.id), allowEmpty: false)
            if let credentials = runtime.credentials {
                try checkSize(
                    credentials.username, name: "username of \(runtime.id)", allowEmpty: true)
                try checkSize(
                    credentials.password, name: "password of \(runtime.id)", allowEmpty: true)
            }
            if let passphrase = runtime.keyPassphrase {
                try checkSize(passphrase, name: "key passphrase of \(runtime.id)", allowEmpty: true)
            }
        }
    }

    /// `rules-t-<id>.json` → `<id>`.
    public static func ruleSetID(fromFileName name: String) -> String? {
        guard name.hasPrefix("rules-t-"), name.hasSuffix(".json") else { return nil }
        let id = name.dropFirst("rules-t-".count).dropLast(".json".count)
        return id.isEmpty ? nil : String(id)
    }

    /// Lowercase hyphenated UUID: the only shape that ever becomes part of a file name.
    public static func isTunnelID(_ id: String) -> Bool {
        guard id.count == 36, let parsed = UUID(uuidString: id) else { return false }
        return parsed.uuidString.lowercased() == id
    }

    private static func checkSize(_ text: String, name: String, allowEmpty: Bool)
        throws(DaemonError)
    {
        let bytes = text.utf8.count
        guard bytes <= RuntimePlan.maxConfigBytes else {
            throw .planInvalid(
                reason: "\(name) is \(bytes) bytes, limit \(RuntimePlan.maxConfigBytes)")
        }
        guard allowEmpty || bytes > 0 else {
            throw .planInvalid(reason: "\(name) is empty")
        }
        guard !text.utf8.contains(0) else {
            throw .planInvalid(reason: "\(name) contains a NUL byte")
        }
    }
}
