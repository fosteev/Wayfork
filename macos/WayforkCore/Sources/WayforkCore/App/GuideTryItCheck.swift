import Foundation

/// Step 6 of the first-run guide, "Try it": proves each side of the model with data the
/// daemon already has (docs/design/02-ux.md, "First-run guide (F22)" › step 6). The daemon's
/// recent-hosts list only holds hosts that took the *default* route, so a site routed by a
/// rule never appears there by name — the user's sites are proven instead by the counters of
/// the exit their rules point at, and the other side by a recent host.
public struct GuideTryItCheck: Sendable {
    /// Step 4's mode: which side the chosen sites sit on.
    public enum Mode: Sendable, Hashable {
        /// "Only these sites": the sites are the tunnel's rules; everything else is direct.
        case onlyTheseSites
        /// "Everything through the tunnel, except these sites": the tunnel is default, the
        /// sites are `.direct` rules.
        case everythingExceptThese
    }

    /// How long after the Open click the download-rate fallback still counts, when no
    /// `match`/`using` log line has been seen yet.
    public static let rateFallbackWindow: TimeInterval = 20

    public var tunnelID: UUID
    public var mode: Mode
    /// The traffic snapshot taken at the moment the *Open ‹site›* button was clicked.
    public var baseline: TrafficSnapshot
    public var openedAt: Date

    public init(tunnelID: UUID, mode: Mode, baseline: TrafficSnapshot, openedAt: Date) {
        self.tunnelID = tunnelID
        self.mode = mode
        self.baseline = baseline
        self.openedAt = openedAt
    }

    public struct Result: Sendable, Equatable {
        /// The opened site left through the exit its rule names: the tunnel in mode 1,
        /// direct in mode 2.
        public var sitesProven: Bool
        /// A site not on the list, once seen, with the default route it took: direct in
        /// mode 1, the tunnel in mode 2.
        public var otherHost: String?

        public init(sitesProven: Bool, otherHost: String? = nil) {
            self.sitesProven = sitesProven
            self.otherHost = otherHost
        }
    }

    private var tunnelKey: String { tunnelID.uuidString.lowercased() }
    /// The exit the user's sites take.
    private var sitesExit: String { mode == .onlyTheseSites ? tunnelKey : "direct" }
    /// The exit everything else takes (the default route).
    private var otherExit: String { mode == .onlyTheseSites ? "direct" : tunnelKey }

    /// Evaluates a later snapshot against the baseline.
    public func evaluate(latest: TrafficSnapshot, now: Date = Date()) -> Result {
        Result(sitesProven: sitesProven(latest: latest, now: now), otherHost: otherHost(latest))
    }

    private func sitesProven(latest: TrafficSnapshot, now: Date) -> Bool {
        if let latestOpened = latest.exits[sitesExit]?.opened {
            guard let baseOpened = baseline.exits[sitesExit]?.opened else {
                return latestOpened > 0
            }
            return latestOpened > baseOpened
        }
        // No match/using line seen yet (log detail below "Problems"): fall back to the exit's
        // download rate, only within the window right after the click.
        guard now.timeIntervalSince(openedAt) <= Self.rateFallbackWindow else { return false }
        let counters =
            mode == .onlyTheseSites ? latest.counters(forTunnel: tunnelKey) : latest.direct
        return counters.downBytesPerSecond > 0
    }

    /// The first `RecentHost` seen after the baseline that took the default route (F15).
    private func otherHost(_ latest: TrafficSnapshot) -> String? {
        latest.recentHosts
            .filter { $0.exit == otherExit && $0.lastSeen > baseline.sampledAt }
            .min { $0.lastSeen < $1.lastSeen }?.host
    }
}
