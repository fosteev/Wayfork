import Foundation
import WayforkCore
import WayforkDaemonCore

/// Measures every connected tunnel through sing-box's Clash API delay endpoint once per
/// `LatencyProbe.interval` (docs/design/05-daemon.md, "Tunnel latency"). The results ride
/// in the traffic snapshot; `TrafficSampler` starts and pauses the prober with itself.
actor LatencyProber {
    /// Ids of the tunnels worth probing right now: routed by the plan, and for OpenVPN
    /// tunnels in the `connected` state. Set by the supervisor, which knows both.
    typealias TunnelSource = @Sendable () async -> [String]

    private enum Failure: Error {
        case httpStatus(Int)
        case notHTTP
    }

    private let hub: ClientHub
    private let session: URLSession
    private var tracker = LatencyTracker()
    private var tunnels: TunnelSource = { [] }
    private var round: Task<Void, Never>?
    private var generation = 0

    init(hub: ClientHub) {
        self.hub = hub
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]  // loopback only, never via a proxy
        // sing-box enforces the probe timeout itself; the request budget is a little wider.
        configuration.timeoutIntervalForRequest = LatencyProbe.timeout + 2
        configuration.timeoutIntervalForResource = LatencyProbe.timeout + 2
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration)
    }

    func setTunnelSource(_ source: @escaping TunnelSource) {
        tunnels = source
    }

    /// sing-box is up on `endpoint`: histories start over, the first round runs at once.
    func start(_ endpoint: ClashAPIEndpoint) {
        pause()
        tracker.clear()
        generation += 1
        let generation = generation
        round = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeRound(endpoint, generation: generation)
                try? await Task.sleep(for: .seconds(LatencyProbe.interval))
            }
        }
    }

    /// sing-box went down: stop probing; the histories are cleared on the next start.
    func pause() {
        round?.cancel()
        round = nil
    }

    /// Turn Off: stop and forget everything.
    func reset() {
        pause()
        tracker.clear()
    }

    /// Latest samples, copied into every traffic snapshot.
    func current() -> [String: LatencySample] {
        tracker.samples
    }

    /// Retry / reconnect from the card: the next round decides afresh.
    func retry(tunnel: String) {
        tracker.resetStreak(tunnel: tunnel)
    }

    private func probeRound(_ endpoint: ClashAPIEndpoint, generation: Int) async {
        let ids = await tunnels()
        tracker.retain(tunnels: Set(ids))
        for id in ids {
            guard generation == self.generation, round != nil else { return }
            let milliseconds = await probe(tunnel: id, at: endpoint)
            guard generation == self.generation, round != nil else { return }
            switch tracker.record(tunnel: id, milliseconds: milliseconds, at: Date()) {
            case .becameUnreachable(let tunnel, let failures):
                hub.post(.warning, "probe: t-\(tunnel) unreachable after \(failures) failures")
            case .recovered(let tunnel, let milliseconds):
                hub.post(.info, "probe: t-\(tunnel) reachable again (\(milliseconds) ms)")
            case nil:
                break
            }
        }
    }

    /// One request through the tunnel; nil when sing-box reports a failure or a timeout.
    private func probe(tunnel id: String, at endpoint: ClashAPIEndpoint) async -> Int? {
        let url = endpoint.delayURL(
            outboundTag: Tunnel.outboundTagPrefix + id, probeURL: LatencyProbe.url,
            timeout: LatencyProbe.timeout)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(endpoint.secret)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
            guard http.statusCode == 200 else { throw Failure.httpStatus(http.statusCode) }
            return try ClashDelay.decode(data)
        } catch {
            hub.post(.debug, "probe: t-\(id) failed (\(describe(error)))")
            return nil
        }
    }

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
