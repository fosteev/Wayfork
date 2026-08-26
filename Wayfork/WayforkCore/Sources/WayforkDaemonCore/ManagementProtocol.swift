import Foundation
import WayforkCore

/// One `>STATE:` notification (`time,state,description,tun_ip,remote_ip,…`).
public struct ManagementState: Sendable, Equatable {
    public var time: Int?
    /// `CONNECTED`, `RECONNECTING`, `EXITING`, `WAIT`, `AUTH`, …
    public var name: String
    /// `SUCCESS`, the reconnect reason, the exit reason, …
    public var description: String
    public var tunnelIP: String?
    public var remoteIP: String?

    public init(
        time: Int? = nil, name: String, description: String = "", tunnelIP: String? = nil,
        remoteIP: String? = nil
    ) {
        self.time = time
        self.name = name
        self.description = description
        self.tunnelIP = tunnelIP
        self.remoteIP = remoteIP
    }
}

/// A line received from the OpenVPN management interface, parsed
/// (docs/design/04-tunnels.md, "Management protocol handling").
public enum ManagementEvent: Sendable, Equatable {
    case state(ManagementState)
    /// `>LOG:time,flags,message`
    case log(flags: String, message: String)
    /// `>PASSWORD:Need '<kind>' …` — `kind` is `Auth` or `Private Key`.
    case passwordNeeded(kind: String)
    /// `>PASSWORD:Verification Failed: '<kind>'`
    case passwordVerificationFailed(kind: String)
    case fatal(String)
    case hold(String)
    case info(String)
    case bytecount(in: Int64, out: Int64)
    /// `SUCCESS: …` reply to a command.
    case success(String)
    /// `ERROR: …` reply to a command.
    case error(String)
    /// Anything else (`END`, `>ECHO`, `>NOTIFY`, …).
    case other(String)
}

public enum ManagementProtocol {
    public static func parse(_ line: String) -> ManagementEvent {
        if line.hasPrefix(">") {
            guard let colon = line.firstIndex(of: ":") else { return .other(line) }
            let kind = line[line.index(after: line.startIndex)..<colon]
            let payload = String(line[line.index(after: colon)...])
            switch kind {
            case "STATE": return .state(parseState(payload))
            case "LOG": return parseLog(payload)
            case "PASSWORD": return parsePassword(payload)
            case "FATAL": return .fatal(payload)
            case "HOLD": return .hold(payload)
            case "INFO": return .info(payload)
            case "BYTECOUNT":
                let parts = payload.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 2, let inBytes = Int64(parts[0]),
                    let outBytes = Int64(parts[1])
                else { return .other(line) }
                return .bytecount(in: inBytes, out: outBytes)
            default: return .other(line)
            }
        }
        if line.hasPrefix("SUCCESS:") {
            return .success(line.dropFirst("SUCCESS:".count).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("ERROR:") {
            return .error(line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces))
        }
        return .other(line)
    }

    private static func parseState(_ payload: String) -> ManagementState {
        let parts = payload.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        func field(_ index: Int) -> String? {
            guard index < parts.count, !parts[index].isEmpty else { return nil }
            return parts[index]
        }
        return ManagementState(
            time: field(0).flatMap(Int.init),
            name: field(1) ?? "",
            description: field(2) ?? "",
            tunnelIP: field(3),
            remoteIP: field(4))
    }

    private static func parseLog(_ payload: String) -> ManagementEvent {
        let parts = payload.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .log(flags: "", message: payload) }
        return .log(flags: String(parts[1]), message: String(parts[2]))
    }

    private static func parsePassword(_ payload: String) -> ManagementEvent {
        if payload.hasPrefix("Need '"), let kind = quoted(payload) {
            return .passwordNeeded(kind: kind)
        }
        if payload.hasPrefix("Verification Failed:"), let kind = quoted(payload) {
            return .passwordVerificationFailed(kind: kind)
        }
        return .other(">PASSWORD:" + payload)
    }

    /// First `'…'` substring.
    private static func quoted(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "'") else { return nil }
        let rest = text[text.index(after: open)...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<close])
    }

    /// `>LOG` flags → level (docs/design/06-logging.md): `F` error, `W`/`N` warning,
    /// `D` debug, everything else info.
    public static func level(forLogFlags flags: String) -> LogLevel {
        if flags.contains("F") { return .error }
        if flags.contains("W") || flags.contains("N") { return .warning }
        if flags.contains("D") { return .debug }
        return .info
    }

    /// `dhcp-option DNS <ip>` entries of a logged `PUSH_REPLY`, in order, de-duplicated;
    /// nil when the line is not a PUSH_REPLY.
    public static func pushedDNS(fromLogMessage message: String) -> [String]? {
        guard let start = message.range(of: "PUSH_REPLY,") else { return nil }
        var body = message[start.upperBound...]
        if let quote = body.lastIndex(of: "'") { body = body[..<quote] }
        var servers: [String] = []
        for option in body.split(separator: ",") {
            let words = option.split(whereSeparator: \.isWhitespace)
            guard words.count == 3, words[0] == "dhcp-option", words[1] == "DNS" else { continue }
            let server = String(words[2])
            if !servers.contains(server) { servers.append(server) }
        }
        return servers
    }
}

/// Commands written to the management socket. Values are quoted per the management
/// interface spec (backslash-escaped `"` and `\`); the caller must never log them.
public enum ManagementCommand {
    public static let stateOn = "state on"
    public static let logOn = "log on"
    public static let bytecount = "bytecount 5"
    public static let holdRelease = "hold release"
    public static let signalTerm = "signal SIGTERM"

    public static func username(kind: String, _ value: String) -> String {
        "username \(quote(kind)) \(quote(value))"
    }

    public static func password(kind: String, _ value: String) -> String {
        "password \(quote(kind)) \(quote(value))"
    }

    public static func quote(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"", "\\": escaped.append("\\")
            default: break
            }
            escaped.unicodeScalars.append(scalar)
        }
        escaped.append("\"")
        return escaped
    }
}

/// openvpn's own stdout with `--machine-readable-output`: `<epoch> <flags> <message>`.
/// Only relevant before the management socket is up (options errors at startup).
public enum OpenVPNOutput {
    /// `Opened utun device utunN` → `utunN` (Darwin utun driver); nil for other lines.
    public static func openedInterface(in message: String) -> String? {
        let marker = "Opened utun device "
        guard let range = message.range(of: marker) else { return nil }
        let name = message[range.upperBound...].prefix { !$0.isWhitespace }
        return name.hasPrefix("utun") ? String(name) : nil
    }

    public static func parse(_ line: String) -> (flags: String, message: String) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber),
            !parts[1].isEmpty, parts[1].allSatisfy(\.isUppercase)
        else { return ("", line) }
        return (String(parts[1]), String(parts[2]))
    }
}
