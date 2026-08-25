import Foundation

/// An IPv4 address or CIDR prefix: the parsed form of an IP rule pattern (F11) and the
/// arithmetic behind the auto-route exclusion list (`SingBoxConfigGenerator`).
public struct IPv4Prefix: Hashable, Sendable, CustomStringConvertible {
    public let address: UInt32
    public let bits: Int

    /// Host bits are cleared: `10.8.0.5/24` becomes `10.8.0.0/24`.
    public init(address: UInt32, bits: Int) {
        self.bits = bits
        self.address = address & Self.mask(bits)
    }

    /// Parses `a.b.c.d` (a /32) or `a.b.c.d/n`; host bits are cleared. Dotted-quad IPv4
    /// only — no IPv6, no shorthand like `10/8`.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var bits = 32
        if parts.count == 2 {
            guard parts[1].allSatisfy(\.isNumber), let n = Int(parts[1]), (0...32).contains(n)
            else { return nil }
            bits = n
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

    /// A single address.
    public var isHost: Bool { bits == 32 }

    public func contains(_ other: IPv4Prefix) -> Bool {
        other.bits >= bits && (other.address & Self.mask(bits)) == address
    }

    /// Prefixes either nest or are disjoint, so overlapping means one contains the other.
    public func overlaps(_ other: IPv4Prefix) -> Bool {
        contains(other) || other.contains(self)
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

    /// `self` minus every prefix in `inners`, sorted by address.
    public func subtracting(all inners: [IPv4Prefix]) -> [IPv4Prefix] {
        var result = [self]
        for inner in inners {
            result = result.flatMap { $0.subtracting(inner) }
        }
        return result.sorted { $0.address < $1.address }
    }

    /// `a.b.c.d/n`, always with the prefix length.
    public var description: String { "\(dotted)/\(bits)" }

    /// The stored pattern form of an IP rule: a bare address for a /32, `a.b.c.d/n` otherwise.
    public var canonical: String { isHost ? dotted : description }

    private var dotted: String {
        "\(address >> 24).\((address >> 16) & 0xff).\((address >> 8) & 0xff).\(address & 0xff)"
    }
}
