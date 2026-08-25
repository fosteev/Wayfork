import Darwin
import Foundation
import Testing

@testable import WayforkDaemonCore

private func makeLogDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

@Test func rotatingLogFileRotatesAndCapsFileCount() throws {
    let directory = makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("source.log").path
    let log = try RotatingLogFile(path: path, maxBytes: 100, maxFiles: 3)
    let lines = (0..<5).map { "\($0)-" + String(repeating: "x", count: 58) }
    for line in lines {
        log.append(line)
    }
    log.close()

    #expect(try String(contentsOfFile: path, encoding: .utf8) == lines[4] + "\n")
    #expect(try String(contentsOfFile: path + ".1", encoding: .utf8) == lines[3] + "\n")
    #expect(try String(contentsOfFile: path + ".2", encoding: .utf8) == lines[2] + "\n")
    #expect(!FileManager.default.fileExists(atPath: path + ".3"))
}

@Test func rotatingLogFileReturnsTailOfCurrentFile() throws {
    let directory = makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("source.log").path
    let log = try RotatingLogFile(path: path)
    for index in 0..<10 {
        log.append("line-\(index)")
    }

    #expect(log.tail(3) == ["line-7", "line-8", "line-9"])
    #expect(log.tail(0).isEmpty)
    log.close()
}

@Test func rotatingLogFileSetsRestrictivePermissions() throws {
    let directory = makeLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("source.log").path
    let log = try RotatingLogFile(path: path)
    defer { log.close() }

    var directoryInfo = stat()
    var fileInfo = stat()
    #expect(stat(directory.path, &directoryInfo) == 0)
    #expect(stat(path, &fileInfo) == 0)
    #expect(directoryInfo.st_mode & 0o777 == 0o700)
    #expect(fileInfo.st_mode & 0o777 == 0o600)
}

@Test func atomicFileWriteReplacesContentsAndSetsMode() throws {
    let directory = makeLogDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("rules.json").path
    try AtomicFile.write("one", to: path)
    try AtomicFile.write("two", to: path)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "two")
    var info = stat()
    #expect(stat(path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["rules.json"])
}
