import Foundation
import Testing

@testable import WayforkCore

private func openVPNTunnel(_ name: String, slot: Int, enabled: Bool = true) -> Tunnel {
    Tunnel(
        name: name, isEnabled: enabled, slot: slot,
        kind: .openVPN(
            OpenVPNMeta(
                remotes: [Remote(host: "vpn.example.com", port: 1194, proto: "udp")],
                needsCredentials: true, needsKeyPassphrase: false, configHash: "abc")))
}

private func vlessTunnel(_ name: String, slot: Int, enabled: Bool = true) -> Tunnel {
    Tunnel(
        name: name, isEnabled: enabled, slot: slot,
        kind: .vless(
            VLESSMeta(
                server: "host.example.com", port: 443, flow: "xtls-rprx-vision",
                security: .reality, sni: "cdn.example.com", fingerprint: "chrome")))
}

private func sampleStore() -> (Store, work: Tunnel, home: Tunnel, lab: Tunnel) {
    let work = openVPNTunnel("Work", slot: 0)
    let home = vlessTunnel("Home", slot: 1)
    let lab = openVPNTunnel("Lab", slot: 2)
    var store = Store(tunnels: [work, home, lab])
    store.rules = [
        Rule(pattern: "example.com", tunnelID: work.id),
        Rule(pattern: "api.internal.example.com", match: .exact, tunnelID: work.id),
        Rule(pattern: "old.example.com", match: .exact, tunnelID: work.id, isEnabled: false),
        Rule(pattern: "*.cdn.example.com", match: .wildcard, tunnelID: home.id),
        Rule(pattern: "news.example.org", tunnelID: home.id),
        Rule(pattern: "docs.example.net", tunnelID: lab.id),
    ]
    return (store, work, home, lab)
}

private func key(_ tunnel: Tunnel) -> String { tunnel.id.uuidString.lowercased() }

// MARK: - Global state

@Test func globalStateOffWithoutStatusOrTransition() {
    let (store, _, _, _) = sampleStore()
    #expect(GlobalStateDerivation.derive(store: store, status: nil, transition: nil) == .off)
    #expect(
        GlobalStateDerivation.derive(store: store, status: .stopped, transition: nil) == .off)
}

@Test func globalStateStartingUntilTunnelsConnect() {
    let (store, work, _, lab) = sampleStore()
    let since = Date()
    let transition = AppTransition.starting(since: since)
    #expect(
        GlobalStateDerivation.derive(store: store, status: nil, transition: transition)
            == .starting)
    var status = RuntimeStatus(engine: .running(since: since))
    status.tunnels = [key(work): .connecting(attempt: 1), key(lab): .connecting(attempt: 1)]
    #expect(
        GlobalStateDerivation.derive(
            store: store, status: status, transition: transition, now: since + 5) == .starting)
    // Timeout → degraded with the tunnels still waiting.
    #expect(
        GlobalStateDerivation.derive(
            store: store, status: status, transition: transition, now: since + 31)
            == .degraded(failingTunnelIDs: [work.id, lab.id]))
    status.tunnels[key(work)] = .connected(since: since, ip: "10.8.0.6", interface: "utun101")
    status.tunnels[key(lab)] = .connected(since: since, ip: nil, interface: "utun103")
    #expect(
        GlobalStateDerivation.derive(store: store, status: status, transition: transition)
            == .on)
}

@Test func globalStateDegradedWhenATunnelFails() {
    let (store, work, _, lab) = sampleStore()
    var status = RuntimeStatus(engine: .running(since: Date()))
    status.tunnels = [
        key(work): .connected(since: Date(), ip: "10.8.0.6", interface: "utun101"),
        key(lab): .failed(reason: "ovpn.authFailed", permanent: true),
    ]
    #expect(
        GlobalStateDerivation.derive(store: store, status: status, transition: nil)
            == .degraded(failingTunnelIDs: [lab.id]))
    // A reconnecting tunnel ends `starting` immediately.
    status.tunnels[key(lab)] = .reconnecting(attempt: 2, nextIn: 4, reason: "tls-error")
    #expect(
        GlobalStateDerivation.derive(
            store: store, status: status, transition: .starting(since: Date()))
            == .degraded(failingTunnelIDs: [lab.id]))
}

@Test func globalStateIgnoresDisabledTunnelsAndStaleEntries() {
    var (store, work, _, lab) = sampleStore()
    store.tunnels[2].isEnabled = false
    var status = RuntimeStatus(engine: .running(since: Date()))
    status.tunnels = [
        key(work): .connected(since: Date(), ip: "10.8.0.6", interface: "utun101"),
        key(lab): .failed(reason: "ovpn.authFailed", permanent: true),
        "not-a-known-id": .failed(reason: "ovpn.exited", permanent: false),
    ]
    #expect(GlobalStateDerivation.derive(store: store, status: status, transition: nil) == .on)
}

@Test func globalStateErrorAndStopping() {
    let (store, _, _, _) = sampleStore()
    let failed = RuntimeStatus(engine: .failed(reason: "singbox.startFailed"))
    #expect(
        GlobalStateDerivation.derive(store: store, status: failed, transition: nil)
            == .error(reason: "singbox.startFailed"))
    #expect(
        GlobalStateDerivation.derive(store: store, status: failed, transition: .stopping)
            == .stopping)
}

/// H2: the app's re-apply backoff after `engine = failed`.
@Test func recoveryBackoffSlowsDownAndCapsWithoutGivingUp() {
    var backoff = RecoveryBackoff()
    #expect(!backoff.isRecovering)
    var delays: [Duration] = []
    for _ in 0..<8 { delays.append(backoff.nextDelay()) }
    #expect(
        delays == [
            .seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300),
            .seconds(300), .seconds(300),
        ])
    #expect(backoff.isRecovering && backoff.failures == 8)
    backoff.reset()
    #expect(!backoff.isRecovering)
    #expect(backoff.nextDelay() == .seconds(5))
}

// MARK: - Status text

@Test func summaryLines() {
    var (store, work, _, lab) = sampleStore()
    #expect(
        StatusText.summary(state: .off, store: store, status: nil)
            == "Off — nothing goes through a tunnel. Turn on to send your 5 sites through their tunnels; everything else stays as it is."
    )
    #expect(StatusText.summary(state: .starting, store: store, status: nil) == "Starting…")
    // 6 rules, one disabled → 5 sites; 3 enabled tunnels.
    #expect(
        StatusText.summary(state: .on, store: store, status: nil)
            == "On — 5 sites via 3 tunnels, the rest as usual")
    #expect(
        StatusText.summary(state: .degraded(failingTunnelIDs: [lab.id]), store: store, status: nil)
            == "Lab can't connect — 2 tunnels up")
    #expect(
        StatusText.summary(
            state: .degraded(failingTunnelIDs: [work.id, lab.id]), store: store, status: nil)
            == "Work and Lab can't connect — 1 tunnel up")
    #expect(
        StatusText.summary(state: .error(reason: "singbox.startFailed"), store: store, status: nil)
            == "Routing engine failed — see Logs")
    store.rules = []
    #expect(
        StatusText.summary(state: .off, store: store, status: nil)
            == "Off — nothing goes through a tunnel.")
    store.tunnels = []
    #expect(StatusText.summary(state: .on, store: store, status: nil) == "On — no tunnels")
}

@Test func ordinalTries() {
    #expect(StatusText.ordinal(1) == "1st try")
    #expect(StatusText.ordinal(2) == "2nd try")
    #expect(StatusText.ordinal(3) == "3rd try")
    #expect(StatusText.ordinal(4) == "4th try")
    #expect(StatusText.ordinal(11) == "11th try")
    #expect(StatusText.ordinal(12) == "12th try")
    #expect(StatusText.ordinal(13) == "13th try")
    #expect(StatusText.ordinal(21) == "21st try")
    #expect(StatusText.ordinal(112) == "112th try")
}

@Test func wordingHelpers() {
    #expect(StatusText.matchWord(.suffix) == "and subdomains")
    #expect(StatusText.matchWord(.exact) == "exactly this")
    #expect(StatusText.matchWord(.wildcard) == "pattern")
    #expect(StatusText.matchWord(.app) == "the app")
    #expect(StatusText.matchWord(.ip) == "address range")
    #expect(StatusText.logDetailName(.error) == "Errors only")
    #expect(StatusText.logDetailName(.warning) == "Problems")
    #expect(StatusText.logDetailName(.info) == "Normal")
    #expect(StatusText.logDetailName(.debug) == "Everything")
    #expect(StatusText.count(1, "site") == "1 site")
    #expect(StatusText.count(3, "site") == "3 sites")
}

@Test func failureMessagesFollowTheCatalogue() {
    #expect(StatusText.failureMessage(code: "ovpn.authFailed") == "Server refused the login")
    #expect(StatusText.failureMessage(code: "ovpn.keyPassphrase") == "Wrong key passphrase")
    #expect(StatusText.failureMessage(code: "ovpn.configError") == "OpenVPN rejected the file")
    #expect(
        StatusText.failureMessage(code: "singbox.startFailed")
            == "Routing engine failed to start. Another VPN may be active.")
    #expect(StatusText.failureMessage(code: "something.new") == "Can't connect (something.new)")
    #expect(StatusText.failureAction(code: "ovpn.authFailed") == .editCredentials)
    #expect(StatusText.failureAction(code: "ovpn.needsKeyPassphrase") == .editKeyPassphrase)
    #expect(StatusText.failureAction(code: "ovpn.configError") == .replaceConfig)
    #expect(StatusText.failureAction(code: "something.new") == .showLog)
}

@Test func tunnelCards() {
    let (_, work, home, lab) = sampleStore()
    let connected = StatusText.card(
        tunnel: work, state: .connected(since: Date(), ip: "10.8.0.6", interface: "utun101"),
        global: .on, ruleCount: 3)
    #expect(connected.status == "Connected")
    #expect(connected.detail == "3 sites")
    #expect(connected.glyph == .up)
    #expect(connected.actions.isEmpty)
    #expect(!connected.isDefault)

    // Proxy kinds have no handshake to wait for: one word for one state.
    let ready = StatusText.card(tunnel: home, state: nil, global: .on, ruleCount: 2)
    #expect(ready.status == "Connected")
    #expect(ready.detail == "2 sites")
    #expect(ready.actions.isEmpty)

    let reconnecting = StatusText.card(
        tunnel: lab, state: .reconnecting(attempt: 2, nextIn: 4, reason: "tls-error"),
        global: .degraded(failingTunnelIDs: [lab.id]), ruleCount: 1)
    #expect(reconnecting.status == "Reconnecting…")
    #expect(reconnecting.detail == "2nd try")
    #expect(reconnecting.glyph == .transitioning)
    #expect(reconnecting.actions == [.reconnect])

    let failed = StatusText.card(
        tunnel: lab, state: .failed(reason: "ovpn.authFailed", permanent: true),
        global: .degraded(failingTunnelIDs: [lab.id]), ruleCount: 1)
    #expect(failed.status == "Can't connect")
    #expect(failed.detail == "Server refused the login")
    #expect(failed.isError)
    #expect(failed.actions == [.reconnect, .edit(.editCredentials)])

    var disabled = lab
    disabled.isEnabled = false
    let disabledCard = StatusText.card(tunnel: disabled, state: nil, global: .on, ruleCount: 1)
    #expect(disabledCard.status == "Off")
    #expect(disabledCard.detail == "1 site")
    #expect(disabledCard.isDimmed)
    #expect(disabledCard.actions == [.enable])

    let off = StatusText.card(tunnel: work, state: nil, global: .off, ruleCount: 3)
    #expect(off.status == "Not running")
    #expect(off.detail == "3 sites")
    #expect(off.isDimmed)
    #expect(off.actions.isEmpty)

    let missing = StatusText.card(
        tunnel: home, state: nil, global: .off, ruleCount: 2, missingSecret: true)
    #expect(missing.status == "Not ready")
    #expect(missing.detail == "UUID missing")
    #expect(missing.isError)
    #expect(missing.actions == [.edit(.replaceConfig)])
}

@Test func tunnelRowSummaries() {
    let (_, work, home, _) = sampleStore()
    let row = StatusText.rowSummary(
        tunnel: work, state: .connected(since: Date(), ip: "10.8.0.6", interface: "utun101"),
        global: .on, ruleCount: 3)
    #expect(row.text == "Connected · OpenVPN · 3 sites")
    #expect(row.glyph == .up)
    let vless = StatusText.rowSummary(tunnel: home, state: nil, global: .on, ruleCount: 2)
    #expect(vless.text == "Connected · VLESS · 2 sites")
    let off = StatusText.rowSummary(tunnel: home, state: nil, global: .off, ruleCount: 1)
    #expect(off.text == "Not running · VLESS · 1 site")
    #expect(off.glyph == .idle)
    let failed = StatusText.rowSummary(
        tunnel: work, state: .failed(reason: "ovpn.authFailed", permanent: true), global: .on,
        ruleCount: 1)
    #expect(failed.text == "Can't connect · Server refused the login · OpenVPN · 1 site")
    #expect(failed.isError)
    let reconnecting = StatusText.rowSummary(
        tunnel: work, state: .reconnecting(attempt: 3, nextIn: 4, reason: nil), global: .on,
        ruleCount: 1)
    #expect(reconnecting.text == "Reconnecting… · 3rd try · OpenVPN · 1 site")
    var disabled = work
    disabled.isEnabled = false
    let offRow = StatusText.rowSummary(tunnel: disabled, state: nil, global: .on, ruleCount: 2)
    #expect(offRow.text == "Off · OpenVPN · 2 sites")
}

@Test func proxyKindStatusText() {
    let shadowsocks = TunnelKind.shadowsocks(
        ShadowsocksMeta(server: "ss.example.net", port: 8388, method: "aes-256-gcm"))
    let trojan = TunnelKind.trojan(
        TrojanMeta(
            server: "trojan.example.net", port: 443, security: .reality,
            transport: .ws(path: "/", host: nil)))
    let vmess = TunnelKind.vmess(
        VMessMeta(
            server: "vmess.example.net", port: 443, security: "auto", tlsSecurity: .tls,
            transport: .grpc(serviceName: "wayfork")))

    #expect(StatusText.typeBadge(shadowsocks) == "Shadowsocks")
    #expect(StatusText.typeBadge(trojan) == "Trojan")
    #expect(StatusText.typeBadge(vmess) == "VMess")
    #expect(StatusText.endpointDescription(shadowsocks) == "ss.example.net:8388 · aes-256-gcm")
    #expect(StatusText.endpointDescription(trojan) == "trojan.example.net:443 · REALITY · ws")
    #expect(StatusText.endpointDescription(vmess) == "vmess.example.net:443 · auto · gRPC")

    let passwordMissing = StatusText.rowSummary(
        tunnel: Tunnel(name: "Trojan", slot: 0, kind: trojan), state: nil, global: .off,
        missingSecret: true)
    #expect(passwordMissing.text.hasPrefix("Not ready · password missing ·"))
    let uuidMissing = StatusText.rowSummary(
        tunnel: Tunnel(name: "VMess", slot: 1, kind: vmess), state: nil, global: .off,
        missingSecret: true)
    #expect(uuidMissing.text.hasPrefix("Not ready · UUID missing ·"))
}

// MARK: - Rule editing and quick add

@Test func quickAddNormalizesAndInfersMatch() {
    let (store, work, home, _) = sampleStore()
    guard
        case .add(let rule) = QuickAdd.evaluate(
            input: "https://Shop.Example.ORG/cart", target: .tunnel(home.id), store: store)
    else {
        Issue.record("expected add")
        return
    }
    #expect(rule.pattern == "shop.example.org")
    #expect(rule.match == .suffix)
    #expect(rule.tunnelID == home.id)

    guard
        case .add(let wildcard) = QuickAdd.evaluate(
            input: "*.img.example.org", target: .tunnel(work.id), store: store)
    else {
        Issue.record("expected add")
        return
    }
    #expect(wildcard.match == .wildcard)

    // An existing pattern is re-pointed instead of duplicated.
    guard
        case .update(let updated) = QuickAdd.evaluate(
            input: "example.com", target: .tunnel(home.id), store: store)
    else {
        Issue.record("expected update")
        return
    }
    #expect(updated.id == store.rules[0].id)
    #expect(updated.tunnelID == home.id)
    #expect(QuickAdd.isUpdate(input: "EXAMPLE.com", store: store))
    #expect(!QuickAdd.isUpdate(input: "new.example.com", store: store))

    #expect(
        QuickAdd.evaluate(input: "not a domain", target: .tunnel(work.id), store: store)
            == .invalid("Not a valid domain"))
    #expect(
        QuickAdd.evaluate(input: "", target: .tunnel(work.id), store: store)
            == .invalid("Enter a domain"))
}

@Test func quickAddClipboardCandidate() {
    #expect(QuickAdd.clipboardCandidate("https://news.example.org/a/b?x=1") == "news.example.org")
    #expect(QuickAdd.clipboardCandidate("  Example.COM  ") == "example.com")
    #expect(QuickAdd.clipboardCandidate("hello world") == nil)
    #expect(QuickAdd.clipboardCandidate("localhost") == nil)
    #expect(QuickAdd.clipboardCandidate("line one\nexample.com") == nil)
    #expect(QuickAdd.clipboardCandidate(nil) == nil)
}

@Test func ruleEditingRejectsDuplicatesWithinAGroup() {
    let (store, work, home, _) = sampleStore()
    #expect(
        RuleEditing.normalize(
            "Example.com", match: .suffix, target: .tunnel(work.id), store: store, excluding: nil)
            == .failure(.duplicate))
    // Same pattern under another tunnel is legal (it will be flagged as shadowed).
    #expect(
        RuleEditing.normalize(
            "example.com", match: .suffix, target: .tunnel(home.id), store: store, excluding: nil)
            == .success("example.com"))
    // Editing the rule itself is not a duplicate of itself.
    #expect(
        RuleEditing.normalize(
            "example.com", match: .suffix, target: .tunnel(work.id), store: store,
            excluding: store.rules[0].id) == .success("example.com"))
    #expect(
        RuleEditing.normalize(
            "*.example.com", match: .suffix, target: .tunnel(work.id), store: store, excluding: nil)
            == .failure(.pattern(.wildcardNotAllowed)))
    #expect(RuleEditing.message(for: .duplicate) == "This rule already exists in this group")
    #expect(
        RuleEditing.message(for: .pattern(.wildcardNotAllowed))
            == "`*` only allowed in wildcard rules")
}

// MARK: - F8

@Test func summaryAndCardsWithADefaultTunnel() {
    var (store, work, home, lab) = sampleStore()
    store.defaultTunnelID = home.id
    store.rules.append(Rule(pattern: "bank.example.org", target: .direct))
    store.rules.append(Rule(pattern: "paused.example.org", target: .direct, isEnabled: false))
    // 5 active tunnel rules, 3 of them outside Home; the exception is not "via" anything.
    #expect(
        StatusText.summary(state: .on, store: store, status: nil)
            == "On — everything goes via Home, 3 sites via other tunnels")
    // A default without its secret is no default.
    #expect(
        StatusText.summary(state: .on, store: store, status: nil, missingSecrets: [home.id])
            == "On — 5 sites via 3 tunnels, the rest as usual")
    store.defaultTunnelID = work.id
    #expect(
        StatusText.summary(state: .degraded(failingTunnelIDs: [work.id]), store: store, status: nil)
            == "Work can't connect — sites without a rule are blocked until it is back")
    #expect(
        StatusText.summary(state: .degraded(failingTunnelIDs: [lab.id]), store: store, status: nil)
            == "Lab can't connect — 2 tunnels up, everything else via Work")
    #expect(StatusText.activeExceptionCount(store) == 1)
    store.rules.removeAll { $0.tunnelID != nil && $0.tunnelID != work.id }
    #expect(
        StatusText.summary(state: .on, store: store, status: nil)
            == "On — everything goes via Work")

    let card = StatusText.card(
        tunnel: work, state: .connected(since: Date(), ip: "10.8.0.6", interface: "utun101"),
        global: .on, ruleCount: 3, isDefault: true)
    #expect(card.detail == "3 sites")
    #expect(card.isDefault)
    let row = StatusText.rowSummary(
        tunnel: home, state: nil, global: .on, isDefault: true, ruleCount: 2)
    #expect(row.text == "Connected · VLESS · routes everything else and 2 sites")
}

@Test func quickAddAndEditingSupportDirect() {
    let (store, work, _, _) = sampleStore()
    guard
        case .add(let rule) = QuickAdd.evaluate(
            input: "bank.example.org", target: .direct, store: store)
    else {
        Issue.record("expected add")
        return
    }
    #expect(rule.target == .direct)
    // Re-pointing an existing tunnel rule at Direct turns it into an exception.
    guard
        case .update(let updated) = QuickAdd.evaluate(
            input: "example.com", target: .direct, store: store)
    else {
        Issue.record("expected update")
        return
    }
    #expect(updated.id == store.rules[0].id)
    #expect(updated.isException)

    var withException = store
    withException.rules.append(Rule(pattern: "bank.example.org", target: .direct))
    #expect(
        RuleEditing.normalize(
            "bank.example.org", match: .suffix, target: .direct, store: withException,
            excluding: nil) == .failure(.duplicate))
    #expect(
        RuleEditing.normalize(
            "bank.example.org", match: .suffix, target: .tunnel(work.id), store: withException,
            excluding: nil) == .success("bank.example.org"))
}

// MARK: - F14

@Test func unreachableTunnelCardsAndRows() {
    let (_, work, home, _) = sampleStore()
    let now = Date()
    let down = LatencySample(
        history: [62, nil, nil, nil], failedInARow: 3, unreachable: true,
        lastSuccess: now.addingTimeInterval(-130))
    let card = StatusText.card(
        tunnel: home, state: nil, global: .on, ruleCount: 1, latency: down, now: now)
    #expect(card.status == "Not reachable")
    #expect(card.detail == "No answer through the tunnel for 2 min · 1 site waits")
    #expect(card.isError && card.glyph == .failed)
    #expect(card.actions == [.reconnect])

    // An OpenVPN tunnel that is not connected keeps its own state; its probes are skipped.
    let reconnecting = StatusText.card(
        tunnel: work, state: .reconnecting(attempt: 2, nextIn: 4, reason: nil), global: .on,
        ruleCount: 3, latency: down, now: now)
    #expect(reconnecting.status == "Reconnecting…")
    let connected = StatusText.card(
        tunnel: work, state: .connected(since: now, ip: nil, interface: "utun101"), global: .on,
        ruleCount: 3, latency: down, now: now)
    #expect(connected.status == "Not reachable")
    #expect(connected.detail == "No answer through the tunnel for 2 min · 3 sites wait")

    let fine = LatencySample(milliseconds: 62, history: [60, 62], lastSuccess: now)
    let up = StatusText.card(tunnel: home, state: nil, global: .on, ruleCount: 1, latency: fine)
    #expect(up.status == "Connected")

    let row = StatusText.rowSummary(
        tunnel: home, state: nil, global: .on, ruleCount: 1, latency: down, now: now)
    #expect(row.text == "Not reachable · No answer through the tunnel for 2 min · VLESS · 1 site")
    #expect(row.isError)
    // Off: no probes are shown at all.
    let off = StatusText.card(tunnel: home, state: nil, global: .off, ruleCount: 1, latency: down)
    #expect(off.status == "Not running")
}

// MARK: - F15

@Test func recentFilterDropsOldHiddenAndRuledHosts() {
    let (store, _, _, _) = sampleStore()  // rules: example.com (suffix), *.cdn.example.com, news.example.org…
    let now = Date()
    let hosts = [
        RecentHost(host: "fresh.example.net", exit: "direct", lastSeen: now),
        RecentHost(host: "old.example.net", exit: "direct", lastSeen: now.addingTimeInterval(-400)),
        RecentHost(host: "hidden.example.net", exit: "direct", lastSeen: now),
        RecentHost(host: "shop.example.com", exit: "direct", lastSeen: now),  // suffix rule
        RecentHost(host: "a.cdn.example.com", exit: "direct", lastSeen: now),  // wildcard rule
        RecentHost(host: "old.example.com", exit: "direct", lastSeen: now),  // covered by example.com
    ]
    let visible = RecentFilter.visible(
        hosts, sampledAt: now, window: 300, hidden: ["hidden.example.net"], store: store)
    #expect(visible.map(\.host) == ["fresh.example.net"])
    // A disabled rule does not count as cover.
    var loose = store
    loose.rules = [Rule(pattern: "example.net", tunnelID: store.tunnels[0].id, isEnabled: false)]
    #expect(
        RecentFilter.visible(hosts, sampledAt: now, window: 300, hidden: [], store: loose).count
            == 5)
}

// MARK: - Tunnel groups (F16)

private func groupedStore() -> (Store, group: TunnelGroup, work: Tunnel, home: Tunnel, lab: Tunnel)
{
    var (store, work, home, lab) = sampleStore()
    let group = TunnelGroup(name: "Streaming", members: [home.id, lab.id], policy: .fastest)
    store.groups = [group]
    store.rules.append(Rule(pattern: "video.example.com", target: .group(group.id)))
    store.rules.append(Rule(pattern: "cdn.example.net", target: .group(group.id)))
    return (store, group, work, home, lab)
}

@Test func groupCardStatesAndMembers() {
    var (store, group, work, home, lab) = groupedStore()
    let groups = [group.id.uuidString.lowercased(): GroupState(activeMember: key(home))]
    let latency = [
        key(home): LatencySample(milliseconds: 180), key(lab): LatencySample(milliseconds: 90),
    ]
    let states: [String: TunnelState] = [
        key(lab): .connected(since: Date(), ip: "10.8.0.6", interface: "utun102")
    ]

    let running = StatusText.groupCard(
        group: group, store: store, global: .on, latency: latency, groups: groups, states: states)
    #expect(running.glyph == .group && running.status == "Fastest")
    #expect(running.detail == "using Home · 2 sites")
    #expect(!running.isError && !running.isDimmed)

    // Before the first snapshot names a member the card only counts the sites.
    let unknown = StatusText.groupCard(group: group, store: store, global: .on, latency: latency)
    #expect(unknown.detail == "2 sites")

    let members = StatusText.groupMembers(
        group: group, store: store, global: .on, latency: latency, groups: groups, states: states)
    #expect(members.map(\.tunnel.name) == ["Home", "Lab"])
    #expect(members[0].note == "✓ in use" && members[0].isActive)
    #expect(members[1].note == "" && !members[1].isActive)
    #expect(members[1].latency?.milliseconds == 90)

    // Off, not running, disabled group.
    let off = StatusText.groupCard(group: group, store: store, global: .off)
    #expect(off.status == "Not running" && off.isDimmed && off.detail == "2 sites")
    var disabled = group
    disabled.isEnabled = false
    let disabledCard = StatusText.groupCard(group: disabled, store: store, global: .on)
    #expect(disabledCard.status == "Off" && disabledCard.actions == [.enable])

    // Every member gone: red, and the sites fall to the default exit.
    let unreachable = [
        key(home): LatencySample(milliseconds: nil, failedInARow: 3, unreachable: true),
        key(lab): LatencySample(milliseconds: nil, failedInARow: 3, unreachable: true),
    ]
    let dead = StatusText.groupCard(
        group: group, store: store, global: .on, latency: unreachable, groups: groups,
        states: states)
    #expect(dead.glyph == .failed && dead.isError && dead.status == "No member reachable")
    #expect(dead.detail == "its 2 sites stay outside a tunnel for now")
    store.defaultTunnelID = work.id
    #expect(
        StatusText.groupCard(
            group: group, store: store, global: .on, latency: unreachable, groups: groups,
            states: states
        ).detail == "its 2 sites go via Work for now")
    store.defaultTunnelID = group.id
    #expect(
        StatusText.groupCard(
            group: group, store: store, global: .on, latency: unreachable, groups: groups,
            states: states
        ).detail == "its 2 sites are blocked for now")
    let deadMembers = StatusText.groupMembers(
        group: group, store: store, global: .on, latency: unreachable, groups: groups,
        states: states)
    #expect(deadMembers.map(\.note) == ["skipped — not reachable", "skipped — not reachable"])

    // A disabled member is skipped as off; a failed OpenVPN member as not reachable.
    store.tunnels[1].isEnabled = false
    let failing: [String: TunnelState] = [
        key(lab): .failed(reason: "ovpn.authFailed", permanent: true)
    ]
    let mixed = StatusText.groupMembers(
        group: group, store: store, global: .on, states: failing)
    #expect(mixed.map(\.note) == ["skipped — off", "skipped — not reachable"])
    #expect(
        StatusText.groupCard(group: group, store: store, global: .on, states: failing).status
            == "No member reachable")
}

@Test func groupRowSummaryAndRulesHint() {
    var (store, group, work, home, _) = groupedStore()
    let groups = [group.id.uuidString.lowercased(): GroupState(activeMember: key(home))]
    #expect(
        StatusText.groupRowSummary(group: group, store: store, global: .on, groups: groups).text
            == "Group · fastest of Home, Lab · using Home · 2 sites")
    #expect(
        StatusText.groupRowSummary(group: group, store: store, global: .off).text
            == "Not running · Group · fastest of Home, Lab · 2 sites")
    #expect(
        StatusText.groupHint(group: group, store: store, global: .on, groups: groups).text
            == "fastest of Home, Lab · using Home right now")
    var firstLive = group
    firstLive.policy = .firstLive
    #expect(
        StatusText.groupHint(group: firstLive, store: store, global: .off).text
            == "first live of Home, Lab")
    #expect(StatusText.policyWord(.firstLive) == "First live")

    store.defaultTunnelID = work.id
    var disabled = group
    disabled.isEnabled = false
    let hint = StatusText.groupHint(group: disabled, store: store, global: .on)
    #expect(hint.text == "off — its sites go via Work for now" && !hint.isError)

    // The group as the default exit: the summary names it and its row says so.
    store.defaultTunnelID = group.id
    #expect(
        StatusText.summary(state: .on, store: store, status: nil)
            == "On — everything goes via Streaming, 5 sites via other tunnels")
    #expect(
        StatusText.groupRowSummary(group: group, store: store, global: .off).text
            == "Not running · Group · fastest of Home, Lab · routes everything else and 2 sites")
    #expect(StatusText.effectiveDefaultExitName(store) == "Streaming")
    #expect(StatusText.effectiveDefaultExitName(store, missingSecrets: [home.id]) == "Streaming")
    store.tunnels[1].isEnabled = false
    #expect(
        StatusText.effectiveDefaultExitName(store, missingSecrets: [store.tunnels[2].id]) == nil)
}
