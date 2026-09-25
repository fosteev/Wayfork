import Darwin
import Foundation

/// The app side of the control socket (docs/design/09-wayforkctl.md § Control socket):
/// a Unix socket, mode 0600, that closes connections from other users unanswered and
/// hands each request to `handler`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> Result<Data, ControlError>

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.wayfork.control")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    /// Replaces a stale socket file at `path` and starts accepting.
    public func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        unlink(path)
        guard var address = ControlSocketAddress.make(path) else {
            close(fd)
            throw ControlSocketError.pathTooLong(path)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ControlSocketError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw ControlSocketError.system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// Stops accepting and removes the socket file.
    public func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        listenFD = -1
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else {
                close(client)
                continue
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            ControlSocketIO.setTimeout(client, seconds: 5)
            let handler = handler
            DispatchQueue.global().async {
                Self.serve(client, handler: handler)
            }
        }
    }

    private static func serve(_ fd: Int32, handler: @escaping Handler) {
        guard let line = ControlSocketIO.readLine(fd, limit: ControlWire.maxRequestBytes) else {
            close(fd)
            return
        }
        let request: ControlRequest
        do {
            request = try ControlWire.decodeRequest(line)
        } catch {
            let failure = (error as? ControlError) ?? ControlError(.badRequest, "\(error)")
            ControlSocketIO.writeAll(fd, ControlWire.encodeReply(id: 0, .failure(failure)))
            close(fd)
            return
        }
        Task {
            let reply = await handler(request)
            ControlSocketIO.writeAll(fd, ControlWire.encodeReply(id: request.id, reply))
            close(fd)
        }
    }
}

/// The CLI side: one request, one reply.
public enum ControlClient {
    /// The raw reply line. Throws `ControlSocketError.notRunning` when nothing listens at
    /// `path`.
    public static func send(
        _ request: ControlRequest, path: String, timeout: Int = 30
    ) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        defer { close(fd) }
        guard var address = ControlSocketAddress.make(path) else {
            throw ControlSocketError.pathTooLong(path)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            if code == ENOENT || code == ECONNREFUSED { throw ControlSocketError.notRunning }
            throw ControlSocketError.system("connect", code)
        }
        ControlSocketIO.setTimeout(fd, seconds: timeout)
        guard ControlSocketIO.writeAll(fd, try ControlWire.encodeRequest(request)) else {
            throw ControlSocketError.system("write", errno)
        }
        guard let reply = ControlSocketIO.readLine(fd, limit: 16 * 1024 * 1024) else {
            throw ControlSocketError.noReply
        }
        return reply
    }
}

public enum ControlSocketError: Error, Equatable, CustomStringConvertible {
    case notRunning
    case noReply
    case pathTooLong(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case .notRunning:
            "no control socket: Wayfork is not running, or the running build predates F21"
        case .noReply: "no reply from Wayfork (closed or timed out)"
        case .pathTooLong(let path): "socket path too long: \(path)"
        case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
        }
    }
}

enum ControlSocketAddress {
    static func make(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}

enum ControlSocketIO {
    static func setTimeout(_ fd: Int32, seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Bytes up to (not including) the first newline; nil on EOF before it, a timeout, an
    /// error, or more than `limit` bytes.
    static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return nil }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<newline])
                return data.count <= limit ? data : nil
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return nil
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
