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
            == "Off — all traffic goes direct")
    #expect(StatusText.summary(state: .starting, store: store, status: nil) == "Starting…")
    // 6 rules, one disabled → 5 domains; 3 enabled tunnels.
    #expect(
        StatusText.summary(state: .on, store: store, status: nil)
            == "On — routing 5 domains through 3 tunnels")
    #expect(
        StatusText.summary(state: .degraded(failingTunnelIDs: [lab.id]), store: store, status: nil)
            == "Degraded — Lab is failing · 5 domains, 2 tunnels up")
    #expect(
        StatusText.summary(
            state: .degraded(failingTunnelIDs: [work.id, lab.id]), store: store, status: nil)
            == "Degraded — Work, Lab are failing · 5 domains, 1 tunnel up")
    #expect(
        StatusText.summary(state: .error(reason: "singbox.startFailed"), store: store, status: nil)
            == "Routing engine failed — see Logs")
    store.tunnels = []
    store.rules = []
    #expect(StatusText.summary(state: .on, store: store, status: nil) == "On — no tunnels")
}

@Test func failureMessagesFollowTheCatalogue() {
    #expect(
        StatusText.failureMessage(code: "ovpn.authFailed")
            == "failed: server rejected username/password")
    #expect(StatusText.failureMessage(code: "ovpn.keyPassphrase") == "failed: wrong key passphrase")
    #expect(
        StatusText.failureMessage(code: "ovpn.configError") == "failed: OpenVPN rejected the config"
    )
    #expect(
        StatusText.failureMessage(code: "singbox.startFailed")
            == "Routing engine failed to start. Another VPN may be active.")
    #expect(StatusText.failureMessage(code: "something.new") == "failed: something.new")
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
    #expect(connected.detail == "connected · 10.8.0.6 on utun101 · 3 rules")
    #expect(connected.glyph == .up)
    #expect(connected.action == .reconnect)

    let ready = StatusText.card(tunnel: home, state: nil, global: .on, ruleCount: 2)
    #expect(ready.detail == "ready · host.example.com · 2 rules")
    #expect(ready.action == nil)

    let reconnecting = StatusText.card(
        tunnel: lab, state: .reconnecting(attempt: 2, nextIn: 4, reason: "tls-error"),
        global: .degraded(failingTunnelIDs: [lab.id]), ruleCount: 1)
    #expect(reconnecting.detail == "reconnecting… attempt 2 · tls-error")
    #expect(reconnecting.glyph == .transitioning)

    let failed = StatusText.card(
        tunnel: lab, state: .failed(reason: "ovpn.authFailed", permanent: true),
        global: .degraded(failingTunnelIDs: [lab.id]), ruleCount: 1)
    #expect(failed.detail == "failed: server rejected username/password")
    #expect(failed.isError)
    #expect(failed.action == .edit(.editCredentials))

    var disabled = lab
    disabled.isEnabled = false
    let disabledCard = StatusText.card(tunnel: disabled, state: nil, global: .on, ruleCount: 1)
    #expect(disabledCard.detail == "disabled · 1 rule")
    #expect(disabledCard.isDimmed)
    #expect(disabledCard.action == .enable)

    let off = StatusText.card(tunnel: work, state: nil, global: .off, ruleCount: 3)
    #expect(off.detail == "not running · 3 rules")
    #expect(off.isDimmed)
    #expect(off.action == nil)

    let missing = StatusText.card(
        tunnel: home, state: nil, global: .off, ruleCount: 2, missingSecret: true)
    #expect(missing.detail == "UUID missing · 2 rules")
    #expect(missing.isError)
}

@Test func tunnelRowSummaries() {
    let (_, work, home, _) = sampleStore()
    let row = StatusText.rowSummary(
        tunnel: work, state: .connected(since: Date(), ip: "10.8.0.6", interface: "utun101"),
        global: .on)
    #expect(row.text == "connected · vpn.example.com:1194 udp · 10.8.0.6 on utun101")
    #expect(row.glyph == .up)
    let vless = StatusText.rowSummary(tunnel: home, state: nil, global: .on)
    #expect(vless.text == "ready · host.example.com:443 · REALITY · vision")
    let off = StatusText.rowSummary(tunnel: home, state: nil, global: .off)
    #expect(off.text == "not running · host.example.com:443 · REALITY · vision")
    #expect(off.glyph == .idle)
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
    #expect(
        StatusText.summary(state: .on, store: store, status: nil)
            == "On — everything via Home · 5 rules, 1 exception")
    // A default without its secret is no default.
    #expect(
        StatusText.summary(state: .on, store: store, status: nil, missingSecrets: [home.id])
            == "On — routing 5 domains through 3 tunnels")
    store.defaultTunnelID = work.id
    #expect(
        StatusText.summary(state: .degraded(failingTunnelIDs: [work.id]), store: store, status: nil)
            == "Degraded — Work (default) is down · unmatched traffic is blocked")
    #expect(
        StatusText.summary(state: .degraded(failingTunnelIDs: [lab.id]), store: store, status: nil)
            == "Degraded — Lab is failing · 5 domains, 2 tunnels up")
    #expect(StatusText.activeExceptionCount(store) == 1)

    let card = StatusText.card(
        tunnel: work, state: .connected(since: Date(), ip: "10.8.0.6", interface: "utun101"),
        global: .on, ruleCount: 3, isDefault: true)
    #expect(card.detail == "connected · 10.8.0.6 on utun101 · 3 rules · everything else")
    let ready = StatusText.card(
        tunnel: home, state: nil, global: .on, ruleCount: 2, isDefault: true)
    #expect(ready.detail == "ready · host.example.com · 2 rules · everything else")
    let row = StatusText.rowSummary(tunnel: home, state: nil, global: .on, isDefault: true)
    #expect(row.text == "ready · host.example.com:443 · REALITY · vision · everything else")
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
