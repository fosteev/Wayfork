import Foundation
import WayforkCore

/// Limits enforced on a `RuntimePlan` before anything is written or spawned
/// (docs/design/00-architecture.md, "Trust boundaries", rule 4).
public enum PlanValidator {
    /// `blockListPath`: the daemon's own `Contents/Resources/rulesets/block-ads.srs` (F18);
    /// a binary rule-set anywhere else is refused (trust rule 3), a missing file too.
    public static func validate(_ plan: RuntimePlan, blockListPath: String? = nil)
        throws(DaemonError)
    {
        guard plan.version == RuntimePlan.currentVersion else {
            throw .planInvalid(
                reason:
                    "unsupported plan version \(plan.version) (expected \(RuntimePlan.currentVersion))"
            )
        }
        try checkSize(plan.singBox.config, name: RunLayout.singBoxConfig, allowEmpty: false)
        for (name, contents) in plan.singBox.ruleSets {
            guard
                name == RunLayout.directRuleSet || name == RunLayout.directIPRuleSet
                    || ruleSetID(fromFileName: name).map(isTunnelID) == true
            else {
                throw .planInvalid(
                    reason:
                        "rule-set file name \"\(name)\" is not rules-t-<id>.json, rules-t-<id>-ip.json, their rules-g- twins, \(RunLayout.directRuleSet) or \(RunLayout.directIPRuleSet)"
                )
            }
            try checkSize(contents, name: name, allowEmpty: false)
        }
        for path in plan.singBox.binaryRuleSetPaths {
            guard path == blockListPath else {
                throw .planInvalid(
                    reason: "rule-set path \"\(path)\" is not the bundled block list")
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw .planInvalid(reason: "block list missing at \(path) — reinstall Wayfork")
            }
        }
        // F17: loopback only, sane ports, one per tunnel or group, tags of our shape.
        var proxyPorts = Set<Int>()
        var proxyExits = Set<String>()
        for inbound in plan.singBox.localProxyInbounds {
            guard inbound.listen == LocalProxy.listenAddress else {
                throw .planInvalid(
                    reason: "inbound \(inbound.tag) listens on \(inbound.listen), not loopback")
            }
            guard LocalProxy.portRange.contains(inbound.port) else {
                throw .planInvalid(
                    reason: "inbound \(inbound.tag) port \(inbound.port) is out of range")
            }
            guard proxyPorts.insert(inbound.port).inserted else {
                throw .planInvalid(reason: "port \(inbound.port) is used by two inbounds")
            }
            guard let exitID = inbound.exitID, isTunnelID(exitID) else {
                throw .planInvalid(
                    reason: "inbound tag \"\(inbound.tag)\" is not proxy-t-<id> or proxy-g-<id>")
            }
            guard proxyExits.insert(exitID).inserted else {
                throw .planInvalid(reason: "tunnel or group \(exitID) has two local proxy ports")
            }
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

    /// `rules-t-<id>.json`, `rules-t-<id>-ip.json` and their `rules-g-` twins (F16) → `<id>`.
    public static func ruleSetID(fromFileName name: String) -> String? {
        guard let prefix = ["rules-t-", "rules-g-"].first(where: name.hasPrefix),
            name.hasSuffix(".json")
        else { return nil }
        var id = name.dropFirst(prefix.count).dropLast(".json".count)
        if id.hasSuffix("-ip") { id = id.dropLast(3) }
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
