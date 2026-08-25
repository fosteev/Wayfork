import Foundation

/// Reason codes carried in `TunnelState.failed(reason:permanent:)`; the app maps them to
/// the messages in docs/design/02-ux.md ("Error catalogue").
public enum OpenVPNFailure: String, Sendable, CaseIterable {
    /// Server rejected username/password (`>PASSWORD:Verification Failed: 'Auth'`).
    case authFailed = "ovpn.authFailed"
    /// Config asks for credentials but the plan has none.
    case needsCredentials = "ovpn.needsCredentials"
    /// Private key decryption failed.
    case keyPassphrase = "ovpn.keyPassphrase"
    /// Key is encrypted but the plan has no passphrase.
    case needsKeyPassphrase = "ovpn.needsKeyPassphrase"
    /// OpenVPN rejected the config (options error, unreadable certificate, …).
    case configError = "ovpn.configError"
    /// The server asks for something the daemon cannot provide (proxy credentials, …).
    case unsupportedPrompt = "ovpn.unsupportedPrompt"
    /// Process exited and `autoReconnect` is off.
    case exited = "ovpn.exited"

    public var isPermanent: Bool {
        self != .exited
    }

    /// Classifies a `>FATAL:` message; nil means transient (network, TLS handshake, …).
    public static func permanentReason(forFatal message: String) -> OpenVPNFailure? {
        let lower = message.lowercased()
        if lower.contains("private key password verification failed")
            || lower.contains("bad decrypt")
        {
            return .keyPassphrase
        }
        if lower.hasPrefix("options error") || lower.contains("cannot load certificate")
            || lower.contains("cannot load private key") || lower.contains("cannot load ca")
            || lower.contains("cannot load inline certificate")
            || lower.contains("failed to parse") || lower.contains("cannot read")
            || lower.contains("unrecognized option") || lower.contains("--config file")
        {
            return .configError
        }
        return nil
    }
}
