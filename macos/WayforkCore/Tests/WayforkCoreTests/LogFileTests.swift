import Darwin
import Foundation
import Testing

@testable import WayforkCore

private func makeLogDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func referenceDate() -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(
        from: DateComponents(
            year: 2026,
            month: 8,
            day: 25,
            hour: 12,
            minute: 0,
            second: 0,
            nanosecond: 123_000_000
        ))!
}

@Test func logLineFormatFormatsAndParses() throws {
    let line = LogLine(ts: referenceDate(), source: "sing-box", level: .info, message: "message")
    let text = LogLineFormat.format(line)
    #expect(text == "2026-08-25T12:00:00.123Z sing-box INFO message")

    let parsed = try #require(LogLineFormat.parse(text))
    #expect(
        Int(parsed.ts.timeIntervalSince1970 * 1_000) == Int(line.ts.timeIntervalSince1970 * 1_000))
    #expect(parsed.source == line.source)
    #expect(parsed.level == line.level)
    #expect(parsed.message == line.message)

    let spaced = LogLine(
        ts: referenceDate(),
        source: "openvpn:3f2a…",
        level: .warning,
        message: "message with spaces"
    )
    let parsedSpaced = try #require(LogLineFormat.parse(LogLineFormat.format(spaced)))
    #expect(parsedSpaced.source == spaced.source)
    #expect(parsedSpaced.level == spaced.level)
    #expect(parsedSpaced.message == spaced.message)
}

@Test func logLineFormatRejectsMalformedLines() {
    #expect(LogLineFormat.parse("") == nil)
    #expect(LogLineFormat.parse("garbage") == nil)
    #expect(LogLineFormat.parse("2026-08-25T12:00:00.123Z sing-box TRACE message") == nil)
}

@Test func appLogFileRotatesWithoutLosingLines() throws {
    let directory = makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try AppLogFile(directory: directory, name: "runtime", maxBytes: 100)
    let lines = (0..<5).map { "\($0)-" + String(repeating: "x", count: 58) }
    for line in lines { log.append(line) }
    log.close()

    let current = try String(contentsOf: log.url, encoding: .utf8)
    #expect(current == lines.last! + "\n")
    let rotated = AppLogFile.rotatedFiles(directory: directory, name: "runtime")
    #expect(!rotated.isEmpty)
    let urls = rotated + [log.url]
    let storedLines = try urls.flatMap { url in
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }
    #expect(storedLines.sorted() == lines.sorted())
}

@Test func appLogFileReturnsTailOldestFirst() throws {
    let directory = makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try AppLogFile(directory: directory, name: "runtime")
    defer { log.close() }
    for index in 0..<10 { log.append("line-\(index)") }

    #expect(log.tail(maxLines: 3) == ["line-7", "line-8", "line-9"])
    #expect(log.tail(maxLines: 0).isEmpty)
}

@Test func appLogFilePrunesOnlyExpiredRotations() throws {
    let directory = makeLogDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let current = directory.appendingPathComponent("runtime.log")
    let old = directory.appendingPathComponent("runtime-20260815-120000.log")
    let recent = directory.appendingPathComponent("runtime-20260824-120000.log")
    for url in [current, old, recent] {
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    }
    let now = referenceDate()
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-10 * 86_400)],
        ofItemAtPath: old.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-86_400)],
        ofItemAtPath: recent.path
    )

    let deleted = AppLogFile.prune(
        directory: directory, name: "runtime", retentionDays: 7, now: now)
    #expect(deleted.map(\.lastPathComponent) == [old.lastPathComponent])
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(FileManager.default.fileExists(atPath: current.path))
}

@Test func appLogFileSetsRestrictivePermissions() throws {
    let directory = makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try AppLogFile(directory: directory, name: "runtime")
    defer { log.close() }

    var directoryInfo = stat()
    var fileInfo = stat()
    #expect(stat(directory.path, &directoryInfo) == 0)
    #expect(stat(log.url.path, &fileInfo) == 0)
    #expect(directoryInfo.st_mode & 0o777 == 0o700)
    #expect(fileInfo.st_mode & 0o777 == 0o600)
}
