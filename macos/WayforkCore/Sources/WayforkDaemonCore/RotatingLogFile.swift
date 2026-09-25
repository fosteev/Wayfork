import Darwin
import Foundation
import os

public enum RotatingLogFileError: Error, Sendable, Equatable {
    case invalidConfiguration
    case openFailed(errno: Int32)
}

public final class RotatingLogFile: Sendable {
    private let path: String
    private let maxBytes: Int
    private let maxFiles: Int
    private let state: OSAllocatedUnfairLock<RotatingLogFileState>

    public init(path: String, maxBytes: Int = 1_048_576, maxFiles: Int = 5) throws {
        guard maxBytes > 0, maxFiles > 0 else {
            throw RotatingLogFileError.invalidConfiguration
        }
        let parentDirectory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(
            atPath: parentDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(parentDirectory, 0o700) == 0 else {
            throw RotatingLogFileError.openFailed(errno: errno)
        }

        let opened = try Self.openLog(at: path)
        self.path = path
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        state = OSAllocatedUnfairLock(
            initialState: RotatingLogFileState(fileDescriptor: opened.fd, size: opened.size)
        )
    }

    public func append(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        state.withLock { state in
            guard !state.isClosed else {
                return
            }
            if state.size + bytes.count > maxBytes {
                rotate(state: &state)
            }
            guard state.fileDescriptor >= 0 else {
                return
            }

            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { buffer in
                    Darwin.write(
                        state.fileDescriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                }
                if written > 0 {
                    offset += written
                    state.size += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    public func tail(_ count: Int) -> [String] {
        guard count > 0 else {
            return []
        }
        return state.withLock { state in
            guard !state.isClosed, state.fileDescriptor >= 0 else {
                return []
            }

            var fileInfo = stat()
            guard fstat(state.fileDescriptor, &fileInfo) == 0 else {
                return []
            }
            let length = min(Int(fileInfo.st_size), 256 * 1_024)
            guard length > 0 else {
                return []
            }
            let start = Int(fileInfo.st_size) - length
            var bytes = [UInt8](repeating: 0, count: length)
            var offset = 0
            while offset < length {
                let bytesRead = bytes.withUnsafeMutableBytes { buffer in
                    pread(
                        state.fileDescriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        length - offset,
                        off_t(start + offset)
                    )
                }
                if bytesRead > 0 {
                    offset += bytesRead
                } else if bytesRead == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            bytes.removeSubrange(offset..<bytes.count)
            if start > 0, let firstNewline = bytes.firstIndex(of: 0x0A) {
                bytes.removeSubrange(...firstNewline)
            }

            var lines = String(decoding: bytes, as: UTF8.self).split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).map(String.init)
            if lines.last == "" {
                lines.removeLast()
            }
            return Array(lines.suffix(count))
        }
    }

    public func close() {
        state.withLock { state in
            guard !state.isClosed else {
                return
            }
            state.isClosed = true
            if state.fileDescriptor >= 0 {
                Darwin.close(state.fileDescriptor)
                state.fileDescriptor = -1
            }
        }
    }

    private func rotate(state: inout RotatingLogFileState) {
        if state.fileDescriptor >= 0 {
            Darwin.close(state.fileDescriptor)
            state.fileDescriptor = -1
        }

        if maxFiles == 1 {
            unlink(path)
        } else {
            unlink("\(path).\(maxFiles - 1)")
            if maxFiles > 2 {
                for index in stride(from: maxFiles - 2, through: 1, by: -1) {
                    rename("\(path).\(index)", "\(path).\(index + 1)")
                }
            }
            rename(path, "\(path).1")
        }

        guard let opened = try? Self.openLog(at: path) else {
            state.size = 0
            return
        }
        state.fileDescriptor = opened.fd
        state.size = opened.size
    }

    private static func openLog(at path: String) throws -> (fd: Int32, size: Int) {
        // O_RDWR: `tail` reads back through the same descriptor.
        let fileDescriptor = Darwin.open(path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else {
            throw RotatingLogFileError.openFailed(errno: errno)
        }
        guard fchmod(fileDescriptor, 0o600) == 0 else {
            let savedErrno = errno
            Darwin.close(fileDescriptor)
            throw RotatingLogFileError.openFailed(errno: savedErrno)
        }
        var fileInfo = stat()
        guard fstat(fileDescriptor, &fileInfo) == 0 else {
            let savedErrno = errno
            Darwin.close(fileDescriptor)
            throw RotatingLogFileError.openFailed(errno: savedErrno)
        }
        return (fileDescriptor, Int(fileInfo.st_size))
    }
}

private struct RotatingLogFileState {
    var fileDescriptor: Int32
    var size: Int
    var isClosed = false
}
