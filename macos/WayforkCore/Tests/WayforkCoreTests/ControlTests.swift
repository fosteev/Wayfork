import Foundation
import Testing

@testable import WayforkCore

// F21 (docs/design/09-wayforkctl.md): log filters, reversible edits, the control socket.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func line(
    _ offset: TimeInterval, _ source: String, _ level: LogLevel, _ message: String
) -> LogLine {
    LogLine(ts: t0.addingTimeInterval(offset), source: source, level: level, message: message)
}

@Suite struct LogQueryTests {
    @Test func filtersBySourceLevelGrepAndSince() {
        let lines = [
            line(0, "sing-box", .info, "inbound connection to example.com:443"),
            line(1, "openvpn:abc", .warning, "TLS handshake failed"),
            line(2, "daemon", .error, "sing-box exited"),
            line(3, "sing-box", .debug, "dns: exchanged example.com"),
            line(4, "app", .info, "apply: plan 1234"),
        ]
        #expect(LogQuery(sources: ["openvpn"]).run([lines]).map(\.source) == ["openvpn:abc"])
        #expect(LogQuery(level: .warning).run([lines]).count == 2)
        #expect(LogQuery(grep: ["EXAMPLE", "dns"]).run([lines]).count == 1)
        #expect(LogQuery(since: t0.addingTimeInterval(2)).run([lines]).count == 3)
        #expect(LogQuery(sources: ["SING-BOX", "app"]).run([lines]).count == 3)
    }

    @Test func mergesStreamsByTimeAndKeepsTheTail() {
        let runtime = [line(0, "sing-box", .info, "a"), line(2, "sing-box", .info, "c")]
        let app = [line(1, "app", .info, "b"), line(2, "app", .info, "d")]
        let all = LogQuery(tail: 0).run([runtime, app]).map(\.message)
        #expect(all == ["a", "b", "c", "d"])
        #expect(LogQuery(tail: 2).run([runtime, app]).map(\.message) == ["c", "d"])
    }

    @Test func parsesSince() {
        #expect(LogQuery.parseSince("90s", now: t0) == t0.addingTimeInterval(-90))
        #expect(LogQuery.parseSince("15m", now: t0) == t0.addingTimeInterval(-900))
        #expect(LogQuery.parseSince("2h", now: t0) == t0.addingTimeInterval(-7200))
        #expect(LogQuery.parseSince("1d", now: t0) == t0.addingTimeInterval(-86_400))
        #expect(LogQuery.parseSince("2026-09-25T10:00:00Z") != nil)
        #expect(LogQuery.parseSince("2026-09-25T10:00:00.250Z") != nil)
        #expect(LogQuery.parseSince("soon") == nil)
        #expect(LogQuery.parseSince("5w") == nil)
    }

    @Test func archiveReadsRotatedFilesOnlyWhenNeeded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ lines: [LogLine]) throws {
            let text = lines.map(LogLineFormat.format).joined(separator: "\n") + "\n"
            try text.write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("runtime-20260101-000000.log", [line(0, "sing-box", .info, "old")])
        try write(
            "runtime.log",
            [line(10, "sing-box", .info, "new1"), line(11, "sing-box", .info, "new2")])

        let tail = LogArchive.lines(directory: directory, name: "runtime", query: LogQuery(tail: 2))
        #expect(tail.map(\.message) == ["new1", "new2"])
        let all = LogArchive.lines(directory: directory, name: "runtime", query: LogQuery(tail: 0))
        #expect(all.map(\.message) == ["old", "new1", "new2"])
        let recent = LogArchive.lines(
            directory: directory, name: "runtime",
            query: LogQuery(since: t0.addingTimeInterval(5), tail: 0))
        #expect(recent.map(\.message) == ["new1", "new2"])
        let missing = LogArchive.lines(directory: directory, name: "wayfork", query: LogQuery())
        #expect(missing.isEmpty)
    }

    @Test func redactsWholeServerTokensOnly() {
        let redactor = LogRedactor(servers: ["vpn.example.com", "203.0.113.7", "example.com"])
        let (text, count) = redactor.redact(
            "dial VPN.example.com:443 via 203.0.113.7; not 203.0.113.70 or my.example.com.org; example.com."
        )
        #expect(
            text
                == "dial server-1:443 via server-2; not 203.0.113.70 or my.example.com.org; server-3."
        )
        #expect(count == 3)
        #expect(LogRedactor(servers: []).redact("x") == ("x", 0))
    }
}

@Suite struct StoreEditTests {
    private func store() -> Store {
        var store = Store.empty
        let work = UUID()
        store.rules = [
            Rule(pattern: "a.com", target: .tunnel(work)),
            Rule(pattern: "b.com", target: .direct),
            Rule(pattern: "c.com", target: .tunnel(work)),
        ]
        return store
    }

    @Test func removeAndItsInverseRestoreThePosition() {
        var store = store()
        let original = store
        let edit = StoreEdit.removal(of: store.rules[0], in: store)
        #expect(edit == .removeRule(store.rules[0], before: store.rules[2].id))
        #expect(edit.apply(to: &store) == nil)
        #expect(store.rules.map(\.pattern) == ["b.com", "c.com"])
        #expect(edit.inverse.apply(to: &store) == nil)
        // Back in its place within its group; the array order across groups is irrelevant.
        #expect(store.effectiveRules == original.effectiveRules)
    }

    @Test func insertGoesToTheGroupEndAndInverseRemovesIt() {
        var store = store()
        let original = store
        let rule = Rule(pattern: "d.com", target: store.rules[0].target)
        let edit = StoreEdit.insertRule(rule, before: nil)
        #expect(edit.apply(to: &store) == nil)
        #expect(store.rules.map(\.pattern) == ["a.com", "b.com", "c.com", "d.com"])
        #expect(edit.apply(to: &store) != nil)
        #expect(edit.inverse.apply(to: &store) == nil)
        #expect(store == original)
    }

    @Test func inverseSkipsWhatTheGUIChanged() {
        var store = store()
        let rule = Rule(pattern: "d.com", target: .direct)
        let edit = StoreEdit.insertRule(rule, before: nil)
        edit.apply(to: &store)
        let index = store.rules.firstIndex { $0.id == rule.id }!
        store.rules[index].isEnabled = false
        let before = store
        #expect(edit.inverse.apply(to: &store) == "rule d.com was changed since")
        #expect(store == before)
    }

    @Test func replaceAndLogLevelInvert() {
        var store = store()
        let from = store.rules[1]
        var to = from
        to.target = store.rules[0].target
        let edit = StoreEdit.replaceRule(from: from, to: to)
        #expect(edit.apply(to: &store) == nil)
        #expect(edit.inverse.apply(to: &store) == nil)
        #expect(store.rules[1] == from)

        let level = StoreEdit.setLogLevel(from: store.settings.logLevel, to: .debug)
        let old = store.settings.logLevel
        #expect(level.apply(to: &store) == nil)
        #expect(store.settings.logLevel == .debug)
        #expect(level.inverse.apply(to: &store) == nil)
        #expect(store.settings.logLevel == old)
    }

    @Test func pendingChangeRoundTrips() throws {
        let pending = PendingControlChange(
            edit: .insertRule(Rule(pattern: "x.com", target: .direct), before: UUID()),
            description: "add x.com → direct", deadline: t0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            PendingControlChange.self, from: encoder.encode(pending))
        #expect(decoded == pending)
    }

    @Test func deadlineBounds() throws {
        #expect(try ControlDeadline.seconds(nil) == 60)
        #expect(try ControlDeadline.seconds(0) == nil)
        #expect(try ControlDeadline.seconds(600) == 600)
        #expect(throws: ControlError.self) { try ControlDeadline.seconds(5) }
        #expect(throws: ControlError.self) { try ControlDeadline.seconds(601) }
    }
}

@Suite struct ControlSocketTests {
    private func socketPath() -> String {
        "/tmp/wf-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func roundTripAndErrors() async throws {
        let path = socketPath()
        let server = ControlServer(path: path) { request in
            switch request.method {
            case .status:
                return ControlWire.encodeResult(["pattern": request.params.pattern ?? "-"])
            default:
                return .failure(ControlError(.notFound, "no such thing"))
            }
        }
        try server.start()
        defer { server.stop() }

        var attributes = stat()
        #expect(stat(path, &attributes) == 0)
        #expect(attributes.st_mode & 0o777 == 0o600)

        let reply = try await Task.detached {
            try ControlClient.send(
                ControlRequest(id: 7, method: .status, params: ControlParams(pattern: "x")),
                path: path)
        }.value
        guard case .success(let result) = try ControlWire.decodeReply(reply) else {
            Issue.record("expected a result")
            return
        }
        #expect((result as? [String: String]) == ["pattern": "x"])

        let failure = try await Task.detached {
            try ControlClient.send(ControlRequest(method: .failed), path: path)
        }.value
        guard case .failure(let error) = try ControlWire.decodeReply(failure) else {
            Issue.record("expected an error")
            return
        }
        #expect(error == ControlError(.notFound, "no such thing"))
    }

    @Test func notRunningIsItsOwnError() {
        #expect(throws: ControlSocketError.notRunning) {
            try ControlClient.send(ControlRequest(method: .status), path: socketPath())
        }
    }

    @Test func stopRemovesTheSocket() throws {
        let path = socketPath()
        let server = ControlServer(path: path) { _ in .success(Data("null".utf8)) }
        try server.start()
        server.stop()
        #expect(access(path, F_OK) != 0)
    }
}
