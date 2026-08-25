import Foundation
import WayforkCore

// wayforkctl — developer helper, not shipped in the app.
//
//   wayforkctl plan --bundle <Wayfork.app> [--ovpn <file> [--user u --pass p] [--pass-key pp]]…
//                   [--vless <uri>]… [--rule <pattern>=<tunnel name>]… [--log-level info]
//                   [--no-auto-reconnect] > plan.json
//
// Tunnels are named after the .ovpn file (without extension) or the VLESS URI fragment;
// `--rule` refers to those names. Secrets end up in the plan file: keep it root-only and
// delete it afterwards.

struct Usage: Error, CustomStringConvertible {
    var description: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("wayforkctl: \(message)\n".utf8))
    exit(2)
}

func buildPlan(_ arguments: ArraySlice<String>) throws -> RuntimePlan {
    var bundlePath: String?
    var store = Store()
    var secrets = PlanSecrets()
    var rules: [(pattern: String, tunnelName: String)] = []
    var lastOpenVPN: UUID?
    var slot = 0

    var iterator = arguments.makeIterator()
    func value(_ flag: String) throws -> String {
        guard let next = iterator.next() else { throw Usage(description: "\(flag) needs a value") }
        return next
    }
    while let flag = iterator.next() {
        switch flag {
        case "--bundle":
            bundlePath = try value(flag)
        case "--ovpn":
            let path = try value(flag)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let result = try OpenVPNConfigParser.parse(
                text, baseDirectory: URL(fileURLWithPath: path).deletingLastPathComponent())
            let tunnel = Tunnel(
                name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                slot: slot, kind: .openVPN(result.meta))
            slot += 1
            store.tunnels.append(tunnel)
            secrets.openVPNConfigs[tunnel.id] = result.sanitizedConfig
            if let credentials = result.credentials {
                secrets.credentials[tunnel.id] = credentials
            }
            lastOpenVPN = tunnel.id
        case "--user":
            guard let id = lastOpenVPN else { throw Usage(description: "--user before --ovpn") }
            let username = try value(flag)
            secrets.credentials[id] = Credentials(
                username: username, password: secrets.credentials[id]?.password ?? "")
        case "--pass":
            guard let id = lastOpenVPN else { throw Usage(description: "--pass before --ovpn") }
            let password = try value(flag)
            secrets.credentials[id] = Credentials(
                username: secrets.credentials[id]?.username ?? "", password: password)
        case "--pass-key":
            guard let id = lastOpenVPN else { throw Usage(description: "--pass-key before --ovpn") }
            secrets.keyPassphrases[id] = try value(flag)
        case "--vless":
            let result = try VLESSURIParser.parse(try value(flag))
            let tunnel = Tunnel(name: result.name, slot: slot, kind: .vless(result.meta))
            slot += 1
            store.tunnels.append(tunnel)
            secrets.vlessUUIDs[tunnel.id] = result.uuid
        case "--rule":
            let spec = try value(flag)
            guard let separator = spec.firstIndex(of: "=") else {
                throw Usage(description: "--rule wants <pattern>=<tunnel name>")
            }
            rules.append(
                (String(spec[..<separator]), String(spec[spec.index(after: separator)...])))
        case "--log-level":
            guard let level = LogLevel(rawValue: try value(flag)) else {
                throw Usage(description: "--log-level: error|warning|info|debug")
            }
            store.settings.logLevel = level
        case "--no-auto-reconnect":
            store.settings.autoReconnect = false
        default:
            throw Usage(description: "unknown argument \(flag)")
        }
    }
    guard let bundlePath else { throw Usage(description: "--bundle <Wayfork.app> is required") }
    for (pattern, tunnelName) in rules {
        guard
            let tunnel = store.tunnels.first(where: {
                $0.name.lowercased() == tunnelName.lowercased()
            })
        else { throw Usage(description: "rule \(pattern): no tunnel named \(tunnelName)") }
        let match: RuleMatch = pattern.contains("*") ? .wildcard : .suffix
        store.rules.append(
            Rule(
                pattern: try RulePattern.normalize(pattern, match: match), match: match,
                tunnelID: tunnel.id))
    }
    let built = RuntimePlanBuilder.build(store: store, secrets: secrets, bundlePath: bundlePath)
    for warning in built.warnings {
        FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
    }
    return built.plan
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.first == "plan" else {
    fail(
        "usage: wayforkctl plan --bundle <Wayfork.app> [--ovpn <file> …] [--vless <uri>] [--rule <pattern>=<tunnel>] …"
    )
}
do {
    let plan = try buildPlan(arguments.dropFirst())
    let data = try JSONCoding.prettyEncoder.encode(plan)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("\(error)")
}
