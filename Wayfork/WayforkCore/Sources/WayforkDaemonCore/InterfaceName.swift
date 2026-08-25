import Foundation
import WayforkCore

/// Validation of `utun` interface names before they reach `route` or a child's argv
/// (docs/design/05-daemon.md, "Route helper").
public enum InterfaceName {
    /// Units OpenVPN tunnels may use: `utun101`…`utun132` (sing-box owns `utun100`).
    public static let openVPNUnits =
        Tunnel.firstOpenVPNInterfaceUnit..<(Tunnel.firstOpenVPNInterfaceUnit + Tunnel.maxSlots)

    /// `utun1NN` → `1NN`; nil for anything that does not match `^utun(1[0-9]{2})$`.
    public static func unit(of name: String) -> Int? {
        guard name.count == 7, name.hasPrefix("utun1") else { return nil }
        let digits = name.dropFirst(4)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let unit = Int(digits) else {
            return nil
        }
        return unit
    }

    /// Accepted by the route helper: any `utun100`…`utun199`.
    public static func isRoutable(_ name: String) -> Bool {
        unit(of: name) != nil
    }

    /// Accepted for an OpenVPN process: within `openVPNUnits`.
    public static func isOpenVPNInterface(_ name: String) -> Bool {
        guard let unit = unit(of: name) else { return false }
        return openVPNUnits.contains(unit)
    }
}
