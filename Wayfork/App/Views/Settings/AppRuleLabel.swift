import AppKit
import SwiftUI
import WayforkCore

/// Icon, display name and existence of an application bundle for app rules (F10). Cached
/// per path; a bundle that is gone falls back to the generic app icon and the path's last
/// component, and is looked up again once it is back.
@MainActor
enum AppBundleInfo {
    struct Info {
        var name: String
        var icon: NSImage
        var exists: Bool
    }

    private static var cache: [String: Info] = [:]

    static func info(for path: String) -> Info {
        let exists = FileManager.default.fileExists(atPath: path)
        if let cached = cache[path], cached.exists == exists { return cached }
        var name = exists ? FileManager.default.displayName(atPath: path) : RulePattern.appName(path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let icon =
            exists
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .applicationBundle)
        let info = Info(name: name, icon: icon, exists: exists)
        cache[path] = info
        return info
    }
}

/// App icon + display name in a rule row; the bundle path is the tooltip.
struct AppRuleLabel: View {
    let path: String

    var body: some View {
        let info = AppBundleInfo.info(for: path)
        HStack(spacing: 6) {
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(info.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(info.exists ? 1 : 0.6)
        .help(path)
    }
}
