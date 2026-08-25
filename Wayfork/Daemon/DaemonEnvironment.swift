import Foundation
import WayforkCore
import WayforkDaemonCore

/// Where the daemon lives and what it may execute. Every path is derived from the daemon's
/// own executable location; nothing comes from the client
/// (docs/design/00-architecture.md, "Trust boundaries").
struct DaemonEnvironment: Sendable {
    let executablePath: String
    /// `…/Wayfork.app` — three levels above `Contents/MacOS/WayforkDaemon`.
    let bundlePath: String
    /// `WayforkTeamID` from the embedded Info.plist; nil when unset (ad-hoc build).
    let teamID: String?
    let version: String
    let runDirectory: String
    let logDirectory: String

    var binDirectory: String { bundlePath + "/Contents/Resources/bin" }
    var singBoxPath: String { binDirectory + "/sing-box" }
    var openVPNPath: String { binDirectory + "/openvpn" }

    static func current() -> DaemonEnvironment {
        let executable =
            (Bundle.main.executableURL?.resolvingSymlinksInPath().path)
            ?? CommandLine.arguments[0]
        let bundle = (executable as NSString).deletingLastPathComponent  // MacOS
        let contents = (bundle as NSString).deletingLastPathComponent  // Contents
        let app = (contents as NSString).deletingLastPathComponent  // Wayfork.app
        let info = Bundle.main.infoDictionary ?? [:]
        let rawTeam = (info["WayforkTeamID"] as? String) ?? ""
        return DaemonEnvironment(
            executablePath: executable,
            bundlePath: app,
            teamID: CodeSigningRequirement.isValidTeamID(rawTeam) ? rawTeam : nil,
            version: (info["CFBundleShortVersionString"] as? String) ?? WayforkCore.version,
            runDirectory: RunLayout.directory,
            logDirectory: RunLayout.logDirectory)
    }

    func runPath(_ fileName: String) -> String {
        (runDirectory as NSString).appendingPathComponent(fileName)
    }

    /// Creates `run/` and the log directory as root-only directories.
    func prepareDirectories() throws {
        for directory in [runDirectory, logDirectory] {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory)
        }
    }
}
