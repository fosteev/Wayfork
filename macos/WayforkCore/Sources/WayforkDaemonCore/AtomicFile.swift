import Darwin
import Foundation

/// Root-only files written via temp file + `rename`, so a watcher (sing-box's rule-set
/// reload) and a crash mid-write both see either the old or the new contents.
public enum AtomicFile {
    public enum Error: Swift.Error {
        case openFailed(path: String, errno: Int32)
        case writeFailed(path: String, errno: Int32)
        case renameFailed(path: String, errno: Int32)
    }

    public static func write(_ contents: String, to path: String, mode: mode_t = 0o600) throws {
        try write(Data(contents.utf8), to: path, mode: mode)
    }

    public static func write(_ data: Data, to path: String, mode: mode_t = 0o600) throws {
        let temporary = "\(path).tmp-\(getpid())"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw Error.openFailed(path: temporary, errno: errno) }
        var closed = false
        defer {
            if !closed { close(descriptor) }
        }
        _ = fchmod(descriptor, mode)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written == -1 && errno == EINTR {
                continue
            } else {
                let code = errno
                unlink(temporary)
                throw Error.writeFailed(path: temporary, errno: code)
            }
        }
        _ = fsync(descriptor)
        close(descriptor)
        closed = true
        guard rename(temporary, path) == 0 else {
            let code = errno
            unlink(temporary)
            throw Error.renameFailed(path: path, errno: code)
        }
    }
}
