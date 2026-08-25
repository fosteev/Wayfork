import Darwin
import Foundation

/// One line of `runtime.log` / `wayfork.log`.
public enum LogLineFormat {
    /// `ISO8601DateFormatter` is documented as thread-safe; one instance for every line.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// ISO-8601 UTC with milliseconds, source, upper-cased level, message.
    public static func format(_ line: LogLine) -> String {
        let message = line.message.map { $0.isNewline ? " " : String($0) }.joined()
        return "\(formatter.string(from: line.ts)) \(line.source) "
            + "\(line.level.rawValue.uppercased()) \(message)"
    }

    /// Parses a line produced by `format`; malformed and non-canonical lines return `nil`.
    public static func parse(_ text: String) -> LogLine? {
        guard !text.isEmpty, !text.contains(where: \Character.isNewline) else {
            return nil
        }
        let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
            return nil
        }

        let timestamp = String(parts[0])
        guard let date = formatter.date(from: timestamp), formatter.string(from: date) == timestamp
        else {
            return nil
        }
        let levelText = String(parts[2])
        guard
            levelText == levelText.uppercased(),
            let level = LogLevel(rawValue: levelText.lowercased())
        else {
            return nil
        }
        return LogLine(ts: date, source: String(parts[1]), level: level, message: String(parts[3]))
    }
}

public enum AppLogFileError: Error, Sendable, Equatable {
    case invalidConfiguration
    case openFailed(errno: Int32)
}

/// Append-only app log with timestamped size rotation and age-based retention.
public final class AppLogFile: @unchecked Sendable {
    public let url: URL

    private let directory: URL
    private let name: String
    private let maxBytes: Int
    private let lock = NSLock()
    private var fileDescriptor: Int32
    private var byteCount: Int
    private var isClosed = false

    public init(directory: URL, name: String, maxBytes: Int = 5 * 1024 * 1024) throws {
        guard !name.isEmpty, maxBytes > 0 else {
            throw AppLogFileError.invalidConfiguration
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw AppLogFileError.openFailed(errno: errno)
        }

        let url = directory.appendingPathComponent("\(name).log")
        let opened = try Self.openLog(at: url.path)
        self.directory = directory
        self.name = name
        self.maxBytes = maxBytes
        self.url = url
        fileDescriptor = opened.fd
        byteCount = opened.size
    }

    deinit {
        close()
    }

    public func append(_ text: String) {
        let bytes = Array((text + "\n").utf8)
        lock.withLock {
            guard !isClosed else { return }
            if byteCount > 0, byteCount + bytes.count > maxBytes {
                rotate()
            }
            guard fileDescriptor >= 0 else { return }

            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { buffer in
                    Darwin.write(
                        fileDescriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                }
                if written > 0 {
                    offset += written
                    byteCount += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    public func tail(maxLines: Int, maxBytes: Int = 5 * 1024 * 1024) -> [String] {
        guard maxLines > 0, maxBytes > 0 else { return [] }
        return lock.withLock {
            guard !isClosed, fileDescriptor >= 0 else { return [] }

            var info = stat()
            guard fstat(fileDescriptor, &info) == 0 else { return [] }
            let length = min(Int(info.st_size), maxBytes)
            guard length > 0 else { return [] }
            let start = Int(info.st_size) - length
            var bytes = [UInt8](repeating: 0, count: length)
            var offset = 0
            while offset < length {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    pread(
                        fileDescriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        length - offset,
                        off_t(start + offset)
                    )
                }
                if count > 0 {
                    offset += count
                } else if count == -1, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            bytes.removeSubrange(offset..<bytes.count)
            if start > 0, !Self.startsAtLineBoundary(fileDescriptor: fileDescriptor, start: start) {
                guard let newline = bytes.firstIndex(of: 0x0A) else { return [] }
                bytes.removeSubrange(...newline)
            }

            var lines = String(decoding: bytes, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if lines.last == "" { lines.removeLast() }
            return Array(lines.suffix(maxLines))
        }
    }

    public func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            if fileDescriptor >= 0 {
                Darwin.close(fileDescriptor)
                fileDescriptor = -1
            }
        }
    }

    public static func rotatedFiles(directory: URL, name: String) -> [URL] {
        let prefix = "\(name)-"
        return
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ))?.filter {
                $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "log"
            }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    @discardableResult
    public static func prune(
        directory: URL,
        name: String,
        retentionDays: Int,
        now: Date = Date()
    ) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return rotatedFiles(directory: directory, name: name).filter { url in
            let shouldDelete: Bool
            if retentionDays <= 0 {
                shouldDelete = true
            } else {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                shouldDelete = values?.contentModificationDate.map { $0 < cutoff } ?? false
            }
            guard shouldDelete, (try? FileManager.default.removeItem(at: url)) != nil else {
                return false
            }
            return true
        }
    }

    private func rotate() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }

        let rotatedURL = availableRotatedURL()
        guard rename(url.path, rotatedURL.path) == 0 else {
            reopenCurrentFile()
            return
        }
        reopenCurrentFile()
    }

    private func availableRotatedURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(name)-\(formatter.string(from: Date()))"
        var candidate = directory.appendingPathComponent("\(stem).log")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix).log")
            suffix += 1
        }
        return candidate
    }

    private func reopenCurrentFile() {
        guard let opened = try? Self.openLog(at: url.path) else {
            byteCount = 0
            return
        }
        fileDescriptor = opened.fd
        byteCount = opened.size
    }

    private static func openLog(at path: String) throws -> (fd: Int32, size: Int) {
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppLogFileError.openFailed(errno: errno) }
        guard fchmod(fd, 0o600) == 0 else {
            let savedErrno = errno
            Darwin.close(fd)
            throw AppLogFileError.openFailed(errno: savedErrno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let savedErrno = errno
            Darwin.close(fd)
            throw AppLogFileError.openFailed(errno: savedErrno)
        }
        return (fd, Int(info.st_size))
    }

    private static func startsAtLineBoundary(fileDescriptor: Int32, start: Int) -> Bool {
        var previous: UInt8 = 0
        return pread(fileDescriptor, &previous, 1, off_t(start - 1)) == 1 && previous == 0x0A
    }
}
