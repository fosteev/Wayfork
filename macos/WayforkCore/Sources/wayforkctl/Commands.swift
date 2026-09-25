import Foundation
import WayforkCore

// F21 commands (docs/design/09-wayforkctl.md): `logs` reads the app's log files, the rest
// talk to the running app over its control socket.

let helpText = """
    usage: wayforkctl <command> [options]

    Read (safe):
      logs [--source S]… [--level L] [--grep T]… [--since D] [--tail N] [--json] [--raw]
            the app's log files, works with the app quit. S: app | daemon | sing-box |
            openvpn | openvpn:<id>; L: error | warning | info | debug (threshold);
            D: 90s | 15m | 2h | 1d | ISO-8601; N: default 100, 0 = all. Configured server
            addresses are replaced by server-N unless --raw (resolved server IPs are not).
      status                     tunnels, groups, rule count, last apply, pending change
      failed                     Can't reach rows and per-exit counters
      rules [--via EXIT]         rules in route order

    Change (needs the app; reverted unless confirmed):
      rules add <pattern> --via EXIT [--confirm-within S] [--dry-run]
      rules remove <pattern|id> [--confirm-within S] [--dry-run]
      log-level <level> [--confirm-within S]
      confirm                    keep the pending change
      revert                     undo the pending change now
      reconnect <tunnel>         restart one tunnel (runtime only, nothing to confirm)

      EXIT / tunnel: a tunnel or group name (case-insensitive) or id, or `direct`.
      --confirm-within S: seconds until an unconfirmed change is undone; default 60,
      10–600, 0 = keep immediately. One pending change at a time.

    Developer mode:
      plan --bundle <Wayfork.app> …   build a daemon plan (docs/design/05-daemon.md)

    For assistants:
      Read with `logs` (narrow it: --source, --level warning, --grep <host>, --since 10m)
      and `failed` before changing anything. Change with the default --confirm-within,
      check that the fix works AND that you can still reach your own API, then run
      `wayforkctl confirm`; if the change cut you off it undoes itself. Never pass
      --confirm-within 0, never quit, restart or turn off Wayfork: your own traffic may go
      through it.

    Exit codes: 0 ok, 1 the app refused, 2 usage error, 3 Wayfork is not running.
    """

struct Usage: Error, CustomStringConvertible {
    var description: String
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("wayforkctl: \(message)\n".utf8))
    exit(code)
}

/// `--name value`, repeated `--name value`, `--flag` and positionals.
struct Arguments {
    var positionals: [String] = []
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>, valued: Set<String>, flags known: Set<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if valued.contains(argument) {
                guard let value = iterator.next() else {
                    throw Usage(description: "\(argument) needs a value")
                }
                values[argument, default: []].append(value)
            } else if known.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("--") {
                throw Usage(description: "unknown option \(argument)")
            } else {
                positionals.append(argument)
            }
        }
    }

    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func int(_ name: String) throws -> Int? {
        guard let text = value(name) else { return nil }
        guard let number = Int(text), number >= 0 else {
            throw Usage(description: "\(name) needs a non-negative number, got \(text)")
        }
        return number
    }
}

// MARK: - logs

func runLogs(_ arguments: ArraySlice<String>) throws {
    let args = try Arguments(
        arguments, valued: ["--source", "--level", "--grep", "--since", "--tail"],
        flags: ["--json", "--raw"])
    guard args.positionals.isEmpty else {
        throw Usage(
            description: "logs takes no arguments: \(args.positionals.joined(separator: " "))")
    }
    var query = LogQuery(sources: args.all("--source"), grep: args.all("--grep"))
    if let level = args.value("--level") {
        guard let parsed = LogLevel(rawValue: level.lowercased()) else {
            throw Usage(description: "--level: error | warning | info | debug")
        }
        query.level = parsed
    }
    if let since = args.value("--since") {
        guard let date = LogQuery.parseSince(since) else {
            throw Usage(description: "--since: 90s | 15m | 2h | 1d | ISO-8601, got \(since)")
        }
        query.since = date
    }
    if let tail = try args.int("--tail") { query.tail = tail }

    let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Wayfork", isDirectory: true)
    var lines = query.run([
        LogArchive.lines(directory: directory, name: "runtime", query: query),
        LogArchive.lines(directory: directory, name: "wayfork", query: query),
    ])

    var redacted = 0
    if !args.has("--raw") {
        let storeURL = StoreRepository.defaultDirectory().appendingPathComponent(
            StoreRepository.fileName)
        if let data = try? Data(contentsOf: storeURL), let store = try? StoreCodec.decode(data) {
            let redactor = LogRedactor(store: store)
            for index in lines.indices {
                let (message, count) = redactor.redact(lines[index].message)
                lines[index].message = message
                redacted += count
            }
        } else {
            note("cannot read \(storeURL.path): server addresses are not redacted")
        }
    }

    if args.has("--json") {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines {
            let object: [String: String] = [
                "ts": formatter.string(from: line.ts), "source": line.source,
                "level": line.level.rawValue, "message": line.message,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    } else {
        let text = lines.map(LogLineFormat.format).joined(separator: "\n")
        if !text.isEmpty { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    }
    if lines.isEmpty { note("no matching lines in \(directory.path)") }
    if redacted > 0 { note("\(redacted) server address(es) redacted; --raw keeps them") }
}

private func note(_ message: String) {
    FileHandle.standardError.write(Data("# \(message)\n".utf8))
}

// MARK: - Control socket

func runControl(_ command: String, _ arguments: ArraySlice<String>) throws {
    let request: ControlRequest
    switch command {
    case "status", "failed", "confirm", "revert":
        let args = try Arguments(arguments, valued: [], flags: [])
        guard args.positionals.isEmpty else {
            throw Usage(description: "\(command) takes no arguments")
        }
        let method: ControlMethod =
            switch command {
            case "status": .status
            case "failed": .failed
            case "confirm": .confirm
            default: .revert
            }
        request = ControlRequest(method: method)
    case "rules":
        request = try rulesRequest(arguments)
    case "log-level":
        let args = try Arguments(arguments, valued: ["--confirm-within"], flags: [])
        guard args.positionals.count == 1,
            let level = LogLevel(rawValue: args.positionals[0].lowercased())
        else { throw Usage(description: "log-level error | warning | info | debug") }
        request = ControlRequest(
            method: .logLevelSet,
            params: ControlParams(level: level, confirmWithin: try args.int("--confirm-within")))
    case "reconnect":
        let args = try Arguments(arguments, valued: [], flags: [])
        guard args.positionals.count == 1 else {
            throw Usage(description: "reconnect <tunnel name or id>")
        }
        request = ControlRequest(
            method: .reconnect, params: ControlParams(tunnel: args.positionals[0]))
    default:
        throw Usage(description: "unknown command \(command); see wayforkctl help")
    }

    let reply: Data
    do {
        reply = try ControlClient.send(request, path: ControlPaths.socket().path)
    } catch ControlSocketError.notRunning {
        fail(ControlSocketError.notRunning.description, code: 3)
    }
    switch try ControlWire.decodeReply(reply) {
    case .success(let result):
        let data = try JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    case .failure(let error):
        fail("\(error.code.rawValue): \(error.message)", code: 1)
    }
}

private func rulesRequest(_ arguments: ArraySlice<String>) throws -> ControlRequest {
    let args = try Arguments(
        arguments, valued: ["--via", "--confirm-within"], flags: ["--dry-run"])
    let confirmWithin = try args.int("--confirm-within")
    let dryRun = args.has("--dry-run") ? true : nil
    switch args.positionals.first {
    case nil:
        return ControlRequest(method: .rulesList, params: ControlParams(via: args.value("--via")))
    case "add":
        guard args.positionals.count == 2, let via = args.value("--via") else {
            throw Usage(description: "rules add <pattern> --via <tunnel|group|direct>")
        }
        return ControlRequest(
            method: .rulesAdd,
            params: ControlParams(
                pattern: args.positionals[1], via: via, confirmWithin: confirmWithin,
                dryRun: dryRun))
    case "remove":
        guard args.positionals.count == 2 else {
            throw Usage(description: "rules remove <pattern|id>")
        }
        return ControlRequest(
            method: .rulesRemove,
            params: ControlParams(
                pattern: args.positionals[1], confirmWithin: confirmWithin, dryRun: dryRun))
    case let other?:
        throw Usage(description: "rules: unknown subcommand \(other) (add | remove)")
    }
}
