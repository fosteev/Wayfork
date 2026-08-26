import Foundation
import WayforkCore

/// A network service's manual DNS entry (`Setup:/Network/Service/<id>/DNS`, what
/// `networksetup -setdnsservers` writes), the parts Wayfork reasons about (F12,
/// docs/design/05-daemon.md, "System resolver override").
public struct ResolverEntry: Codable, Equatable, Sendable {
    public var serverAddresses: [String]
    public var searchDomains: [String]

    public init(serverAddresses: [String], searchDomains: [String] = []) {
        self.serverAddresses = serverAddresses
        self.searchDomains = searchDomains
    }
}

/// What the daemon sees of the resolver configuration.
public struct ResolverSnapshot: Equatable, Sendable {
    /// `PrimaryService` of `State:/Network/Global/IPv4`; nil when the network is down.
    public var primaryService: String?
    /// The primary service's manual (`Setup:`) DNS entry; nil when there is none.
    public var entry: ResolverEntry?
    /// The same entry verbatim (property list), put back as is on restore.
    public var entryRaw: Data?
    /// Search domains the network supplied (`State:` DNS, DHCP): kept while the override
    /// replaces the resolvers so that `host.lan` still resolves.
    public var networkSearchDomains: [String]

    public init(
        primaryService: String?, entry: ResolverEntry?, entryRaw: Data? = nil,
        networkSearchDomains: [String] = []
    ) {
        self.primaryService = primaryService
        self.entry = entry
        self.entryRaw = entryRaw
        self.networkSearchDomains = networkSearchDomains
    }
}

/// `run/dns-override.json`: what to put back, and where.
public struct ResolverOverrideRecord: Codable, Equatable, Sendable {
    public var service: String
    /// The manual entry before the override; nil when there was none.
    public var original: ResolverEntry?
    /// The entry verbatim, so that keys Wayfork does not model survive the round trip.
    public var originalRaw: Data?

    public init(service: String, original: ResolverEntry?, originalRaw: Data? = nil) {
        self.service = service
        self.original = original
        self.originalRaw = originalRaw
    }
}

public enum ResolverOverrideAction: Equatable, Sendable {
    /// Save `record`, then write `entry` as the service's manual DNS.
    case write(service: String, entry: ResolverEntry, record: ResolverOverrideRecord)
    /// Put the record's original back (or remove the manual entry), then delete the record.
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
        let current = snapshot.entry
        let isOurs = current?.serverAddresses == [address]
        // A foreign value (the user edited DNS in System Settings) is the new original.
        let original = isOurs ? saved?.original : current
        let originalRaw = isOurs ? saved?.originalRaw : snapshot.entryRaw
        var searchDomains = original?.searchDomains ?? []
        for domain in snapshot.networkSearchDomains where !searchDomains.contains(domain) {
            searchDomains.append(domain)
        }
        let wanted = ResolverEntry(serverAddresses: [address], searchDomains: searchDomains)
        if let saved, saved.service == service, saved.original == original, current == wanted {
            return (actions, .active(service: service))
        }
        actions.append(
            .write(
                service: service, entry: wanted,
                record: ResolverOverrideRecord(
                    service: service, original: original, originalRaw: originalRaw)))
        return (actions, .active(service: service))
    }
}
