/// Shared, UI-free core of Wayfork: models, parsers, config generation and XPC payloads.
/// Used by both the app and the daemon; must never touch the UI or require privileges.
public enum WayforkCore {
    /// Core module version. Kept in sync with the app's `MARKETING_VERSION`.
    public static let version = "0.1.0"
}

/// Identifiers shared by the app, the daemon and the launchd plist.
public enum WayforkIdentifiers {
    /// Bundle identifier of `Wayfork.app`.
    public static let app = "com.wayfork.app"
    /// Bundle identifier (and launchd label) of `WayforkDaemon`.
    public static let daemon = "com.wayfork.daemon"
    /// Mach service the daemon listens on; the app connects to it over XPC.
    public static let machService = "com.wayfork.daemon.xpc"
    /// Keychain service name for every secret stored by the app.
    public static let keychainService = "com.wayfork"
}
