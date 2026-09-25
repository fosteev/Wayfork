import Foundation
import Security

/// Read-only code-signature facts shared by the app and the daemon.
public enum CodeSignature {
    /// The CDHash of the executable at `path`, hex-encoded; nil when the file is missing or
    /// unsigned. Two builds of the same version differ here, which is how the app notices
    /// that the daemon launchd is running is not the one inside its bundle
    /// (docs/design/05-daemon.md, "Registration").
    public static func uniqueIdentifier(ofExecutableAt path: String) -> String? {
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
                == errSecSuccess, let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
