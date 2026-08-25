import Darwin
import Dispatch
import Foundation
import os

public struct UnixSocketLineClientHandlers: Sendable {
    public var onLine: @Sendable (String) -> Void
    public var onClose: @Sendable (Error?) -> Void

    public init(
        onLine: @escaping @Sendable (String) -> Void,
        onClose: @escaping @Sendable (Error?) -> Void
    ) {
        self.onLine = onLine
        self.onClose = onClose
    }
}

public enum UnixSocketError: Error, Sendable, Equatable {
    case pathTooLong
    case connectTimedOut(path: String)
    case connectFailed(errno: Int32)
    case closed
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
}

public final class UnixSocketLineClient: Sendable {
    private let runtime: UnixSocketLineClientRuntime

    private init(fileDescriptor: Int32, handlers: UnixSocketLineClientHandlers) {
        runtime = UnixSocketLineClientRuntime(fileDescriptor: fileDescriptor, handlers: handlers)
        runtime.start()
    }

    public static func connect(
        path: String,
        retryInterval: Duration = .milliseconds(100),
        timeout: Duration = .seconds(5),
        handlers: UnixSocketLineClientHandlers
    ) async throws -> UnixSocketLineClient {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= 103 else {
            throw UnixSocketError.pathTooLong
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            switch connectOnce(pathBytes: pathBytes) {
            case .success(let fileDescriptor):
                return UnixSocketLineClient(
                    fileDescriptor: fileDescriptor,
                    handlers: handlers
                )
            case .failure(let errorNumber):
                guard isRetryableConnectError(errorNumber) else {
                    throw UnixSocketError.connectFailed(errno: errorNumber)
                }
                guard clock.now < deadline else {
                    throw UnixSocketError.connectTimedOut(path: path)
                }
                try await Task.sleep(for: retryInterval)
            }
        }
    }

    public func send(_ line: String) throws {
        try runtime.send(line)
    }

    public func close() {
        runtime.close()
    }
}

private struct UnixSocketLineClientState {
    var isClosed = false
    var splitter = LineSplitter()
    var source: DispatchSourceRead?
}

private final class UnixSocketLineClientRuntime: Sendable {
    private let fileDescriptor: Int32
    private let handlers: UnixSocketLineClientHandlers
    private let queue = DispatchQueue(label: "com.wayfork.daemon.unix-socket-client")
    private let state = OSAllocatedUnfairLock(initialState: UnixSocketLineClientState())

    init(fileDescriptor: Int32, handlers: UnixSocketLineClientHandlers) {
        self.fileDescriptor = fileDescriptor
        self.handlers = handlers
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else {
                return
            }
            self.readAvailable(source: source)
        }
        state.withLock { $0.source = source }
        source.resume()
    }

    func send(_ line: String) throws {
        let payload = Array((line + "\n").utf8)
        try state.withLock { state in
            guard !state.isClosed else {
                throw UnixSocketError.closed
            }
            var offset = 0
            while offset < payload.count {
                let written = payload.withUnsafeBytes { bytes in
                    Darwin.write(
                        fileDescriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        payload.count - offset
                    )
                }
                if written > 0 {
                    offset += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    throw UnixSocketError.writeFailed(errno: errno)
                }
            }
        }
    }

    func close() {
        queue.async { [weak self] in
            self?.finish(error: nil)
        }
    }

    private func readAvailable(source: DispatchSourceRead) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let bytesRead = Darwin.read(fileDescriptor, &bytes, bytes.count)
        if bytesRead > 0 {
            let chunk = Array(bytes.prefix(bytesRead))
            let lines = state.withLock { state in
                state.splitter.append(chunk)
            }
            for line in lines {
                handlers.onLine(line)
            }
            return
        }
        if bytesRead == 0 {
            let leftover = state.withLock { $0.splitter.flush() }
            if let leftover {
                handlers.onLine(leftover)
            }
            finish(error: nil)
            return
        }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            return
        }
        finish(error: UnixSocketError.readFailed(errno: errno))
    }

    private func finish(error: (any Error)?) {
        let source = state.withLock { state -> DispatchSourceRead? in
            guard !state.isClosed else {
                return nil
            }
            state.isClosed = true
            return state.source
        }
        guard let source else {
            return
        }
        source.cancel()
        Darwin.close(fileDescriptor)
        handlers.onClose(error)
    }
}

private enum ConnectAttempt {
    case success(Int32)
    case failure(Int32)
}

private func connectOnce(pathBytes: [UInt8]) -> ConnectAttempt {
    let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
        return .failure(errno)
    }

    if fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) == -1 {
        let savedErrno = errno
        Darwin.close(fileDescriptor)
        return .failure(savedErrno)
    }
    var noSigPipe: Int32 = 1
    if setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    ) == -1 {
        let savedErrno = errno
        Darwin.close(fileDescriptor)
        return .failure(savedErrno)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let addressLength =
        MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
        + pathBytes.count + 1
    address.sun_len = UInt8(addressLength)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.copyBytes(from: pathBytes)
    }

    let result = withUnsafePointer(to: &address) { addressPointer in
        addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fileDescriptor, $0, socklen_t(addressLength))
        }
    }
    guard result == 0 else {
        let savedErrno = errno
        Darwin.close(fileDescriptor)
        return .failure(savedErrno)
    }
    return .success(fileDescriptor)
}

private func isRetryableConnectError(_ errorNumber: Int32) -> Bool {
    switch errorNumber {
    case ENOENT, ECONNREFUSED, EAGAIN, EINTR:
        return true
    default:
        return false
    }
}
