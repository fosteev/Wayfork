import Foundation
import WayforkCore

/// Reads and writes `GuideState` (F22) in `UserDefaults` (docs/design/01-data-model.md,
/// "Persistence"): this Mac's UI progress, not configuration, so it never travels with an
/// export and needs no schema migration. A missing or undecodable value reads as the empty
/// state, which never shows the guide to someone who already has a setup.
struct GuideStore {
    static let defaultsKey = "WayforkGuideState"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> GuideState {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return GuideState() }
        return (try? JSONDecoder().decode(GuideState.self, from: data)) ?? GuideState()
    }

    func save(_ state: GuideState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
