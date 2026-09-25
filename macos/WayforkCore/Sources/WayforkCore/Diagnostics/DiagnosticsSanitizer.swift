import Darwin
import Foundation

public struct SanitizerOptions: Sendable, Equatable {
    public var includeServerAddresses: Bool

    public init(includeServerAddresses: Bool = false) {
        self.includeServerAddresses = includeServerAddresses
    }
}

public enum DiagnosticsSanitizer {
    /// Sanitizes a JSON document used by diagnostics export.
    public static func sanitizeJSON(
        _ data: Data, options: SanitizerOptions = SanitizerOptions()
    ) throws -> Data {
        let document = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let orderedServers =
            options.includeServerAddresses ? [] : JSONAddressCollector.collect(data)
        var sanitizer = JSONTreeSanitizer(options: options, orderedServers: orderedServers)
        let sanitized = sanitizer.sanitize(document)
        return try JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    public static func sanitizeJSON(
        _ text: String, options: SanitizerOptions = SanitizerOptions()
    ) throws -> String {
        let data = try sanitizeJSON(Data(text.utf8), options: options)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct JSONTreeSanitizer {
    fileprivate static let secretKeys: Set<String> = [
        "uuid",
        "password",
        "keypassphrase",
        "key_passphrase",
        "realitypublickey",
        "realityshortid",
        "public_key",
        "short_id",
        "private_key",
        "psk",
        "ovpn",
        "credentials",
        "secrets",
    ]

    fileprivate static let serverKeys: Set<String> = [
        "server", "host", "server_name", "sni", "hostname", "Host",
    ]

    let options: SanitizerOptions
    private var serverPlaceholders: [String: String] = [:]

    init(options: SanitizerOptions, orderedServers: [String]) {
        self.options = options
        for server in orderedServers where serverPlaceholders[server] == nil {
            serverPlaceholders[server] = "server-\(serverPlaceholders.count + 1)"
        }
    }

    mutating func sanitize(_ value: Any, key: String? = nil) -> Any {
        if let key, Self.secretKeys.contains(key.lowercased()) {
            return "<redacted>"
        }

        if let object = value as? [String: Any] {
            var sanitized: [String: Any] = [:]
            for (childKey, childValue) in object {
                sanitized[childKey] = sanitize(childValue, key: childKey)
            }
            return sanitized
        }
        if let array = value as? [Any] {
            return array.map { sanitize($0) }
        }
        guard let string = value as? String else { return value }

        if string.contains("-----BEGIN") {
            return "<redacted>"
        }
        if !options.includeServerAddresses, let key, Self.serverKeys.contains(key),
            !Self.isPrivateOrLoopbackIP(string)
        {
            if let existing = serverPlaceholders[string] {
                return existing
            }
            let placeholder = "server-\(serverPlaceholders.count + 1)"
            serverPlaceholders[string] = placeholder
            return placeholder
        }
        return Self.abbreviateUserPath(string)
    }

    private static func abbreviateUserPath(_ value: String) -> String {
        let prefix = "/Users/"
        guard value.hasPrefix(prefix) else { return value }
        let usernameStart = value.index(value.startIndex, offsetBy: prefix.count)
        guard let slash = value[usernameStart...].firstIndex(of: "/"), slash > usernameStart else {
            return value
        }
        return "~/" + value[value.index(after: slash)...]
    }

    fileprivate static func isPrivateOrLoopbackIP(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            return address & 0xFF00_0000 == 0x0A00_0000
                || address & 0xFFF0_0000 == 0xAC10_0000
                || address & 0xFFFF_0000 == 0xC0A8_0000
                || address & 0xFF00_0000 == 0x7F00_0000
                || address & 0xFFC0_0000 == 0x6440_0000
        }

        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let isUniqueLocal = bytes[0] & 0xFE == 0xFC
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            return isUniqueLocal || isLoopback
        }
        return false
    }
}

/// Reads address values in source order before `JSONSerialization` discards object ordering.
private struct JSONAddressCollector {
    private let bytes: [UInt8]
    private var index = 0
    private var servers: [String] = []

    static func collect(_ data: Data) -> [String] {
        var collector = JSONAddressCollector(bytes: Array(data))
        collector.parseValue(collectAddresses: true)
        return collector.servers
    }

    mutating func parseValue(collectAddresses: Bool) {
        skipWhitespace()
        guard index < bytes.count else { return }
        switch bytes[index] {
        case 123: parseObject(collectAddresses: collectAddresses)  // {
        case 91: parseArray(collectAddresses: collectAddresses)  // [
        case 34: _ = readString()  // "
        default: skipScalar()
        }
    }

    mutating func parseObject(collectAddresses: Bool) {
        index += 1
        skipWhitespace()
        while index < bytes.count, bytes[index] != 125 {  // }
            guard let key = readString() else { return }
            skipWhitespace()
            guard consume(58) else { return }  // :
            skipWhitespace()

            let collectChild =
                collectAddresses && !JSONTreeSanitizer.secretKeys.contains(key.lowercased())
            if collectChild, JSONTreeSanitizer.serverKeys.contains(key), bytes[index] == 34 {
                let valueStart = index
                if let value = readString(), !value.contains("-----BEGIN"),
                    !JSONTreeSanitizer.isPrivateOrLoopbackIP(value)
                {
                    servers.append(value)
                }
                index = valueStart
            }
            parseValue(collectAddresses: collectChild)
            skipWhitespace()
            if !consume(44) { break }  // ,
            skipWhitespace()
        }
        _ = consume(125)
    }

    mutating func parseArray(collectAddresses: Bool) {
        index += 1
        skipWhitespace()
        while index < bytes.count, bytes[index] != 93 {  // ]
            parseValue(collectAddresses: collectAddresses)
            skipWhitespace()
            if !consume(44) { break }  // ,
            skipWhitespace()
        }
        _ = consume(93)
    }

    mutating func readString() -> String? {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 34 else { return nil }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 92 {  // \\
                escaped = true
            } else if byte == 34 {
                let token = Data(bytes[start..<index])
                return try? JSONSerialization.jsonObject(
                    with: token, options: [.fragmentsAllowed]) as? String
            }
        }
        return nil
    }

    mutating func skipScalar() {
        while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
