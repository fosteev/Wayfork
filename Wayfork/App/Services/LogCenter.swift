import Foundation
import Observation
import WayforkCore
import os

/// In-memory ring of log lines behind the Logs window plus the on-disk mirrors
/// `wayfork.log` / `runtime.log` (docs/design/06-logging.md).
@MainActor
@Observable
final class LogCenter {
    nonisolated static let ringCapacity = 10_000
    nonisolated static let appSource = "app"
    nonisolated static let runtimeFileName = "runtime"
    nonisolated static let appFileName = "wayfork"

    nonisolated static var directory: URL {
        let base =
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/Wayfork", isDirectory: true)
    }

    /// Oldest first, at most `ringCapacity` lines (trimmed in chunks).
    private(set) var lines: [LogLine] = []
    /// Lines below this level are neither stored nor shown.
    var minimumLevel: LogLevel = .info

    private let runtimeFile: AppLogFile?
    private let appFile: AppLogFile?
    private let osLog = Logger(subsystem: WayforkIdentifiers.app, category: "app")
    /// Keys of recently received daemon lines; `subscribe` replays ring buffers and the
    /// tail loaded from `runtime.log` overlaps with them.
    private var seen: Set<LineKey> = []

    private struct LineKey: Hashable {
        let ts: Date
        let source: String
        let message: String

        init(_ line: LogLine) {
            ts = line.ts
            source = line.source
            message = line.message
        }
    }

    init() {
        let directory = LogCenter.directory
        runtimeFile = try? AppLogFile(directory: directory, name: LogCenter.runtimeFileName)
        appFile = try? AppLogFile(directory: directory, name: LogCenter.appFileName)
        if let runtimeFile {
            let tail = runtimeFile.tail(maxLines: LogCenter.ringCapacity)
            lines = tail.compactMap(LogLineFormat.parse)
            seen = Set(lines.suffix(5000).map(LineKey.init))
        }
    }

    // MARK: - App log

    func app(_ level: LogLevel, _ message: String) {
        switch level {
        case .error: osLog.error("\(message, privacy: .public)")
        case .warning: osLog.warning("\(message, privacy: .public)")
        case .info: osLog.info("\(message, privacy: .public)")
        case .debug: osLog.debug("\(message, privacy: .public)")
        }
        let line = LogLine(source: LogCenter.appSource, level: level, message: message)
        guard level <= minimumLevel else { return }
        appFile?.append(LogLineFormat.format(line))
        append([line])
    }

    // MARK: - Daemon stream

    func receive(_ batch: [LogLine]) {
        var fresh: [LogLine] = []
        fresh.reserveCapacity(batch.count)
        for line in batch where line.level <= minimumLevel {
            let key = LineKey(line)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            fresh.append(line)
            runtimeFile?.append(LogLineFormat.format(line))
        }
        if seen.count > 20_000 {
            seen = Set(lines.suffix(5000).map(LineKey.init))
        }
        append(fresh)
    }

    func clear() {
        lines.removeAll()
    }

    /// Deletes rotated files older than the retention period.
    func prune(retentionDays: Int) {
        let directory = LogCenter.directory
        for name in [LogCenter.runtimeFileName, LogCenter.appFileName] {
            AppLogFile.prune(directory: directory, name: name, retentionDays: retentionDays)
        }
    }

    private func append(_ fresh: [LogLine]) {
        guard !fresh.isEmpty else { return }
        lines.append(contentsOf: fresh)
        let overflow = lines.count - LogCenter.ringCapacity
        if overflow > 1000 {
            lines.removeFirst(overflow)
        }
    }
}
