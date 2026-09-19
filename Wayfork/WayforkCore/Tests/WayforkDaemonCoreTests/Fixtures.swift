import Foundation

/// The repo-level `fixtures/` directory (see `Fixtures` in WayforkCoreTests).
enum Fixtures {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("fixtures")
    }()

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    /// Non-empty lines of a text fixture, in order (e.g. a recorded sing-box log).
    static func lines(_ relativePath: String) throws -> [String] {
        let text = try String(contentsOf: url(relativePath), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
