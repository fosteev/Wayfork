import AppKit
import Foundation
import WayforkCore

/// Recent domains → rule (F15, docs/design/02-ux.md, "Variant C" › Popover / Rules): the
/// daemon lists what took the default route; the app keeps a 5-minute window, hides what
/// the user dismissed for the session and what a rule already covers, and turns a row
/// into a suffix rule for the registrable domain in one click.
extension AppModel {
    /// How far back the popover and the Rules strip look.
    static let recentWindow: TimeInterval = 300

    /// Rows worth showing right now, newest first: within the window, not hidden, not
    /// already covered by an active domain rule (the daemon cannot tell a rule that points
    /// at the default tunnel from no rule at all).
    var recentHosts: [RecentHost] {
        guard globalState.isRunning, let traffic else { return [] }
        return RecentFilter.visible(
            traffic.recentHosts, sampledAt: traffic.sampledAt, window: Self.recentWindow,
            hidden: hiddenRecentHosts, store: store)
    }

    /// Where the listed flows went: the default tunnel's or group's name, or "direct".
    var recentExitName: String? {
        StatusText.effectiveDefaultExitName(store, missingSecrets: missingSecrets)
    }

    /// Targets a row can be routed to: every tunnel and group except the default one, then
    /// Direct.
    var recentTargets: [RuleTarget] {
        let defaultID = recentExitName == nil ? nil : store.defaultTunnelID
        return store.tunnels.filter { $0.isEnabled && $0.id != defaultID }.map { .tunnel($0.id) }
            + store.groups.filter { $0.isEnabled && $0.id != defaultID }.map { .group($0.id) }
            + [.direct]
    }

    /// The pattern *Route via* creates for a row.
    func recentRulePattern(_ host: String) -> String {
        RulePattern.registrableDomain(of: host)
    }

    /// Creates the suffix rule and drops the row (and its siblings under the same domain).
    @discardableResult
    func routeRecent(_ host: String, via target: RuleTarget) -> String? {
        let pattern = recentRulePattern(host)
        if let message = addRule(pattern: pattern, match: .suffix, target: target) {
            return message
        }
        hideRecent(host)
        return nil
    }

    /// Hides a row until the next Turn On.
    func hideRecent(_ host: String) {
        hiddenRecentHosts.insert(host)
    }

    /// Name and icon of the process behind a row: the enclosing app bundle when there is
    /// one, the executable's name otherwise.
    static func recentProcess(_ path: String?) -> (name: String, icon: NSImage) {
        guard let path, !path.isEmpty else {
            return ("", NSWorkspace.shared.icon(for: .unixExecutable))
        }
        let components = path.split(separator: "/").map(String.init)
        if let bundle = components.lastIndex(where: { $0.hasSuffix(".app") }) {
            let bundlePath = "/" + components[...bundle].joined(separator: "/")
            let info = AppBundleInfo.info(for: bundlePath)
            return (info.name, info.icon)
        }
        return (components.last ?? path, NSWorkspace.shared.icon(for: .unixExecutable))
    }
}
