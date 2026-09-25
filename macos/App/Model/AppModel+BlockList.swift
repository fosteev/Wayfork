import Foundation
import WayforkCore

// Block ads and trackers (F18, docs/design/02-ux.md, "Variant C" › General › Blocking):
// the switch, the *Never block* exceptions and the daemon's counter.

extension AppModel {
    /// What this build ships (`Contents/Resources/rulesets/block-ads.srs` + sidecar).
    var blockList: BlockListInfo {
        BlockListInfo.load(bundlePath: bundlePath)
    }

    /// The daemon's count since local midnight; nil while it cannot count.
    var blockedToday: Int? { traffic?.blockedToday }

    /// The counter needs sing-box's `info` lines.
    var blockCountingPossible: Bool {
        settings.logLevel == .info || settings.logLevel == .debug
    }

    var blockListHint: String {
        BlockListText.hint(
            info: blockList, isEnabled: settings.blockList.isEnabled, blockedToday: blockedToday,
            isRunning: globalState.isRunning, countingPossible: blockCountingPossible,
            appVersion: appVersion)
    }

    func setBlockList(enabled: Bool) {
        updateSettings { $0.blockList.isEnabled = enabled }
        logs.app(.info, "block list \(enabled ? "on" : "off")")
    }

    /// Adds a *Never block* site. Returns an error message, or nil when it went through.
    @discardableResult
    func addBlockException(_ input: String) -> String? {
        switch BlockListText.normalizeException(input) {
        case .failure(let error):
            return RuleEditing.message(for: error)
        case .success(let host):
            guard !settings.blockList.exceptions.contains(host) else {
                return "\(host) is already on the list"
            }
            updateSettings { $0.blockList.exceptions.append(host) }
            return nil
        }
    }

    func removeBlockException(_ host: String) {
        updateSettings { $0.blockList.exceptions.removeAll { $0 == host } }
    }
}
