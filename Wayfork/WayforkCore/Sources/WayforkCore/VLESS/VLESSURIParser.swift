import Darwin
import Foundation

public struct VLESSImportResult: Sendable, Equatable {
    public var uuid: String
    public var meta: VLESSMeta
    public var name: String
}

public enum VLESSImportError: Error, Equatable, Sendable {
    case invalid(String)
    case unsupported(String)
}

public enum VLESSURIParser {
    public static func parse(_ uri: String) throws -> VLESSImportResult {
        let (withoutFragment, rawFragment) = splitOnce(uri[...], separator: "#")
        let (withoutQuery, rawQuery) = splitOnce(withoutFragment, separator: "?")

        guard let schemeEnd = withoutQuery.range(of: "://") else {
            throw VLESSImportError.invalid("scheme is missing")
        }
        let scheme = withoutQuery[..<schemeEnd.lowerBound]
        guard scheme.caseInsensitiveCompare("vless") == .orderedSame else {
            throw VLESSImportError.invalid("scheme must be vless")
        }

        let authority = withoutQuery[schemeEnd.upperBound...]
        guard let at = authority.firstIndex(of: "@") else {
            throw VLESSImportError.invalid("UUID is missing")
        }
        let rawUUID = String(authority[..<at])
        guard !rawUUID.isEmpty else {
            throw VLESSImportError.invalid("UUID is missing")
        }
        guard isCanonicalUUIDText(rawUUID), let uuid = UUID(uuidString: rawUUID) else {
            throw VLESSImportError.invalid("UUID is invalid")
        }

        let (host, port) = try parseEndpoint(authority[authority.index(after: at)...])
        let query = try parseQuery(rawQuery)

        if let encryption = query["encryption"], encryption != "none" {
            throw VLESSImportError.invalid("encryption must be none")
        }
        if let headerType = query["headerType"], headerType != "none" {
            throw VLESSImportError.unsupported(
                "headerType \"\(headerType)\" is not supported yet.")
        }

        let security: VLESSSecurity
        switch query["security"] {
        case nil, "none": security = .none
        case "tls": security = .tls
        case "reality": security = .reality
        default:
            throw VLESSImportError.invalid("security must be none, tls, or reality")
        }

        let transport: VLESSTransport
        switch query["type"] {
        case nil, "tcp": transport = .tcp
        case "ws": transport = .ws(path: query["path"] ?? "/", host: query["host"])
        case "grpc": transport = .grpc(serviceName: query["serviceName"] ?? "")
        case let type?:
            throw VLESSImportError.unsupported(
                "Transport \"\(type)\" is not supported yet.")
        }

        let flow: String?
        switch query["flow"] {
        case nil: flow = nil
        case "xtls-rprx-vision": flow = "xtls-rprx-vision"
        case let unsupported?:
            throw VLESSImportError.unsupported(
                "Flow \"\(unsupported)\" is not supported yet.")
        }
        if flow != nil && (security == .none || transport != .tcp) {
            throw VLESSImportError.invalid("flow requires TLS/REALITY over TCP")
        }

        if security == .reality {
            guard let publicKey = query["pbk"], !publicKey.isEmpty else {
                throw VLESSImportError.invalid("REALITY requires pbk")
            }
            if transport != .tcp {
                throw VLESSImportError.unsupported("REALITY over ws/grpc is not supported")
            }
        }

        let sni = security == .none ? nil : query["sni"] ?? host
        let alpn =
            query["alpn"]?.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let allowInsecure = isTrue(query["allowInsecure"]) || isTrue(query["insecure"])

        let decodedFragment = try decode(rawFragment ?? "", component: "fragment")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullName = decodedFragment.isEmpty ? host : decodedFragment
        let name = String(fullName.prefix(Tunnel.nameMaxLength))

        return VLESSImportResult(
            uuid: uuid.uuidString.lowercased(),
            meta: VLESSMeta(
                server: host,
                port: port,
                flow: flow,
                security: security,
                sni: sni,
                fingerprint: query["fp"],
                alpn: alpn,
                realityPublicKey: query["pbk"],
                realityShortID: query["sid"].flatMap { $0.isEmpty ? nil : $0 },
                transport: transport,
                allowInsecure: allowInsecure),
            name: name)
    }

    /// Rebuilds a VLESS sharing link. `uuid` may be a placeholder for display purposes.
    public static func uri(meta: VLESSMeta, uuid: String, name: String) -> String {
        var query: [(String, String)] = [("encryption", "none")]
        append(meta.flow, as: "flow", to: &query)
        query.append(("security", meta.security.rawValue))
        append(meta.sni, as: "sni", to: &query)
        append(meta.fingerprint, as: "fp", to: &query)
        if !meta.alpn.isEmpty {
            query.append(("alpn", meta.alpn.joined(separator: ",")))
        }
        append(meta.realityPublicKey, as: "pbk", to: &query)
        append(meta.realityShortID, as: "sid", to: &query)

        switch meta.transport {
        case .tcp:
            query.append(("type", "tcp"))
        case .ws(let path, let host):
            query.append(("type", "ws"))
            query.append(("path", path))
            append(host, as: "host", to: &query)
        case .grpc(let serviceName):
            query.append(("type", "grpc"))
            query.append(("serviceName", serviceName))
        }
        if meta.allowInsecure {
            query.append(("allowInsecure", "1"))
        }

        let host = isIPv6(meta.server) ? "[\(meta.server)]" : meta.server
        let encodedQuery = query.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
        return "vless://\(uuid)@\(host):\(meta.port)?\(encodedQuery)#\(percentEncode(name))"
    }

    private static func splitOnce(
        _ value: Substring, separator: Character
    ) -> (Substring, Substring?) {
        guard let index = value.firstIndex(of: separator) else { return (value, nil) }
        return (value[..<index], value[value.index(after: index)...])
    }

    private static func parseEndpoint(_ endpoint: Substring) throws -> (String, Int) {
        let rawHost: Substring
        let rawPort: Substring

        if endpoint.first == "[" {
            guard let closingBracket = endpoint.firstIndex(of: "]") else {
                throw VLESSImportError.invalid("IPv6 host is missing a closing bracket")
            }
            rawHost = endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket]
            let afterBracket = endpoint[endpoint.index(after: closingBracket)...]
            guard afterBracket.first == ":" else {
                throw VLESSImportError.invalid("port is missing")
            }
            rawPort = afterBracket.dropFirst()
            guard isIPv6(String(rawHost)) else {
                throw VLESSImportError.invalid("host is invalid")
            }
        } else {
            guard let colon = endpoint.lastIndex(of: ":") else {
                throw VLESSImportError.invalid("port is missing")
            }
            rawHost = endpoint[..<colon]
            rawPort = endpoint[endpoint.index(after: colon)...]
            guard !rawHost.contains(":") else {
                throw VLESSImportError.invalid("IPv6 host must be enclosed in brackets")
            }
        }

        let host = String(rawHost)
        guard !host.isEmpty else {
            throw VLESSImportError.invalid("host is missing")
        }
        guard isValidHost(host) else {
            throw VLESSImportError.invalid("host is invalid")
        }
        guard !rawPort.isEmpty else {
            throw VLESSImportError.invalid("port is missing")
        }
        guard rawPort.allSatisfy(\.isNumber), let port = Int(rawPort),
            (1...65_535).contains(port)
        else {
            throw VLESSImportError.invalid("port must be between 1 and 65535")
        }
        return (host, port)
    }

    private static func parseQuery(_ rawQuery: Substring?) throws -> [String: String] {
        guard let rawQuery else { return [:] }
        var result: [String: String] = [:]
        for item in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let pair = splitOnce(item, separator: "=")
            result[String(pair.0)] = try decode(pair.1 ?? "", component: "query value")
        }
        return result
    }

    private static func decode(_ value: Substring, component: String) throws -> String {
        guard let decoded = String(value).removingPercentEncoding else {
            throw VLESSImportError.invalid("\(component) has invalid percent encoding")
        }
        return decoded
    }

    private static func isTrue(_ value: String?) -> Bool {
        value == "1" || value == "true"
    }

    private static func append(
        _ value: String?, as key: String, to query: inout [(String, String)]
    ) {
        if let value {
            query.append((key, value))
        }
    }

    private static func percentEncode(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var result = ""
        for byte in value.utf8 {
            if byte.isASCIIUnreserved {
                result.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                result.append("%")
                result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte >> 4)]))
                result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte & 0x0F)]))
            }
        }
        return result
    }

    private static func isValidHost(_ host: String) -> Bool {
        if isIPv6(host) || isIPv4(host) { return true }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        if host.count > 253 { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty
            && labels.allSatisfy { label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy {
                        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                            || $0 == 45
                    }
            }
    }

    private static func isIPv4(_ host: String) -> Bool {
        var address = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    private static func isCanonicalUUIDText(_ value: String) -> Bool {
        guard value.utf8.count == 36 else { return false }
        for (offset, byte) in value.utf8.enumerated() {
            if [8, 13, 18, 23].contains(offset) {
                if byte != 45 { return false }
            } else if !((48...57).contains(byte) || (65...70).contains(byte)
                || (97...102).contains(byte))
            {
                return false
            }
        }
        return true
    }

    private static func isIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
}

extension UInt8 {
    fileprivate var isASCIIUnreserved: Bool {
        (65...90).contains(self) || (97...122).contains(self) || (48...57).contains(self)
            || self == 45 || self == 46 || self == 95 || self == 126
    }
}
