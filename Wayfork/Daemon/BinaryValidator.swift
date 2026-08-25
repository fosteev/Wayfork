import Foundation
import Security
import WayforkCore
import WayforkDaemonCore

/// Signature check of a bundled binary before every spawn
/// (docs/design/05-daemon.md, "Binary validation").
enum BinaryValidator {
    static func validate(path: String, name: String, teamID: String?) throws(DaemonError) {
        guard let teamID else {
            throw .binaryUntrusted(path: path)
        }
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
            let staticCode
        else {
            throw .binaryUntrusted(path: path)
        }
        var requirement: SecRequirement?
        let text = CodeSigningRequirement.binary(name: name, teamID: teamID) as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess,
            let requirement
        else {
            throw .binaryUntrusted(path: path)
        }
        let status = SecStaticCodeCheckValidity(staticCode, [], requirement)
        guard status == errSecSuccess else {
            throw .binaryUntrusted(path: path)
        }
    }
}
