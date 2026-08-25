import Foundation
import ServiceManagement
import WayforkCore

/// Registration of the privileged daemon and of the app's login item through
/// `SMAppService` (docs/design/05-daemon.md, "Registration").
@MainActor
final class HelperInstaller {
    static let plistName = "com.wayfork.daemon.plist"

    enum State: Sendable, Hashable {
        case notInstalled
        case requiresApproval
        case enabled
        /// The plist is not inside the running bundle (moved app, ad-hoc build).
        case notFound
    }

    private let daemon = SMAppService.daemon(plistName: HelperInstaller.plistName)

    var state: State {
        switch daemon.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notInstalled
        @unknown default: .notInstalled
        }
    }

    /// Registers the daemon. `SMAppService` throws when the item still needs approval even
    /// though the registration itself succeeded, so callers must look at `state` afterwards.
    func register() throws {
        do {
            try daemon.register()
        } catch {
            if state == .requiresApproval || state == .enabled { return }
            throw error
        }
    }

    func unregister() async throws {
        try await daemon.unregister()
    }

    /// `unregister()` then `register()`; used after an app update or move. launchd tears the
    /// old job down asynchronously and `register()` fails with "Operation not permitted"
    /// while it is still there (seen 2026-08-25), so the registration is retried for a few
    /// seconds.
    func reinstall() async throws {
        try? await unregister()
        var attempt = 0
        while true {
            do {
                try register()
                return
            } catch {
                attempt += 1
                guard attempt < 12 else { throw error }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Polls `state` until it is `.enabled`, the task is cancelled or `timeout` elapses.
    func waitUntilEnabled(pollEvery: Duration = .seconds(1), timeout: Duration = .seconds(900))
        async -> Bool
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if state == .enabled { return true }
            do {
                try await Task.sleep(for: pollEvery)
            } catch {
                return false
            }
        }
        return state == .enabled
    }

    // MARK: - Launch at login

    static var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
