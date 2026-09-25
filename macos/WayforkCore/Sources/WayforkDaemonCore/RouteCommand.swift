import Foundation

/// `/sbin/route` invocations for interface-scoped default routes
/// (docs/design/04-tunnels.md, "Interface-scoped default route").
public enum RouteCommand: Sendable {
    public static let executable = "/sbin/route"

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidInterface(String)
    }

    /// `route -n add -inet default -ifscope utunN -interface utunN`
    public static func addScopedDefault(interface: String) throws(Error) -> [String] {
        try validate(interface)
        return ["-n", "add", "-inet", "default", "-ifscope", interface, "-interface", interface]
    }

    /// `route -n delete -inet default -ifscope utunN`
    public static func deleteScopedDefault(interface: String) throws(Error) -> [String] {
        try validate(interface)
        return ["-n", "delete", "-inet", "default", "-ifscope", interface]
    }

    /// `route -n get default` — diagnostics.
    public static let getDefault = ["-n", "get", "default"]

    /// `route -n get -inet <address>` — startup verification asks which interface a public
    /// address leaves through (sing-box's `auto_route` installs split ranges, not a plain
    /// default route, so `get default` would still name the physical interface).
    public static func get(address: String) -> [String] {
        ["-n", "get", "-inet", address]
    }

    /// The `interface:` field of `route -n get default` output, if any.
    public static func interface(fromGetOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("interface:") else { continue }
            let value = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func validate(_ interface: String) throws(Error) {
        guard InterfaceName.isRoutable(interface) else {
            throw .invalidInterface(interface)
        }
    }
}
