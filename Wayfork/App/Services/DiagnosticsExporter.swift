import Foundation
import WayforkCore

/// Builds `wayfork-diagnostics-<timestamp>.zip` (docs/design/06-logging.md, "Export
/// Diagnostics"). Pure file work; runs off the main actor.
enum DiagnosticsExporter {
    struct Input: Sendable {
        var store: Store
        var plan: RuntimePlan?
        var daemon: DaemonDiagnostics?
        var daemonInfo: DaemonInfo?
        var helperState: String
        var appVersion: String
        var logDirectory: URL
        var includeServerAddresses: Bool
        /// The latest F9 sample, for the `## traffic` section (one-way UDP counts, H3).
        var traffic: TrafficSnapshot?
    }

    static let maxLogBytes = 5 * 1024 * 1024

    static func suggestedFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "wayfork-diagnostics-\(formatter.string(from: now)).zip"
    }

    static func export(_ input: Input, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try build(input, to: destination)
        }.value
    }

    private static func build(_ input: Input, to destination: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent(
            "wayfork-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent("wayfork-diagnostics", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let options = SanitizerOptions(includeServerAddresses: input.includeServerAddresses)
        try write(systemReport(input), to: root.appendingPathComponent("system.txt"))
        let storeJSON = try StoreCodec.encode(input.store)
        try DiagnosticsSanitizer.sanitizeJSON(storeJSON, options: options)
            .write(to: root.appendingPathComponent("store.json"))
        if let plan = input.plan {
            try write(
                DiagnosticsSanitizer.sanitizeJSON(plan.singBox.config, options: options),
                to: root.appendingPathComponent("sing-box.json"))
            for (name, contents) in plan.singBox.ruleSets {
                try write(contents, to: root.appendingPathComponent(name))
            }
        }
        for name in [LogCenter.runtimeFileName, LogCenter.appFileName] {
            let source = input.logDirectory.appendingPathComponent("\(name).log")
            if let data = tail(of: source, maxBytes: maxLogBytes) {
                try data.write(to: root.appendingPathComponent("\(name).log"))
            }
        }
        if let daemon = input.daemon {
            let daemonDirectory = root.appendingPathComponent("daemon", isDirectory: true)
            try fileManager.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)
            try write(
                daemon.daemonLogTail.joined(separator: "\n"),
                to: daemonDirectory.appendingPathComponent("daemon.log"))
            for (name, lines) in daemon.childLogTails {
                try write(
                    lines.joined(separator: "\n"),
                    to: daemonDirectory.appendingPathComponent("\(name).log"))
            }
            try write(
                daemon.runDirectoryListing.joined(separator: "\n"),
                to: daemonDirectory.appendingPathComponent("run-listing.txt"))
            try write(daemon.routes, to: daemonDirectory.appendingPathComponent("routes.txt"))
        }

        try? fileManager.removeItem(at: destination)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", root.path, destination.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func systemReport(_ input: Input) -> String {
        var sections: [String] = []
        sections.append(
            """
            Wayfork \(input.appVersion)
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            helper: \(input.helperState)
            daemon: \(input.daemonInfo?.version ?? "unknown") at \(input.daemonInfo?.bundlePath ?? "?")
            sing-box: \(input.daemonInfo?.singBoxVersion ?? "unknown")
            openvpn: \(input.daemonInfo?.openVPNVersion ?? "unknown")
            generated: \(ISO8601DateFormatter().string(from: Date()))
            """)
        for (title, path, arguments) in [
            ("ifconfig", "/sbin/ifconfig", ["-a"]),
            ("route -n get default", "/sbin/route", ["-n", "get", "default"]),
            ("route -n get 1.1.1.1", "/sbin/route", ["-n", "get", "-inet", "1.1.1.1"]),
            ("scutil --dns", "/usr/sbin/scutil", ["--dns"]),
        ] {
            sections.append("## \(title)\n" + run(path, arguments))
        }
        if let traffic = input.traffic {
            sections.append("## traffic\n" + trafficReport(traffic, store: input.store))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Per-exit totals since Turn On, with the one-way UDP counts the dead-UDP detector
    /// flags (H3). Aggregates only — no hosts, no addresses.
    private static func trafficReport(_ traffic: TrafficSnapshot, store: Store) -> String {
        var lines = ["sampled \(ISO8601DateFormatter().string(from: traffic.sampledAt))"]
        func describe(_ label: String, _ counters: TrafficCounters) -> String {
            var line =
                "\(label): ↓ \(TrafficFormat.bytes(counters.downTotal))"
                + " ↑ \(TrafficFormat.bytes(counters.upTotal))"
                + " · \(StatusText.count(counters.connections, "connection"))"
            if counters.oneWayUDPFlows > 0 {
                line += " · \(StatusText.count(counters.oneWayUDPFlows, "one-way UDP flow"))"
            }
            return line
        }
        for (id, counters) in traffic.tunnels.sorted(by: { $0.key < $1.key }) {
            let name = store.tunnels.first { $0.id.uuidString.lowercased() == id }?.name
            lines.append(describe("\(name ?? "?") (t-\(id))", counters))
        }
        lines.append(describe("Direct", traffic.direct))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "(failed to run: \(error))"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func tail(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }
}
