import Foundation

/// Loads and saves `store.json` (docs/design/01-data-model.md, "Persistence"): atomic
/// writes debounced after the last change, corrupt files moved aside, newer schemas refused.
public actor StoreRepository {
    public static let fileName = "store.json"

    public struct LoadResult: Sendable, Equatable {
        public var store: Store
        /// Set when the previous file was unreadable and has been renamed to this path
        /// (`store.corrupt` in the UI).
        public var corruptBackup: URL?
    }

    public enum Error: Swift.Error {
        case newerSchema(found: Int, supported: Int)
    }

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(StoreRepository.fileName) }

    private let debounce: Duration
    private var pending: Store?
    private var flushTask: Task<Void, Never>?
    private let fileManager = FileManager.default

    /// - Parameter directory: `~/Library/Application Support/Wayfork` in the app.
    public init(directory: URL, debounce: Duration = .milliseconds(300)) {
        self.directory = directory
        self.debounce = debounce
    }

    public static func defaultDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support")
        return base.appendingPathComponent("Wayfork", isDirectory: true)
    }

    /// Missing file → empty store. Corrupt file → renamed to `store.json.corrupt-<timestamp>`,
    /// empty store plus `corruptBackup`. Newer schema → `Error.newerSchema` (never touched).
    public func load() throws -> LoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return LoadResult(store: .empty, corruptBackup: nil)
        }
        let data = try Data(contentsOf: fileURL)
        do {
            return LoadResult(store: try StoreCodec.decode(data), corruptBackup: nil)
        } catch StoreCodec.Error.newerSchema(let found, let supported) {
            throw Error.newerSchema(found: found, supported: supported)
        } catch {
            let backup = directory.appendingPathComponent(
                "\(StoreRepository.fileName).corrupt-\(Self.timestamp())")
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: fileURL, to: backup)
            return LoadResult(store: .empty, corruptBackup: backup)
        }
    }

    /// Schedules a write; consecutive calls within the debounce window collapse into one.
    public func save(_ store: Store) {
        pending = store
        flushTask?.cancel()
        let delay = debounce
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            try? await self?.flush()
        }
    }

    /// Writes the pending store now, if any.
    public func flush() throws {
        flushTask?.cancel()
        flushTask = nil
        guard let store = pending else { return }
        try write(store)
        pending = nil
    }

    /// Writes immediately, bypassing the debounce.
    public func write(_ store: Store) throws {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try StoreCodec.encode(store)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        pending = nil
    }

    public var hasPendingChanges: Bool { pending != nil }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
