import Foundation
import WayforkCore
import WayforkDaemonCore

/// Polls sing-box's Clash API once a second while it runs and pushes per-exit aggregates to
/// the subscribed client (docs/design/05-daemon.md, "Traffic sampling"). Totals survive
/// sing-box restarts (`pause` + `start`) and go back to zero on `reset` (Turn Off).
actor TrafficSampler {
    static let interval: Duration = .seconds(1)
    static let requestTimeout: TimeInterval = 0.9

    private enum Failure: Error {
        case httpStatus(Int)
        case notHTTP
    }

    private let hub: ClientHub
    private let session: URLSession
    private var accumulator = TrafficAccumulator()
    private var poll: Task<Void, Never>?
    private var generation = 0
    /// One WARNING per failure streak.
    private var failing = false

    init(hub: ClientHub) {
        self.hub = hub
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]  // loopback only, never via a proxy
        configuration.timeoutIntervalForRequest = TrafficSampler.requestTimeout
        configuration.timeoutIntervalForResource = TrafficSampler.requestTimeout
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration)
    }

    /// sing-box is up on `endpoint`: (re)start polling; the per-connection map starts over.
    func start(_ endpoint: ClashAPIEndpoint) {
        pause()
        accumulator.restartConnections(at: Date())
        generation += 1
        let generation = generation
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: TrafficSampler.interval)
                guard !Task.isCancelled, let self else { return }
                await self.sample(endpoint, generation: generation)
            }
        }
    }

    /// sing-box went down: stop polling, keep the totals.
    func pause() {
        poll?.cancel()
        poll = nil
        failing = false
    }

    /// Turn Off: stop and forget everything.
    func reset() {
        pause()
        accumulator.reset()
    }

    private func sample(_ endpoint: ClashAPIEndpoint, generation: Int) async {
        var request = URLRequest(url: endpoint.connectionsURL)
        request.setValue("Bearer \(endpoint.secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = TrafficSampler.requestTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
            guard http.statusCode == 200 else { throw Failure.httpStatus(http.statusCode) }
            let decoded = try ClashConnections.decode(data)
            // Paused or restarted while the request was in flight: drop the sample.
            guard generation == self.generation, poll != nil else { return }
            let snapshot = accumulator.ingest(decoded.connections, at: Date())
            if failing {
                failing = false
                hub.post(.info, "traffic: clash api reachable again")
            }
            await hub.pushTraffic(snapshot)
        } catch {
            guard generation == self.generation, poll != nil, !failing else { return }
            failing = true
            hub.post(.warning, "traffic: clash api unreachable (\(describe(error)))")
        }
    }

    /// Short, secret-free description (URLError texts carry the URL, which has no secret).
    private func describe(_ error: any Error) -> String {
        switch error {
        case Failure.httpStatus(let code): "http \(code)"
        case Failure.notHTTP: "not an http response"
        case let urlError as URLError: "\(urlError.code.rawValue) \(urlError.localizedDescription)"
        case is DecodingError: "undecodable response"
        default: "\(error)"
        }
    }
}
