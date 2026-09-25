import Foundation

/// Strings of the *Local proxy* row (F17, docs/design/02-ux.md, "Variant C" › Settings ›
/// Tunnels) and the port validation the app applies before a store change.
public enum LocalProxyText {
    /// Hint while the switch is off.
    public static func offHint(exitName: String) -> String {
        "Turn on to get a 127.0.0.1 address that sends an app through \(exitName) without a rule — for curl, a browser profile, Telegram."
    }

    /// Hint next to the address while the switch is on.
    public static func onHint(exitName: String) -> String {
        "for curl, a browser profile, Telegram — uses \(exitName), no rule needed"
    }

    /// `proxy.portInUse`: the engine started without this inbound.
    public static func portTaken(_ port: Int) -> String {
        "Port \(port) is taken by another program — pick another"
    }

    /// Inline validation of a typed port: nil when it can be stored.
    public static func portProblem(_ text: String, store: Store, excluding id: UUID) -> String? {
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)),
            LocalProxy.portRange.contains(port)
        else { return "Ports 1024–65535" }
        if let owner = store.localProxyPortOwner(port, excluding: id) {
            return "Port already used by \(owner)"
        }
        return nil
    }
}
