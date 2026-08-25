import Foundation

/// A minimal IPv4 CIDR prefix — just enough for the auto-route exclusion math in
/// `SingBoxConfigGenerator.routeExcludeAddresses()`.
public struct IPv4Prefix: Equatable, Sendable, CustomStringConvertible {
    public let address: UInt32
    public let bits: Int

    public init(address: UInt32, bits: Int) {
        self.bits = bits
        self.address = address & Self.mask(bits)
    }

    /// Parses `a.b.c.d/n`; host bits are cleared.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits) else {
            return nil
        }
        var raw = in_addr()
        guard String(parts[0]).withCString({ inet_pton(AF_INET, $0, &raw) }) == 1 else {
            return nil
        }
        self.init(address: UInt32(bigEndian: raw.s_addr), bits: bits)
    }

    static func mask(_ bits: Int) -> UInt32 {
        bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
    }

    public func contains(_ other: IPv4Prefix) -> Bool {
        other.bits >= bits && (other.address & Self.mask(bits)) == address
    }

    /// `self` minus `inner`, as prefixes: the sibling of every step down from `self` to
    /// `inner`, sorted by address. Returns `[self]` when `inner` lies outside, `[]` when
    /// `inner` covers `self`.
    public func subtracting(_ inner: IPv4Prefix) -> [IPv4Prefix] {
        guard contains(inner) else { return [self] }
        guard inner.bits > bits else { return [] }
        return ((bits + 1)...inner.bits)
            .map { depth in
                IPv4Prefix(address: inner.address ^ (UInt32(1) << UInt32(32 - depth)), bits: depth)
            }
            .sorted { $0.address < $1.address }
    }

    public var description: String {
        "\(address >> 24).\((address >> 16) & 0xff).\((address >> 8) & 0xff).\(address & 0xff)/\(bits)"
    }
}
