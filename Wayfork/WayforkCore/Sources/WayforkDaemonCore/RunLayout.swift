import Foundation
import WayforkCore

/// File names inside `/Library/Application Support/Wayfork/run/`
/// (docs/design/05-daemon.md, "Files written by the daemon").
public enum RunLayout {
    public static let directory = "/Library/Application Support/Wayfork/run"
    public static let logDirectory = "/Library/Logs/Wayfork"

    public static let singBoxConfig = "sing-box.json"
    public static let singBoxPID = "sing-box.pid"
    /// Survives `stop`: fake-ip mappings must outlive restarts.
    public static let cacheFile = "cache.db"

    public static func openVPNConfig(_ id: String) -> String { "t-\(id).ovpn" }
    public static func managementSocket(_ id: String) -> String { "t-\(id).sock" }
    public static func openVPNPID(_ id: String) -> String { "t-\(id).pid" }
    public static func ruleSet(_ id: String) -> String { "rules-t-\(id).json" }
    /// Exceptions and built-in local names (F8); always part of the plan.
    public static let directRuleSet = "rules-direct.json"

    /// Everything except `cache.db` is wiped on stop and on daemon startup.
    public static func isTransient(_ fileName: String) -> Bool {
        fileName != cacheFile
    }

    public static func isPIDFile(_ fileName: String) -> Bool {
        fileName.hasSuffix(".pid")
    }

    public static func isRuleSet(_ fileName: String) -> Bool {
        fileName.hasPrefix("rules-t-") && fileName.hasSuffix(".json")
    }

    /// Raw child output log: `sing-box.log`, `openvpn-<id>.log`, `daemon.log`.
    public static func childLog(source: String) -> String {
        source.replacingOccurrences(of: ":", with: "-") + ".log"
    }
}
