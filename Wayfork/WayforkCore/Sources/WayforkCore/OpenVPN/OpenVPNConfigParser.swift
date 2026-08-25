import Foundation

public struct OpenVPNImportResult: Sendable, Equatable {
    /// Sanitized profile body: exactly what the daemon later writes to run/t-<id>.ovpn.
    public var sanitizedConfig: String
    /// Remotes and credential requirements, automatic DNS defaults, and the config hash.
    public var meta: OpenVPNMeta
    /// Names of stripped directives, unique and ordered by first occurrence.
    public var strippedDirectives: [String]
    /// Filled when `auth-user-pass <file>` points at a readable two-line file.
    public var credentials: Credentials?

    public init(
        sanitizedConfig: String,
        meta: OpenVPNMeta,
        strippedDirectives: [String],
        credentials: Credentials?
    ) {
        self.sanitizedConfig = sanitizedConfig
        self.meta = meta
        self.strippedDirectives = strippedDirectives
        self.credentials = credentials
    }
}

public enum OpenVPNImportError: Error, Equatable, Sendable {
    case missingFiles([String])
    case unsupported(String)
    case noRemote
    case malformed(line: Int, reason: String)
}

public enum OpenVPNConfigParser {
    public static func parse(_ text: String, baseDirectory: URL?) throws -> OpenVPNImportResult {
        try parse(text) { name in
            guard let baseDirectory else { return nil }
            return try? Data(contentsOf: baseDirectory.appendingPathComponent(name))
        }
    }

    public static func parse(
        _ text: String,
        readFile: (String) -> Data?
    ) throws -> OpenVPNImportResult {
        try withoutActuallyEscaping(readFile) { readFile in
            var parser = Parser(text: text, readFile: readFile)
            return try parser.parse()
        }
    }
}

private struct Parser {
    private enum OutputLine {
        case text(String)
        case generatedKeyDirection(String)
    }

    private struct RemoteSpec {
        var host: String
        var port: Int?
        var proto: String?
    }

    private struct BlockTag {
        var name: String
        var isClosing: Bool
    }

    private static let inlineFileDirectives: Set<String> = [
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "dh", "pkcs12",
        "crl-verify", "extra-certs",
    ]

    private static let strippedDirectives: Set<String> = [
        "dev", "dev-type", "dev-node", "route", "route-ipv6", "redirect-gateway",
        "redirect-private", "dhcp-option", "route-nopull", "pull-filter", "block-outside-dns",
        "ifconfig-noexec", "route-noexec", "route-gateway", "route-metric", "daemon", "up",
        "down", "up-restart", "up-delay", "down-pre", "route-up", "route-pre-down", "ipchange",
        "client-connect", "client-disconnect", "learn-address", "auth-user-pass-verify",
        "tls-verify", "tls-export-cert", "script-security", "plugin", "log", "log-append",
        "writepid", "status", "status-version", "user", "group", "chroot", "verb", "mute",
        "askpass", "config", "dns-updown",
    ]

    private let lines: [String]
    private let readFile: (String) -> Data?
    private var output: [OutputLine] = []
    private var remoteSpecs: [RemoteSpec] = []
    private var globalPort: Int?
    private var globalProto: String?
    private var needsCredentials = false
    private var encryptedKeyFound = false
    private var pkcs12Found = false
    private var askpassFound = false
    private var keyDirectionFound = false
    private var credentials: Credentials?
    private var stripped: [String] = []
    private var strippedSet: Set<String> = []
    private var missingFiles: [String] = []
    private var missingFileSet: Set<String> = []
    private var unsupportedReason: String?

    init(text: String, readFile: @escaping (String) -> Data?) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).trimmingSuffix("\r")
        }
        self.readFile = readFile
    }

    mutating func parse() throws -> OpenVPNImportResult {
        try scan(0..<lines.count, insideConnection: false)

        if let unsupportedReason {
            throw OpenVPNImportError.unsupported(unsupportedReason)
        }
        if !missingFiles.isEmpty {
            throw OpenVPNImportError.missingFiles(missingFiles)
        }
        if remoteSpecs.isEmpty {
            throw OpenVPNImportError.noRemote
        }

        let renderedLines = renderOutput()
        let sanitizedConfig = renderedLines.joined(separator: "\n") + "\n"
        let remotes = remoteSpecs.map {
            Remote(
                host: $0.host,
                port: $0.port ?? globalPort ?? 1194,
                proto: Self.normalizeProto($0.proto ?? globalProto ?? "udp")
            )
        }
        let meta = OpenVPNMeta(
            remotes: remotes,
            needsCredentials: needsCredentials,
            needsKeyPassphrase: encryptedKeyFound || (pkcs12Found && askpassFound),
            configHash: Hashing.sha256Hex(sanitizedConfig)
        )
        return OpenVPNImportResult(
            sanitizedConfig: sanitizedConfig,
            meta: meta,
            strippedDirectives: stripped,
            credentials: credentials
        )
    }

    private mutating func scan(_ range: Range<Int>, insideConnection: Bool) throws {
        var index = range.lowerBound
        while index < range.upperBound {
            let lineNumber = index + 1
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                index += 1
                continue
            }

            if let tag = Self.blockTag(from: trimmed) {
                guard !tag.isClosing else {
                    throw OpenVPNImportError.malformed(
                        line: lineNumber,
                        reason: "unexpected closing block </\(tag.name)>"
                    )
                }
                guard
                    let closingIndex = findClosingTag(
                        for: tag.name, after: index, limit: range.upperBound)
                else {
                    throw OpenVPNImportError.malformed(
                        line: lineNumber,
                        reason: "unterminated inline block <\(tag.name)>"
                    )
                }

                if tag.name.lowercased() == "connection" {
                    output.append(.text("<\(tag.name)>"))
                    try scan((index + 1)..<closingIndex, insideConnection: true)
                    output.append(.text("</\(tag.name)>"))
                } else {
                    appendInlineBlock(
                        name: tag.name, body: Array(lines[(index + 1)..<closingIndex]))
                }
                index = closingIndex + 1
                continue
            }

            let arguments = try OpenVPNConfigLexer.tokenize(trimmed, lineNumber: lineNumber)
            guard let directiveArgument = arguments.first else {
                index += 1
                continue
            }
            let directive = directiveArgument.value.lowercased()
            let values = Array(arguments.dropFirst())
            processDirective(
                directive,
                originalDirective: directiveArgument.value,
                arguments: values,
                insideConnection: insideConnection
            )
            index += 1
        }
    }

    private mutating func processDirective(
        _ directive: String,
        originalDirective: String,
        arguments: [OpenVPNArgument],
        insideConnection: Bool
    ) {
        recordUnsupportedIfNeeded(directive: directive, arguments: arguments)

        if directive == "askpass" {
            askpassFound = true
        }
        if directive == "key-direction" {
            keyDirectionFound = true
        }

        if Self.shouldStrip(directive) {
            recordStripped(directive)
            return
        }

        if directive == "auth-user-pass" {
            needsCredentials = true
            if let fileName = arguments.first?.value {
                if let data = readFile(fileName) {
                    if credentials == nil, let parsed = Self.credentials(from: data) {
                        credentials = parsed
                    }
                } else {
                    recordMissingFile(fileName)
                }
            }
            output.append(.text("auth-user-pass"))
            return
        }

        if Self.inlineFileDirectives.contains(directive), let fileName = arguments.first?.value {
            if directive == "crl-verify",
                arguments.dropFirst().contains(where: {
                    $0.value.lowercased() == "dir"
                })
            {
                recordUnsupported("crl-verify dir")
                return
            }
            guard let data = readFile(fileName) else {
                recordMissingFile(fileName)
                return
            }
            appendInlinedFile(directive: directive, data: data)
            if directive == "tls-auth", let direction = arguments.dropFirst().first?.value {
                output.append(.generatedKeyDirection(direction))
            }
            return
        }

        if directive == "remote", let host = arguments.first?.value {
            let explicitPort: Int?
            let explicitProto: String?
            if arguments.count > 1, let port = Int(arguments[1].value) {
                explicitPort = port
                explicitProto = arguments.count > 2 ? arguments[2].value : nil
            } else {
                explicitPort = nil
                explicitProto = arguments.count > 1 ? arguments[1].value : nil
            }
            remoteSpecs.append(RemoteSpec(host: host, port: explicitPort, proto: explicitProto))
        } else if !insideConnection, directive == "port", let value = arguments.first?.value {
            globalPort = Int(value)
        } else if !insideConnection, directive == "proto", let value = arguments.first?.value {
            globalProto = value
        }

        output.append(
            .text(OpenVPNConfigLexer.renderDirective(originalDirective, arguments: arguments)))
    }

    private mutating func appendInlineBlock(name: String, body: [String]) {
        let normalizedName = name.lowercased()
        let body = body.map(Self.trimTrailingWhitespace)
        output.append(.text("<\(name)>"))
        output.append(contentsOf: body.map(OutputLine.text))
        output.append(.text("</\(name)>"))

        if normalizedName == "key", body.contains(where: { $0.contains("ENCRYPTED") }) {
            encryptedKeyFound = true
        }
        if normalizedName == "pkcs12" {
            pkcs12Found = true
        }
    }

    private mutating func appendInlinedFile(directive: String, data: Data) {
        let body: [String]
        if directive == "pkcs12" {
            body = Self.base64Lines(data)
        } else {
            body = Self.fileLines(data).map(Self.trimTrailingWhitespace)
        }
        appendInlineBlock(name: directive, body: body)
    }

    private mutating func recordUnsupportedIfNeeded(
        directive: String, arguments: [OpenVPNArgument]
    ) {
        let first = arguments.first?.value.lowercased()
        switch directive {
        case "dev" where first == "null":
            recordUnsupported("dev null")
        case "dev" where first.map(Self.isTapDevice) == true:
            recordUnsupported("dev \(first ?? "tap")")
        case "dev-type" where first == "tap":
            recordUnsupported("dev-type tap")
        case "mode" where first == "server":
            recordUnsupported("mode server")
        case "server":
            recordUnsupported("server")
        case "server-bridge":
            recordUnsupported("server-bridge")
        default:
            break
        }
    }

    private mutating func recordUnsupported(_ reason: String) {
        if unsupportedReason == nil {
            unsupportedReason = reason
        }
    }

    private mutating func recordStripped(_ directive: String) {
        if strippedSet.insert(directive).inserted {
            stripped.append(directive)
        }
    }

    private mutating func recordMissingFile(_ name: String) {
        if missingFileSet.insert(name).inserted {
            missingFiles.append(name)
        }
    }

    private func findClosingTag(for name: String, after openingIndex: Int, limit: Int) -> Int? {
        for index in (openingIndex + 1)..<limit {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            if let tag = Self.blockTag(from: candidate), tag.isClosing,
                tag.name.caseInsensitiveCompare(name) == .orderedSame
            {
                return index
            }
        }
        return nil
    }

    private func renderOutput() -> [String] {
        var generatedDirectionUsed = false
        return output.compactMap { line in
            switch line {
            case .text(let text):
                return text
            case .generatedKeyDirection(let direction):
                guard !keyDirectionFound, !generatedDirectionUsed else { return nil }
                generatedDirectionUsed = true
                let argument = OpenVPNArgument(value: direction, quote: nil)
                return "key-direction \(OpenVPNConfigLexer.renderArgument(argument))"
            }
        }
    }

    private static func shouldStrip(_ directive: String) -> Bool {
        strippedDirectives.contains(directive) || directive.hasPrefix("management")
    }

    private static func blockTag(from line: String) -> BlockTag? {
        guard line.first == "<", line.last == ">", line.count >= 3 else { return nil }
        var contents = String(line.dropFirst().dropLast())
        let isClosing = contents.hasPrefix("/")
        if isClosing {
            contents.removeFirst()
        }
        guard !contents.isEmpty,
            !contents.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "/" })
        else {
            return nil
        }
        return BlockTag(name: contents, isClosing: isClosing)
    }

    private static func credentials(from data: Data) -> Credentials? {
        let lines = fileLines(data)
        guard lines.count >= 2 else { return nil }
        return Credentials(
            username: lines[0].trimmingCharacters(in: .whitespacesAndNewlines),
            password: lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func fileLines(_ data: Data) -> [String] {
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingSuffix("\r") }
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func base64Lines(_ data: Data) -> [String] {
        let encoded = data.base64EncodedString()
        return stride(from: 0, to: encoded.count, by: 64).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(64, encoded.count - offset))
            return String(encoded[start..<end])
        }
    }

    private static func normalizeProto(_ proto: String) -> String {
        switch proto.lowercased() {
        case "udp", "udp4", "udp6":
            return "udp"
        case "tcp", "tcp-client", "tcp4", "tcp6", "tcp4-client", "tcp6-client":
            return "tcp"
        default:
            return proto.lowercased()
        }
    }

    private static func isTapDevice(_ value: String) -> Bool {
        guard value.hasPrefix("tap") else { return false }
        let unit = value.dropFirst(3)
        return unit.isEmpty || unit.allSatisfy(\.isNumber)
    }

    private static func trimTrailingWhitespace(_ line: String) -> String {
        var result = line
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: Character) -> String {
        last == suffix ? String(dropLast()) : self
    }
}
