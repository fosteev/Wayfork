import Foundation

/// What the build knows about its bundled block list (F18): the `block-ads.json` sidecar
/// `scripts/fetch-blocklist.sh` writes next to `block-ads.srs`, and whether the compiled
/// list is there at all.
public struct BlockListInfo: Sendable, Hashable {
    public var isAvailable: Bool
    public var name: String?
    public var entries: Int?
    /// The list's own version stamp (`202609151706` for OISD), when the sidecar has one.
    public var version: String?

    public init(isAvailable: Bool, name: String? = nil, entries: Int? = nil, version: String? = nil)
    {
        self.isAvailable = isAvailable
        self.name = name
        self.entries = entries
        self.version = version
    }

    public static let missing = BlockListInfo(isAvailable: false)

    private struct Sidecar: Decodable {
        var name: String?
        var entries: Int?
        var version: String?
    }

    /// Reads the bundle at `bundlePath`; `.missing` when the `.srs` is not there.
    public static func load(bundlePath: String) -> BlockListInfo {
        let listPath = RuntimePlanBuilder.blockListPath(bundlePath: bundlePath)
        guard FileManager.default.fileExists(atPath: listPath) else { return .missing }
        let sidecarPath = (listPath as NSString).deletingPathExtension + ".json"
        guard let data = FileManager.default.contents(atPath: sidecarPath),
            let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data)
        else { return BlockListInfo(isAvailable: true) }
        return BlockListInfo(
            isAvailable: true, name: sidecar.name, entries: sidecar.entries,
            version: sidecar.version)
    }
}

/// Strings of the *Blocking* section (docs/design/02-ux.md, "Variant C" › General).
public enum BlockListText {
    /// `Blocked 12 today · list of 56,069 sites · from Wayfork 0.7.0`; the counter part
    /// reads `Blocked — (counting needs log detail Normal)` while it is unavailable.
    public static func hint(
        info: BlockListInfo, isEnabled: Bool, blockedToday: Int?, isRunning: Bool,
        countingPossible: Bool, appVersion: String
    ) -> String {
        guard info.isAvailable else {
            return "The block list is missing from this build — reinstall Wayfork"
        }
        var parts: [String] = []
        if isEnabled, isRunning {
            if !countingPossible {
                parts.append("Blocked — (counting needs log detail Normal)")
            } else {
                parts.append("Blocked \(blockedToday ?? 0) today")
            }
        }
        if let entries = info.entries {
            parts.append("list of \(grouped(entries)) sites")
        }
        parts.append("from Wayfork \(appVersion)")
        return parts.joined(separator: " · ")
    }

    /// `56,069` — English grouping regardless of the locale, like every other string here.
    static func grouped(_ number: Int) -> String {
        let digits = Array(String(number))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }

    public static let exceptionsHint = "Sites the list gets wrong — they load as usual"

    /// Validates a *Never block* entry like a suffix rule pattern.
    public static func normalizeException(_ input: String) -> Result<String, RulePatternError> {
        do {
            return .success(try RulePattern.normalize(input, match: .suffix))
        } catch let error as RulePatternError {
            return .failure(error)
        } catch {
            return .failure(.empty)
        }
    }
}
