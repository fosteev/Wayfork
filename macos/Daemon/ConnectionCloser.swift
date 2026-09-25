import Foundation
import WayforkDaemonCore

/// Closes connections through sing-box's Clash API after a rule-set rewrite
/// (docs/design/05-daemon.md, "Connection cut on rule change").
actor ConnectionCloser {
    static let requestTimeout: TimeInterval = 2

    enum Failure: Error {
        case httpStatus(Int)
        case notHTTP
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]  // loopback only, never via a proxy
        configuration.timeoutIntervalForRequest = ConnectionCloser.requestTimeout
        configuration.timeoutIntervalForResource = ConnectionCloser.requestTimeout
        session = URLSession(configuration: configuration)
    }

    /// Closes the connections `change` covers — every connection when the change is unknown
    /// (nil) — and returns how many there were.
    func close(matching change: RuleSetSelectors?, at endpoint: ClashAPIEndpoint) async throws
        -> Int
    {
        let (data, _) = try await send("GET", endpoint.connectionsURL, endpoint)
        let connections = try ClashConnections.decode(data).connections
        guard let change else {
            _ = try await send("DELETE", endpoint.connectionsURL, endpoint)
            return connections.count
        }
        let affected = connections.filter {
            change.matches(
                host: $0.host, destinationIP: $0.destinationIP, processPath: $0.processPath)
        }
        for connection in affected {
            _ = try await send(
                "DELETE", endpoint.connectionsURL.appendingPathComponent(connection.id), endpoint)
        }
        return affected.count
    }

    private func send(_ method: String, _ url: URL, _ endpoint: ClashAPIEndpoint) async throws
        -> (Data, HTTPURLResponse)
    {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = ConnectionCloser.requestTimeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.httpStatus(http.statusCode)
        }
        return (data, http)
    }
}
