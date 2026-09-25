import Foundation
import WayforkCore

/// Removes one local proxy inbound and its route rule from a config whose port another
/// program holds, so the engine can start without it (F17, docs/design/05-daemon.md,
/// "Local proxy ports"). Pure: the same rendering as `ClashAPIConfig.inject`.
public enum LocalProxyStripper {
    /// nil when the config has no inbound with that tag.
    public static func strip(inboundTag tag: String, from config: String) -> String? {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: Data(config.utf8)),
            var root = parsed as? [String: Any],
            var inbounds = root["inbounds"] as? [[String: Any]],
            inbounds.contains(where: { $0["tag"] as? String == tag })
        else { return nil }
        inbounds.removeAll { $0["tag"] as? String == tag }
        root["inbounds"] = inbounds
        if var route = root["route"] as? [String: Any],
            var rules = route["rules"] as? [[String: Any]]
        {
            rules.removeAll { ($0["inbound"] as? [String]) == [tag] }
            route["rules"] = rules
            root["route"] = route
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
