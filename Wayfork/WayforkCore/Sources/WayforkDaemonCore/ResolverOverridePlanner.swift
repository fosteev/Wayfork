import Foundation
import WayforkCore

/// A network service's DNS entry (`State:/Network/Service/<id>/DNS`), the parts Wayfork
/// preserves across the override (F12, docs/design/05-daemon.md, "System resolver
/// override").
public struct ResolverEntry: Codable, Equatable, Sendable {
    public var serverAddresses: [String]
    public var searchDomains: [String]
    public var domainName: String?

    public init(serverAddresses: [String], searchDomains: [String] = [], domainName: String? = nil)
    {
        self.serverAddresses = serverAddresses
        self.searchDomains = searchDomains
        self.domainName = domainName
    }
}

/// What the daemon sees of the resolver configuration.
public struct ResolverSnapshot: Equatable, Sendable {
    /// `PrimaryService` of `State:/Network/Global/IPv4`; nil when the network is down.
    public var primaryService: String?
    /// The primary service's `State:` DNS entry; nil when the key is absent.
    public var stateEntry: ResolverEntry?
    /// `ServerAddresses` of the primary service's `Setup:` entry (manual DNS in System
    /// Settings), which configd prefers over `State:`.
    public var manualServers: [String]

    public init(primaryService: String?, stateEntry: ResolverEntry?, manualServers: [String] = []) {
        self.primaryService = primaryService
        self.stateEntry = stateEntry
        self.manualServers = manualServers
    }
}

/// `run/dns-override.json`: what to put back, and where.
public struct ResolverOverrideRecord: Codable, Equatable, Sendable {
    public var service: String
    /// The entry before the override; nil when the key did not exist.
    public var original: ResolverEntry?

    public init(service: String, original: ResolverEntry?) {
        self.service = service
        self.original = original
    }
}

public enum ResolverOverrideAction: Equatable, Sendable {
    /// Save `record`, then write `entry` to the service's `State:` DNS key.
    case write(service: String, entry: ResolverEntry, record: ResolverOverrideRecord)
    /// Put the record's original back (or remove the key), then delete the record.
    case restore(ResolverOverrideRecord)
}

/// Decides what the daemon does with the system resolver; the actor performs it.
public enum ResolverOverridePlanner {
    public static func plan(
        active: Bool, snapshot: ResolverSnapshot, saved: ResolverOverrideRecord?, address: String
    ) -> (actions: [ResolverOverrideAction], state: ResolverOverrideState) {
        guard active else {
            return (saved.map { [.restore($0)] } ?? [], .off)
        }
        guard let service = snapshot.primaryService else {
            return (
                saved.map { [.restore($0)] } ?? [], .failed(reason: "no primary network service")
            )
        }
        var actions: [ResolverOverrideAction] = []
        var saved = saved
        if let record = saved, record.service != service {
            // The primary service moved (Wi-Fi → Ethernet): free the old one first.
            actions.append(.restore(record))
            saved = nil
        }
        let current = snapshot.stateEntry
        let isOurs = current?.serverAddresses == [address]
        // A foreign value (configd rewrote the key after a DHCP renew) is the new original.
        let original = isOurs ? saved?.original : current
        let wanted = ResolverEntry(
            serverAddresses: [address],
            searchDomains: original?.searchDomains ?? [],
            domainName: original?.domainName)
        let state: ResolverOverrideState =
            snapshot.manualServers.isEmpty
            ? .active(service: service) : .shadowed(manual: snapshot.manualServers)
        if let saved, saved.service == service, saved.original == original, current == wanted {
            return (actions, state)
        }
        actions.append(
            .write(
                service: service, entry: wanted,
                record: ResolverOverrideRecord(service: service, original: original)))
        return (actions, state)
    }
}
