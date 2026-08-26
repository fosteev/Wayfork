import Foundation
import SystemConfiguration
import WayforkCore
import WayforkDaemonCore

/// Makes Wayfork the system resolver while sing-box runs (F12; docs/design/05-daemon.md,
/// "System resolver override"). `ResolverOverridePlanner` decides; this actor reads and
/// writes `SCDynamicStore` and keeps `run/dns-override.json`.
actor ResolverOverride {
    static let address = SingBoxConfigGenerator.tunHostAddress

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
        let active = desired && engineRunning
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
        }
        if result != state {
            switch result {
            case .off:
                hub.post(.info, "system resolver restored")
            case .active(let service):
                hub.post(.info, "system resolver → \(Self.address) on service \(service)")
            case .shadowed(let manual):
                hub.post(
                    .warning,
                    "system resolver override shadowed by manual DNS \(manual.joined(separator: ", "))"
                )
            case .failed(let reason):
                hub.post(.error, "system resolver override failed: \(reason)")
            }
        }
        state = result
    }

    // MARK: - SCDynamicStore

    private static func stateKey(_ service: String) -> String {
        "State:/Network/Service/\(service)/DNS"
    }

    private func readSnapshot() -> ResolverSnapshot {
        guard let store,
            let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any],
            let primary = ipv4[kSCDynamicStorePropNetPrimaryService as String] as? String
        else {
            return ResolverSnapshot(primaryService: nil, stateEntry: nil)
        }
        let entry =
            SCDynamicStoreCopyValue(store, Self.stateKey(primary) as CFString) as? [String: Any]
        let setup =
            SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(primary)/DNS" as CFString)
            as? [String: Any]
        return ResolverSnapshot(
            primaryService: primary,
            stateEntry: entry.map(Self.entry(from:)),
            manualServers: (setup?[kSCPropNetDNSServerAddresses as String] as? [String]) ?? [])
    }

    private static func entry(from dictionary: [String: Any]) -> ResolverEntry {
        ResolverEntry(
            serverAddresses: dictionary[kSCPropNetDNSServerAddresses as String] as? [String] ?? [],
            searchDomains: dictionary[kSCPropNetDNSSearchDomains as String] as? [String] ?? [],
            domainName: dictionary[kSCPropNetDNSDomainName as String] as? String)
    }

    private static func dictionary(from entry: ResolverEntry) -> [String: Any] {
        var dictionary: [String: Any] = [
            kSCPropNetDNSServerAddresses as String: entry.serverAddresses
        ]
        if !entry.searchDomains.isEmpty {
            dictionary[kSCPropNetDNSSearchDomains as String] = entry.searchDomains
        }
        if let domainName = entry.domainName {
            dictionary[kSCPropNetDNSDomainName as String] = domainName
        }
        return dictionary
    }

    private func perform(_ action: ResolverOverrideAction) throws(Failure) {
        guard let store else { throw .storeUnavailable }
        switch action {
        case .write(let service, let entry, let record):
            // The record goes first: a crash right after the write must still be undoable.
            try writeRecord(record)
            let key = Self.stateKey(service)
            guard
                SCDynamicStoreSetValue(
                    store, key as CFString, Self.dictionary(from: entry) as CFDictionary)
            else { throw .writeFailed(key: key) }
        case .restore(let record):
            let key = Self.stateKey(record.service)
            let ok: Bool
            if let original = record.original {
                ok = SCDynamicStoreSetValue(
                    store, key as CFString, Self.dictionary(from: original) as CFDictionary)
            } else {
                ok = SCDynamicStoreRemoveValue(store, key as CFString)
            }
            guard ok else { throw .writeFailed(key: key) }
            unlink(env.runPath(RunLayout.resolverOverrideRecord))
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
