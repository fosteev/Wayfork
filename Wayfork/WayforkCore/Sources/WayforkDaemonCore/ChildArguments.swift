import Foundation
import WayforkCore

/// argv for the OpenVPN child (docs/design/04-tunnels.md, "Runtime (daemon)").
public enum OpenVPNArguments {
    public static func arguments(
        for runtime: OpenVPNRuntime, runDirectory: String, logLevel: LogLevel
    ) -> [String] {
        let run = runDirectory as NSString
        return [
            "--config", run.appendingPathComponent(RunLayout.openVPNConfig(runtime.id)),
            "--dev", runtime.interface,
            "--dev-type", "tun",
            "--route-nopull",
            "--script-security", "1",
            "--management", run.appendingPathComponent(RunLayout.managementSocket(runtime.id)),
            "unix",
            "--management-hold",
            "--management-query-passwords",
            "--auth-nocache",
            "--auth-retry", "interact",
            "--persist-tun",
            "--persist-key",
            "--resolv-retry", "infinite",
            "--connect-retry", "2", "60",
            "--verb", String(logLevel.openVPNVerbosity),
            "--machine-readable-output",
            "--suppress-timestamps",
            "--dns-updown", "disable",
        ]
    }

    /// Key the reconcile diff compares: any change restarts the process.
    public static func diffKey(for runtime: OpenVPNRuntime, logLevel: LogLevel) -> String {
        "\(runtime.configHash)|\(runtime.interface)|verb=\(logLevel.openVPNVerbosity)"
    }
}

/// argv for the sing-box child (docs/design/03-routing.md).
public enum SingBoxArguments {
    public static func run(runDirectory: String) -> [String] {
        ["run", "-D", runDirectory, "-c", configPath(runDirectory)]
    }

    public static func check(runDirectory: String) -> [String] {
        ["check", "-D", runDirectory, "-c", configPath(runDirectory)]
    }

    public static let version = ["version"]

    private static func configPath(_ runDirectory: String) -> String {
        (runDirectory as NSString).appendingPathComponent(RunLayout.singBoxConfig)
    }
}
