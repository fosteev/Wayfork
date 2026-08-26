import Foundation
import SystemConfiguration
import WayforkCore
import WayforkDaemonCore

/// Makes Wayfork the system resolver while sing-box runs (F12; docs/design/05-daemon.md,
/// "System resolver override"). `ResolverOverridePlanner` decides; this actor reads and
/// writes `SCDynamicStore` and keeps `run/dns-override.json`.
actor ResolverOverride {
    static let address = SingBoxConfigGenerator.resolverAddress
    static let probeName = SingBoxConfigGenerator.resolverProbeName
    /// mDNSResponder answers through the TUN well under a second; anything slower is a
    /// resolver that leads nowhere.
    static let probeTimeout: Duration = .seconds(5)

    enum Failure: Error, CustomStringConvertible {
        case storeUnavailable
        case writeFailed(key: String)
        case recordUnwritable(String)

        var description: String {
            switch self {
            case .storeUnavailable: return "SCDynamicStore unavailable"
            case .writeFailed(let key): return "cannot write \(key)"
            case .recordUnwritable(let reason): return "cannot save the resolver record: \(reason)"
            }
        }
    }

    private let env: DaemonEnvironment
    private let hub: ClientHub
    private let events: AsyncStream<SupervisorEvent>.Continuation
    private let store: SCDynamicStore?
    private var watcher: SystemDNS.Watcher?
    private var desired = false
    private var engineRunning = false
    /// Why the override is held off until sing-box restarts: the probe found that the
    /// system resolver does not reach the TUN (2026-08-26: the TUN's own address never did).
    private var blocked: String?
    private var probe: Task<Void, Never>?
    private var state = ResolverOverrideState.off {
        didSet { if state != oldValue { events.yield(.resolverOverride(state)) } }
    }

    init(env: DaemonEnvironment, hub: ClientHub, events: AsyncStream<SupervisorEvent>.Continuation)
    {
        self.env = env
        self.hub = hub
        self.events = events
        store = SCDynamicStoreCreate(nil, "WayforkDaemon" as CFString, nil, nil)
    }

    /// The plan's wish (`RuntimePlan.overrideSystemDNS`).
    func setDesired(_ on: Bool) {
        desired = on
        reconcile()
    }

    /// Follows the engine: the override is in place only while sing-box runs.
    func setEngineRunning(_ running: Bool) {
        if running != engineRunning { blocked = nil }  // a new sing-box deserves a new try
        engineRunning = running
        reconcile()
    }

    /// Bootstrap: put back whatever a previous daemon left overridden.
    func restoreLeftover() {
        guard let record = readRecord() else { return }
        hub.post(
            .warning, "system resolver left overridden on service \(record.service); restoring")
        do {
            try perform(.restore(record))
        } catch {
            hub.post(.error, "system resolver: \(error)")
        }
    }

    private func reconcile() {
        let active = desired && engineRunning && blocked == nil
        let (actions, planned) = ResolverOverridePlanner.plan(
            active: active, snapshot: readSnapshot(), saved: readRecord(), address: Self.address)
        var result = planned
        for action in actions {
            do {
                try perform(action)
            } catch {
                hub.post(.error, "system resolver: \(error)")
                result = .failed(reason: "\(error)")
                break
            }
        }
        if active {
            startWatching()
        } else {
            watcher = nil
            probe?.cancel()
            probe = nil
        }
        if let blocked, !active, desired, engineRunning {
            result = .failed(reason: blocked)
        }
        if case .active = result, probe == nil, state != result {
            startProbe()
        }
        if result != state {
            switch result {
            case .off:
                hub.post(.info, "system resolver restored")
            case .active(let service):
                hub.post(.info, "system resolver → \(Self.address) on service \(service)")
            case .shadowed(let manual):  // not produced since the move to `Setup:`
                hub.post(
                    .warning,
                    "system resolver override shadowed by \(manual.joined(separator: ", "))")
            case .failed(let reason):
                hub.post(.error, "system resolver override failed: \(reason)")
            }
        }
        state = result
    }

    // MARK: - Probe

    /// Resolves `probe.wayfork.internal` through the system resolver (getaddrinfo →
    /// mDNSResponder → the TUN → sing-box's `predefined` answer). No answer within
    /// `probeTimeout` → the override is backed out until sing-box restarts.
    private func startProbe() {
        probe = Task { [weak self] in
            let answered = await ResolverProbe.resolves(
                ResolverOverride.probeName, within: ResolverOverride.probeTimeout)
            guard !Task.isCancelled, let self else { return }
            await self.probed(answered)
        }
    }

    private func probed(_ answered: Bool) {
        probe = nil
        if answered {
            hub.post(.info, "system resolver verified: \(Self.probeName) answered through the TUN")
            return
        }
        blocked =
            "\(Self.probeName) got no answer through \(Self.address) within \(Self.probeTimeout)"
        hub.post(.error, "system resolver override backed out: \(blocked ?? "")")
        reconcile()
    }

    // MARK: - SCDynamicStore / SCPreferences

    /// The manual DNS goes into `Setup:` (what `networksetup -setdnsservers` writes):
    /// a resolver published from `State:` carries the service interface's `if_index` and
    /// mDNSResponder then sends every query out of that interface — to the LAN router,
    /// never into the TUN (2026-08-26, `scutil --dns`: `if_index : 14 (en0)` from `State:`,
    /// none from `Setup:`; the probe answered only for the latter).
    private static func preferencesPath(_ service: String) -> String {
        "/NetworkServices/\(service)/DNS"
    }

    private func readSnapshot() -> ResolverSnapshot {
        guard let store,
            let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any],
            let primary = ipv4[kSCDynamicStorePropNetPrimaryService as String] as? String
        else {
            return ResolverSnapshot(primaryService: nil, entry: nil)
        }
        var entry: ResolverEntry?
        var raw: Data?
        if let prefs = SCPreferencesCreate(nil, "WayforkDaemon" as CFString, nil),
            let dictionary = SCPreferencesPathGetValue(
                prefs, Self.preferencesPath(primary) as CFString) as? [String: Any]
        {
            entry = Self.entry(from: dictionary)
            raw = try? PropertyListSerialization.data(
                fromPropertyList: dictionary, format: .binary, options: 0)
        }
        var network: [String] = []
        if let state = SCDynamicStoreCopyValue(
            store, "State:/Network/Service/\(primary)/DNS" as CFString) as? [String: Any]
        {
            network = state[kSCPropNetDNSSearchDomains as String] as? [String] ?? []
            if let domain = state[kSCPropNetDNSDomainName as String] as? String,
                !network.contains(domain)
            {
                network.append(domain)
            }
        }
        return ResolverSnapshot(
            primaryService: primary, entry: entry, entryRaw: raw, networkSearchDomains: network)
    }

    private static func entry(from dictionary: [String: Any]) -> ResolverEntry {
        ResolverEntry(
            serverAddresses: dictionary[kSCPropNetDNSServerAddresses as String] as? [String] ?? [],
            searchDomains: dictionary[kSCPropNetDNSSearchDomains as String] as? [String] ?? [])
    }

    private static func dictionary(from entry: ResolverEntry) -> [String: Any] {
        var dictionary: [String: Any] = [
            kSCPropNetDNSServerAddresses as String: entry.serverAddresses
        ]
        if !entry.searchDomains.isEmpty {
            dictionary[kSCPropNetDNSSearchDomains as String] = entry.searchDomains
        }
        return dictionary
    }

    private func perform(_ action: ResolverOverrideAction) throws(Failure) {
        switch action {
        case .write(let service, let entry, let record):
            // The record goes first: a crash right after the write must still be undoable.
            try writeRecord(record)
            try writePreferences(service: service, value: Self.dictionary(from: entry))
        case .restore(let record):
            var value: Any?
            if let raw = record.originalRaw {
                value = try? PropertyListSerialization.propertyList(from: raw, format: nil)
            } else if let original = record.original {
                value = Self.dictionary(from: original)
            }
            try writePreferences(service: record.service, value: value)
            unlink(env.runPath(RunLayout.resolverOverrideRecord))
        }
    }

    /// Commits and applies `value` (nil removes the manual entry) as the service's DNS.
    private func writePreferences(service: String, value: Any?) throws(Failure) {
        let key = Self.preferencesPath(service)
        guard let prefs = SCPreferencesCreate(nil, "WayforkDaemon" as CFString, nil) else {
            throw .storeUnavailable
        }
        guard SCPreferencesLock(prefs, true) else { throw .writeFailed(key: key) }
        defer { SCPreferencesUnlock(prefs) }
        // No manual entry = an empty DNS dictionary, which is what `networksetup
        // -setdnsservers <service> empty` leaves behind.
        let dictionary = (value as? [String: Any]) ?? [:]
        let set = SCPreferencesPathSetValue(prefs, key as CFString, dictionary as CFDictionary)
        guard set, SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw .writeFailed(key: key)
        }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        watcher = SystemDNS.Watcher(queue: DispatchQueue(label: "com.wayfork.daemon.resolver")) {
            [weak self] in
            guard let self else { return }
            Task { await self.changed() }
        }
    }

    private func changed() {
        guard desired && engineRunning else { return }
        reconcile()
    }

    // MARK: - Record

    private var recordPath: String { env.runPath(RunLayout.resolverOverrideRecord) }

    private func readRecord() -> ResolverOverrideRecord? {
        guard let data = FileManager.default.contents(atPath: recordPath) else { return nil }
        return try? JSONDecoder().decode(ResolverOverrideRecord.self, from: data)
    }

    private func writeRecord(_ record: ResolverOverrideRecord) throws(Failure) {
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw .recordUnwritable("\(error)")
        }
        guard
            FileManager.default.createFile(
                atPath: recordPath, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw .recordUnwritable(recordPath) }
    }
}

/// `getaddrinfo`, repeated until it answers or the deadline passes. One lookup is not
/// enough: mDNSResponder takes a moment to pick up the new `Setup:` entry, and until then
/// the *old* resolver answers — the LAN router returns NODATA for the probe name in
/// milliseconds, which a single call took for "no answer" and backed the override out
/// right after every activation (2026-08-26). The lookup blocks for up to 30 s when the
/// resolver is dead, so it runs on a plain dispatch thread — never on the cooperative
/// pool, whose width in a launchd daemon is small enough that one blocked thread stalled
/// every actor for the full 30 s (2026-08-26). A lookup lingering past the deadline is
/// harmless.
enum ResolverProbe {
    static let retryInterval: Duration = .milliseconds(300)

    static func resolves(_ host: String, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if await lookup(host) { return true }
                    guard (try? await Task.sleep(for: retryInterval)) != nil else { break }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func lookup(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: lookupBlocking(host))
            }
        }
    }

    private static func lookupBlocking(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &result)
        if let result { freeaddrinfo(result) }
        return code == 0
    }
}
