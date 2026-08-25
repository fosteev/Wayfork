import Foundation
import WayforkCore

/// Requirement strings checked against XPC clients and bundled binaries
/// (docs/design/05-daemon.md, "Client verification" / "Binary validation").
public enum CodeSigningRequirement {
    public static let anchor = "anchor apple generic"

    /// The app connecting over XPC.
    public static func client(teamID: String) -> String {
        "\(anchor) and identifier \"\(WayforkIdentifiers.app)\" and \(teamClause(teamID))"
    }

    /// A bundled binary signed by `scripts/embed-bins.sh` as `com.wayfork.bin.<name>`.
    public static func binary(name: String, teamID: String) -> String {
        "\(anchor) and identifier \"com.wayfork.bin.\(name)\" and \(teamClause(teamID))"
    }

    /// Team IDs are 10 uppercase alphanumerics; anything else is treated as "unset".
    public static func isValidTeamID(_ teamID: String) -> Bool {
        teamID.count == 10 && teamID.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    private static func teamClause(_ teamID: String) -> String {
        "certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
