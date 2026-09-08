import CoreFoundation
import Darwin
import Foundation

public struct ShadowsocksImportResult: Sendable, Equatable {
    public var password: String
    public var meta: ShadowsocksMeta
    public var name: String

    public init(password: String, meta: ShadowsocksMeta, name: String) {
        self.password = password
        self.meta = meta
        self.name = name
    }
}

public struct TrojanImportResult: Sendable, Equatable {
    public var password: String
    public var meta: TrojanMeta
    public var name: String

    public init(password: String, meta: TrojanMeta, name: String) {
        self.password = password
        self.meta = meta
        self.name = name
    }
}

public struct VMessImportResult: Sendable, Equatable {
    public var uuid: String
    public var meta: VMessMeta
    public var name: String

    public init(uuid: String, meta: VMessMeta, name: String) {
        self.uuid = uuid
        self.meta = meta
        self.name = name
    }
}

/// The parsed values the import sheet needs to build a tunnel and store its secret.
public enum ProxyLink: Sendable, Equatable {
    case vless(VLESSImportResult)
    case shadowsocks(ShadowsocksImportResult)
    case trojan(TrojanImportResult)
    case vmess(VMessImportResult)
}

public enum ProxyLinkError: Error, Equatable, Sendable {
    case invalid(String)
    case unsupported(String)
}

public enum ProxyLinkParser {
    private static let shadowsocksMethods: Set<String> = [
        "aes-128-gcm",
        "aes-256-gcm",
        "chacha20-ietf-poly1305",
        "xchacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm",
        "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-poly1305",
        "none",
    ]

    /// Dispatches on the scheme; VLESS parsing remains owned by `VLESSURIParser`.
    public static func parse(_ text: String) throws -> ProxyLink {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = text.range(of: "://") else {
            throw ProxyLinkError.invalid("unsupported link scheme")
        }
        switch text[..<schemeEnd.lowerBound].lowercased() {
        case "vless":
            do {
                return .vless(try VLESSURIParser.parse(text))
            } catch VLESSImportError.invalid(let message) {
                throw ProxyLinkError.invalid(message)
            } catch VLESSImportError.unsupported(let message) {
                throw ProxyLinkError.unsupported(message)
            }
        case "ss":
            return .shadowsocks(try parseShadowsocks(text, schemeEnd: schemeEnd))
        case "trojan":
            return .trojan(try parseTrojan(text, schemeEnd: schemeEnd))
        case "vmess":
            return .vmess(try parseVMess(text, schemeEnd: schemeEnd))
        default:
            throw ProxyLinkError.invalid("unsupported link scheme")
        }
    }

    /// Rebuilds a SIP002 Shadowsocks sharing link.
    public static func uri(meta: ShadowsocksMeta, password: String, name: String) -> String {
        let credentials = Data("\(meta.method):\(password)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "ss://\(credentials)@\(encodedHost(meta.server)):\(meta.port)#\(percentEncode(name))"
    }

    /// Rebuilds a Trojan sharing link. `password` may be a placeholder for display.
    public static func uri(meta: TrojanMeta, password: String, name: String) -> String {
        var query: [(String, String)] = []
        if meta.security == .reality { query.append(("security", "reality")) }
        if let sni = meta.sni, sni != meta.server { query.append(("sni", sni)) }
        append(meta.fingerprint, as: "fp", to: &query)
        if !meta.alpn.isEmpty { query.append(("alpn", meta.alpn.joined(separator: ","))) }
        append(meta.realityPublicKey, as: "pbk", to: &query)
        append(meta.realityShortID, as: "sid", to: &query)
        appendTransport(meta.transport, to: &query)
        if meta.allowInsecure { query.append(("allowInsecure", "1")) }

        let suffix = query.isEmpty ? "" : "?" + encodedQuery(query)
        return
            "trojan://\(percentEncode(password))@\(encodedHost(meta.server)):\(meta.port)\(suffix)#\(percentEncode(name))"
    }

    /// Rebuilds a V2RayN VMess sharing link. `uuid` may be a placeholder for display.
    public static func uri(meta: VMessMeta, uuid: String, name: String) -> String {
        let transport: (net: String, host: String, path: String)
        switch meta.transport {
        case .tcp:
            transport = ("tcp", "", "")
        case .ws(let path, let host):
            transport = ("ws", host ?? "", path)
        case .grpc(let serviceName):
            transport = ("grpc", "", serviceName)
        }
        var json: [String: String] = [
            "add": meta.server,
            "aid": "0",
            "alpn": meta.alpn.joined(separator: ","),
            "fp": meta.fingerprint ?? "",
            "host": transport.host,
            "id": uuid,
            "net": transport.net,
            "path": transport.path,
            "port": String(meta.port),
            "ps": name,
            "scy": meta.security,
            "sni": meta.sni ?? "",
            "tls": meta.tlsSecurity == .none ? "" : meta.tlsSecurity.rawValue,
            "type": "none",
            "v": "2",
        ]
        if meta.tlsSecurity == .reality {
            json["pbk"] = meta.realityPublicKey ?? ""
            json["sid"] = meta.realityShortID ?? ""
        }
        if meta.allowInsecure { json["allowInsecure"] = "1" }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return "vmess://\(data.base64EncodedString())"
    }

    private static func parseShadowsocks(
        _ text: String, schemeEnd: Range<String.Index>
    ) throws -> ShadowsocksImportResult {
        let (withoutFragment, rawFragment) = splitOnce(text[...], separator: "#")
        let (withoutQuery, rawQuery) = splitOnce(withoutFragment, separator: "?")
        let query = try parseQuery(rawQuery)
        if query.keys.contains("plugin") {
            throw ProxyLinkError.unsupported("SIP003 plugins are not supported")
        }

        let bodyStart = schemeEnd.upperBound
        let rawBody = withoutQuery[bodyStart...]
        let methodAndPassword: String
        let endpoint: Substring
        if let at = rawBody.firstIndex(of: "@") {
            methodAndPassword = try decodeShadowsocksUserinfo(rawBody[..<at])
            endpoint = trimTrailingSlash(rawBody[rawBody.index(after: at)...])
        } else {
            guard let decoded = decodeBase64(String(rawBody)),
                let decodedText = String(data: decoded, encoding: .utf8),
                let at = decodedText.lastIndex(of: "@")
            else {
                throw ProxyLinkError.invalid("Shadowsocks userinfo is invalid")
            }
            methodAndPassword = String(decodedText[..<at])
            endpoint = decodedText[decodedText.index(after: at)...]
        }

        let (methodPart, passwordPart) = splitOnce(methodAndPassword[...], separator: ":")
        let method = String(methodPart)
        let password = String(passwordPart ?? "")
        guard !method.isEmpty, passwordPart != nil else {
            throw ProxyLinkError.invalid("Shadowsocks userinfo must be method:password")
        }
        guard shadowsocksMethods.contains(method) else {
            throw ProxyLinkError.unsupported("method \"\(method)\" is not supported")
        }
        guard !password.isEmpty else {
            throw ProxyLinkError.invalid("password is missing")
        }
        if method.hasPrefix("2022-blake3-") {
            let byteCount = method == "2022-blake3-aes-128-gcm" ? 16 : 32
            guard Data(base64Encoded: password)?.count == byteCount else {
                throw ProxyLinkError.invalid(
                    "password for \"\(method)\" must be base64 encoding of \(byteCount) bytes")
            }
        }

        let (host, port) = try parseEndpoint(endpoint)
        return ShadowsocksImportResult(
            password: password,
            meta: ShadowsocksMeta(server: host, port: port, method: method),
            name: try parsedName(rawFragment, fallback: host))
    }

    private static func parseTrojan(
        _ text: String, schemeEnd: Range<String.Index>
    ) throws -> TrojanImportResult {
        let (withoutFragment, rawFragment) = splitOnce(text[...], separator: "#")
        let (withoutQuery, rawQuery) = splitOnce(withoutFragment, separator: "?")
        let authority = withoutQuery[schemeEnd.upperBound...]
        guard let at = authority.firstIndex(of: "@") else {
            throw ProxyLinkError.invalid("password is missing")
        }
        let password = try decode(authority[..<at], component: "password")
        guard !password.isEmpty else {
            throw ProxyLinkError.invalid("password is missing")
        }
        let (host, port) = try parseEndpoint(authority[authority.index(after: at)...])
        let query = try parseQuery(rawQuery)

        let security: TLSSecurity
        switch query["security"] {
        case nil, "tls": security = .tls
        case "reality": security = .reality
        case "none":
            throw ProxyLinkError.unsupported("security=none is not supported")
        default:
            throw ProxyLinkError.invalid("security must be tls or reality")
        }
        if let headerType = query["headerType"], !headerType.isEmpty, headerType != "none" {
            throw ProxyLinkError.unsupported(
                "headerType \"\(headerType)\" is not supported yet.")
        }
        let transport = try parseTransport(query)
        if security == .reality {
            guard let publicKey = query["pbk"], !publicKey.isEmpty else {
                throw ProxyLinkError.invalid("REALITY requires pbk")
            }
        }
        let fingerprint = query["fp"] ?? (security == .reality ? "chrome" : nil)
        return TrojanImportResult(
            password: password,
            meta: TrojanMeta(
                server: host,
                port: port,
                security: security,
                sni: query["sni"] ?? host,
                fingerprint: fingerprint,
                alpn: parseALPN(query["alpn"]),
                realityPublicKey: query["pbk"],
                realityShortID: nonempty(query["sid"]),
                transport: transport,
                allowInsecure: isTrue(query["allowInsecure"]) || isTrue(query["insecure"])),
            name: try parsedName(rawFragment, fallback: host))
    }

    private static func parseVMess(
        _ text: String, schemeEnd: Range<String.Index>
    ) throws -> VMessImportResult {
        let (withoutFragment, _) = splitOnce(text[...], separator: "#")
        let body = String(withoutFragment[schemeEnd.upperBound...])
        guard let data = decodeBase64(body),
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            throw ProxyLinkError.unsupported("only the V2RayN vmess:// form is supported")
        }

        guard let server = nonempty(json["add"] as? String) else {
            throw ProxyLinkError.invalid("server is missing")
        }
        guard isValidHost(server) else {
            throw ProxyLinkError.invalid("host is invalid")
        }
        let port = try integer(json["port"], field: "port")
        guard (1...65_535).contains(port) else {
            throw ProxyLinkError.invalid("port must be between 1 and 65535")
        }
        guard let rawUUID = nonempty(json["id"] as? String) else {
            throw ProxyLinkError.invalid("UUID is missing")
        }
        guard isCanonicalUUIDText(rawUUID), let uuid = UUID(uuidString: rawUUID) else {
            throw ProxyLinkError.invalid("UUID is invalid")
        }
        let alterID = try optionalInteger(json["aid"], field: "aid") ?? 0
        guard alterID == 0 else {
            throw ProxyLinkError.unsupported("alterId other than 0 is not supported")
        }

        let security =
            nonempty(json["scy"] as? String) ?? nonempty(json["security"] as? String)
            ?? "auto"
        guard ["auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305"].contains(security)
        else {
            throw ProxyLinkError.unsupported("security \"\(security)\" is not supported")
        }
        let tlsSecurity: TLSSecurity
        switch json["tls"] as? String {
        case nil, "": tlsSecurity = .none
        case "tls": tlsSecurity = .tls
        case "reality": tlsSecurity = .reality
        default:
            throw ProxyLinkError.invalid("tls must be empty, tls, or reality")
        }
        if tlsSecurity == .reality {
            guard nonempty(json["pbk"] as? String) != nil else {
                throw ProxyLinkError.invalid("REALITY requires pbk")
            }
        }
        let headerType = json["type"] as? String
        if let headerType, !headerType.isEmpty, headerType != "none" {
            throw ProxyLinkError.unsupported(
                "header type \"\(headerType)\" is not supported")
        }
        let transport: ProxyTransport
        switch nonempty(json["net"] as? String) ?? "tcp" {
        case "tcp": transport = .tcp
        case "ws":
            transport = .ws(
                path: nonempty(json["path"] as? String) ?? "/",
                host: nonempty(json["host"] as? String))
        case "grpc":
            transport = .grpc(serviceName: nonempty(json["path"] as? String) ?? "")
        case let unsupported:
            throw ProxyLinkError.unsupported(
                "Transport \"\(unsupported)\" is not supported yet.")
        }

        let fingerprint =
            nonempty(json["fp"] as? String)
            ?? (tlsSecurity == .reality ? "chrome" : nil)
        let name =
            nonempty((json["ps"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? server
        return VMessImportResult(
            uuid: uuid.uuidString.lowercased(),
            meta: VMessMeta(
                server: server,
                port: port,
                security: security,
                tlsSecurity: tlsSecurity,
                sni: tlsSecurity == .none ? nil : nonempty(json["sni"] as? String) ?? server,
                fingerprint: fingerprint,
                alpn: parseALPN(json["alpn"] as? String),
                realityPublicKey: nonempty(json["pbk"] as? String),
                realityShortID: nonempty(json["sid"] as? String),
                transport: transport,
                allowInsecure: jsonBoolean(json["allowInsecure"]) || jsonBoolean(json["insecure"])),
            name: String(name.prefix(Tunnel.nameMaxLength)))
    }

    private static func decodeShadowsocksUserinfo(_ value: Substring) throws -> String {
        let decoded = try decode(value, component: "userinfo")
        if let data = decodeBase64(decoded), let text = String(data: data, encoding: .utf8),
            text.contains(":")
        {
            return text
        }
        return decoded
    }

    private static func parseTransport(_ query: [String: String]) throws -> ProxyTransport {
        switch query["type"] {
        case nil, "tcp": return .tcp
        case "ws": return .ws(path: query["path"] ?? "/", host: query["host"])
        case "grpc": return .grpc(serviceName: query["serviceName"] ?? "")
        case let type?:
            throw ProxyLinkError.unsupported("Transport \"\(type)\" is not supported yet.")
        }
    }

    private static func appendTransport(
        _ transport: ProxyTransport, to query: inout [(String, String)]
    ) {
        switch transport {
        case .tcp:
            break
        case .ws(let path, let host):
            query.append(("type", "ws"))
            if path != "/" { query.append(("path", path)) }
            append(host, as: "host", to: &query)
        case .grpc(let serviceName):
            query.append(("type", "grpc"))
            if !serviceName.isEmpty { query.append(("serviceName", serviceName)) }
        }
    }

    private static func parseEndpoint(_ endpoint: Substring) throws -> (String, Int) {
        let rawHost: Substring
        let rawPort: Substring
        if endpoint.first == "[" {
            guard let closingBracket = endpoint.firstIndex(of: "]") else {
                throw ProxyLinkError.invalid("IPv6 host is missing a closing bracket")
            }
            rawHost = endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket]
            let afterBracket = endpoint[endpoint.index(after: closingBracket)...]
            guard afterBracket.first == ":" else {
                throw ProxyLinkError.invalid("port is missing")
            }
            rawPort = afterBracket.dropFirst()
            guard isIPv6(String(rawHost)) else {
                throw ProxyLinkError.invalid("host is invalid")
            }
        } else {
            guard let colon = endpoint.lastIndex(of: ":") else {
                throw ProxyLinkError.invalid("port is missing")
            }
            rawHost = endpoint[..<colon]
            rawPort = endpoint[endpoint.index(after: colon)...]
            guard !rawHost.contains(":") else {
                throw ProxyLinkError.invalid("IPv6 host must be enclosed in brackets")
            }
        }
        let host = String(rawHost)
        guard !host.isEmpty else { throw ProxyLinkError.invalid("host is missing") }
        guard isValidHost(host) else { throw ProxyLinkError.invalid("host is invalid") }
        guard !rawPort.isEmpty else { throw ProxyLinkError.invalid("port is missing") }
        guard rawPort.allSatisfy(\.isNumber), let port = Int(rawPort), (1...65_535).contains(port)
        else {
            throw ProxyLinkError.invalid("port must be between 1 and 65535")
        }
        return (host, port)
    }

    private static func parseQuery(_ rawQuery: Substring?) throws -> [String: String] {
        guard let rawQuery else { return [:] }
        var result: [String: String] = [:]
        for item in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let pair = splitOnce(item, separator: "=")
            let key = try decode(pair.0, component: "query key")
            result[key] = try decode(pair.1 ?? "", component: "query value")
        }
        return result
    }

    private static func parsedName(_ rawFragment: Substring?, fallback: String) throws -> String {
        let decoded = try decode(rawFragment ?? "", component: "fragment")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((decoded.isEmpty ? fallback : decoded).prefix(Tunnel.nameMaxLength))
    }

    private static func decode(_ value: Substring, component: String) throws -> String {
        guard let decoded = String(value).removingPercentEncoding else {
            throw ProxyLinkError.invalid("\(component) has invalid percent encoding")
        }
        return decoded
    }

    private static func decodeBase64(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard normalized.count % 4 != 1 else { return nil }
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }

    private static func append(
        _ value: String?, as key: String, to query: inout [(String, String)]
    ) {
        if let value { query.append((key, value)) }
    }

    private static func encodedQuery(_ query: [(String, String)]) -> String {
        query.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private static func encodedHost(_ host: String) -> String {
        isIPv6(host) ? "[\(host)]" : host
    }

    private static func percentEncode(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var result = ""
        for byte in value.utf8 {
            if (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte)
            {
                result.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                result.append("%")
                result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte >> 4)]))
                result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte & 0x0F)]))
            }
        }
        return result
    }

    private static func integer(_ value: Any?, field: String) throws -> Int {
        guard let result = try optionalInteger(value, field: field) else {
            throw ProxyLinkError.invalid("\(field) is missing")
        }
        return result
    }

    private static func optionalInteger(_ value: Any?, field: String) throws -> Int? {
        guard let value else { return nil }
        if let string = value as? String, string.allSatisfy(\.isNumber), let result = Int(string) {
            return result
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            if double.isFinite, double.rounded() == double, let result = Int(exactly: double) {
                return result
            }
        }
        throw ProxyLinkError.invalid("\(field) must be a number or numeric string")
    }

    private static func splitOnce(
        _ value: Substring, separator: Character
    ) -> (Substring, Substring?) {
        guard let index = value.firstIndex(of: separator) else { return (value, nil) }
        return (value[..<index], value[value.index(after: index)...])
    }

    private static func trimTrailingSlash(_ value: Substring) -> Substring {
        value.last == "/" ? value.dropLast() : value
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func parseALPN(_ value: String?) -> [String] {
        value?.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private static func isTrue(_ value: String?) -> Bool {
        value == "1" || value == "true"
    }

    private static func jsonBoolean(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? String { return isTrue(value) }
        return (value as? NSNumber)?.intValue == 1
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

    private static func isIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
}
