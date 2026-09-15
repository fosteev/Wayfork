import Foundation
import WayforkCore
import WayforkDaemonCore

/// Polls sing-box's Clash API once a second while it runs and pushes per-exit aggregates to
/// the subscribed client (docs/design/05-daemon.md, "Traffic sampling"). Totals survive
/// sing-box restarts (`pause` + `start`) and go back to zero on `reset` (Turn Off). The
/// latency prober (F14) runs alongside and its samples ride in every snapshot.
actor TrafficSampler {
    static let interval: Duration = .seconds(1)
    static let requestTimeout: TimeInterval = 0.9

    private enum Failure: Error {
        case httpStatus(Int)
        case notHTTP
    }

    private let hub: ClientHub
    private let prober: LatencyProber
    private let session: URLSession
    private var accumulator = TrafficAccumulator()
    /// Domains that took the default route (F15); cleared with the connection map.
    private var recent = RecentHosts()
    private var defaultExit = TrafficAccumulator.Exit.direct
    /// Groups the plan routes (F16); each is asked once a second which member it uses.
    private var routedGroups: [String] = []
    /// `Blocked N today` (F18): fed by the engine's log relay; reported only while counting.
    private var blocked = BlockCounter()
    private var blockCounting = false
    /// Connections that could not be established (F19), from the same relay.
    private var failed = FailedConnections()
    private var poll: Task<Void, Never>?
    private var generation = 0
    /// One WARNING per failure streak.
    private var failing = false
    /// Tunnels warned about one-way UDP flows; cleared when their count returns to zero,
    /// so each streak logs once (H3).
    private var oneWayWarned: Set<String> = []

    init(hub: ClientHub, prober: LatencyProber) {
        self.hub = hub
        self.prober = prober
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]  // loopback only, never via a proxy
        configuration.timeoutIntervalForRequest = TrafficSampler.requestTimeout
        configuration.timeoutIntervalForResource = TrafficSampler.requestTimeout
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration)
    }

    /// Where a flow no rule matched leaves (`route.final`); set by the supervisor per plan.
    func setDefaultExit(_ exit: TrafficAccumulator.Exit) {
        defaultExit = exit
    }

    /// Ids of the groups in the plan (`RuntimePlan.routedGroupIDs`); set per plan.
    func setRoutedGroups(_ ids: [String]) {
        routedGroups = ids
    }

    /// Whether the plan has the block list and a log level that prints its matches.
    func setBlockCounting(_ enabled: Bool) {
        blockCounting = enabled
        if !enabled { blocked.reset() }
    }

    /// One `block-ads` match in sing-box's log.
    func countBlocked() {
        blocked.record()
    }

    /// One sing-box line that may tell a connection's fate (F19).
    func observe(_ message: String, level: LogLevel) {
        failed.ingest(message, level: level)
    }

    /// sing-box is up on `endpoint`: (re)start polling; the per-connection map starts over.
    func start(_ endpoint: ClashAPIEndpoint) async {
        await pause()
        accumulator.restartConnections(at: Date())
        recent.clear()
        await prober.start(endpoint)
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
    func pause() async {
        poll?.cancel()
        poll = nil
        failing = false
        oneWayWarned = []
        await prober.pause()
    }

    /// Turn Off: stop and forget everything.
    func reset() async {
        await pause()
        accumulator.reset()
        recent.clear()
        blocked.reset()
        failed.clear()
        await prober.reset()
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
            let now = Date()
            var snapshot = accumulator.ingest(decoded.connections, at: now)
            snapshot.latency = await prober.current()
            recent.ingest(decoded.connections, defaultExit: defaultExit, at: now)
            snapshot.recentHosts = recent.snapshot
            snapshot.groups = await groupStates(endpoint)
            snapshot.blockedToday = blockCounting ? blocked.value(at: now) : nil
            snapshot.failedHosts = failed.snapshot
            guard generation == self.generation, poll != nil else { return }
            if failing {
                failing = false
                hub.post(.info, "traffic: clash api reachable again")
            }
            warnAboutOneWayUDP(snapshot)
            await hub.pushTraffic(snapshot)
        } catch {
            guard generation == self.generation, poll != nil, !failing else { return }
            failing = true
            hub.post(.warning, "traffic: clash api unreachable (\(describe(error)))")
        }
    }

    /// `GET /proxies/g-<id>` for every routed group: the member sing-box is using right now
    /// (F16). A group that does not answer gets an entry without a member.
    private func groupStates(_ endpoint: ClashAPIEndpoint) async -> [String: GroupState] {
        var states: [String: GroupState] = [:]
        for id in routedGroups {
            var request = URLRequest(
                url: endpoint.proxyURL(outboundTag: TunnelGroup.outboundTagPrefix + id))
            request.setValue("Bearer \(endpoint.secret)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = TrafficSampler.requestTimeout
            var active: String?
            if let (data, response) = try? await session.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let proxy = try? ClashProxy.decode(data)
            {
                active = proxy.now.flatMap(Tunnel.tunnelID(fromOutboundTag:))
            }
            states[id] = GroupState(activeMember: active)
        }
        return states
    }

    /// One WARNING per tunnel per streak when its one-way UDP count leaves zero — counts
    /// only, the flows' addresses stay with sing-box's own log (H3).
    private func warnAboutOneWayUDP(_ snapshot: TrafficSnapshot) {
        for (id, counters) in snapshot.tunnels {
            if counters.oneWayUDPFlows > 0 {
                guard oneWayWarned.insert(id).inserted else { continue }
                hub.post(
                    .warning,
                    "traffic: \(counters.oneWayUDPFlows) one-way udp flow(s) via t-\(id) — "
                        + "sending for \(Int(TrafficCounters.oneWayUDPGrace)) s+ with nothing "
                        + "received; the server may be dropping UDP")
            } else {
                oneWayWarned.remove(id)
            }
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
