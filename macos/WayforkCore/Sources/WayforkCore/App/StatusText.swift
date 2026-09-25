import Foundation

/// Error codes from the catalogue in docs/design/02-ux.md, with the text the UI shows and
/// the recovery it offers.
public enum FailureCode: String, Sendable, CaseIterable {
    case ovpnAuthFailed = "ovpn.authFailed"
    case ovpnNeedsCredentials = "ovpn.needsCredentials"
    case ovpnKeyPassphrase = "ovpn.keyPassphrase"
    case ovpnNeedsKeyPassphrase = "ovpn.needsKeyPassphrase"
    case ovpnConfigError = "ovpn.configError"
    case ovpnUnsupportedPrompt = "ovpn.unsupportedPrompt"
    case ovpnExited = "ovpn.exited"
    case ovpnStartFailed = "ovpn.startFailed"
    case singboxStartFailed = "singbox.startFailed"
    case singboxConfigInvalid = "singbox.configInvalid"
    case helperNotApproved = "helper.notApproved"
    case helperVersionMismatch = "helper.versionMismatch"
    case helperUnreachable = "helper.unreachable"

    /// Short text for the UI.
    public var message: String {
        switch self {
        case .ovpnAuthFailed: "Server refused the login"
        case .ovpnNeedsCredentials: "Login and password needed"
        case .ovpnKeyPassphrase: "Wrong key passphrase"
        case .ovpnNeedsKeyPassphrase: "Key passphrase needed"
        case .ovpnConfigError: "OpenVPN rejected the file"
        case .ovpnUnsupportedPrompt: "OpenVPN asked for something Wayfork can't provide"
        case .ovpnExited: "OpenVPN stopped (reconnect on its own is off)"
        case .ovpnStartFailed: "OpenVPN could not start"
        case .singboxStartFailed: "Routing engine failed to start. Another VPN may be active."
        case .singboxConfigInvalid: "Routing config rejected"
        case .helperNotApproved: "Wayfork needs approval in System Settings → Login Items."
        case .helperVersionMismatch: "Updating helper…"
        case .helperUnreachable: "Can't reach the Wayfork helper."
        }
    }

    public var action: FailureAction? {
        switch self {
        case .ovpnAuthFailed, .ovpnNeedsCredentials: .editCredentials
        case .ovpnKeyPassphrase, .ovpnNeedsKeyPassphrase: .editKeyPassphrase
        case .ovpnConfigError: .replaceConfig
        case .ovpnUnsupportedPrompt, .ovpnExited, .ovpnStartFailed, .singboxStartFailed: .showLog
        case .singboxConfigInvalid: .exportDiagnostics
        case .helperNotApproved: .openSystemSettings
        case .helperVersionMismatch, .helperUnreachable: .reinstallHelper
        }
    }
}

/// What the Fix… / Show Log button next to a failure does.
public enum FailureAction: Sendable, Hashable {
    case editCredentials
    case editKeyPassphrase
    case replaceConfig
    case showLog
    case exportDiagnostics
    case openSystemSettings
    case reinstallHelper
}

/// Status glyph next to a tunnel (docs/design/02-ux.md, "Status glyphs").
public enum StatusGlyph: Sendable, Hashable {
    /// Green filled: connected.
    case up
    /// Grey hollow: disabled / not running.
    case idle
    /// Orange half: connecting / reconnecting.
    case transitioning
    /// Red: failed / not ready.
    case failed
    /// Accent square: a tunnel group (F16).
    case group
}

/// Action button on a popover tunnel card.
public enum TunnelCardAction: Sendable, Hashable {
    case reconnect
    case edit(FailureAction)
    case enable
}

/// Everything a popover tunnel card needs to render.
public struct TunnelPresentation: Sendable, Hashable {
    public var glyph: StatusGlyph
    /// The bold word at the start of card line 2.
    public var status: String
    /// The rest of card line 2, without the status word.
    public var detail: String
    public var isError: Bool
    public var isDimmed: Bool
    public var actions: [TunnelCardAction]
    public var isDefault: Bool

    public init(
        glyph: StatusGlyph, status: String, detail: String = "", isError: Bool = false,
        isDimmed: Bool = false, actions: [TunnelCardAction] = [], isDefault: Bool = false
    ) {
        self.glyph = glyph
        self.status = status
        self.detail = detail
        self.isError = isError
        self.isDimmed = isDimmed
        self.actions = actions
        self.isDefault = isDefault
    }
}

/// One member line under a group card or in the expanded group (F16).
public struct GroupMemberRow: Sendable, Hashable, Identifiable {
    public var tunnel: Tunnel
    public var glyph: StatusGlyph
    /// `✓ in use` / `skipped — not reachable` / `skipped — off`; empty for a live backup.
    public var note: String
    public var isActive: Bool
    public var latency: LatencySample?

    public var id: UUID { tunnel.id }

    public init(
        tunnel: Tunnel, glyph: StatusGlyph, note: String = "", isActive: Bool = false,
        latency: LatencySample? = nil
    ) {
        self.tunnel = tunnel
        self.glyph = glyph
        self.note = note
        self.isActive = isActive
        self.latency = latency
    }
}

/// User-facing strings derived from store + runtime status (docs/design/02-ux.md).
public enum StatusText {
    // MARK: - Failures

    /// Tunnel failures are presented separately from their status word.
    public static func failureMessage(code: String) -> String {
        guard let known = FailureCode(rawValue: code) else { return "Can't connect (\(code))" }
        return known.message
    }

    public static func failureAction(code: String) -> FailureAction? {
        FailureCode(rawValue: code)?.action ?? .showLog
    }

    // MARK: - Popover header

    /// `missingSecrets`: tunnels the plan left out (a default without its secret is no
    /// default).
    public static func summary(
        state: GlobalState, store: Store, status: RuntimeStatus?, missingSecrets: Set<UUID> = []
    ) -> String {
        // A tunnel or a group (F16) may take "everything else".
        let defaultExit = effectiveDefaultExitName(store, missingSecrets: missingSecrets)
            .map { (id: store.defaultTunnelID!, name: $0) }
        switch state {
        case .off:
            let sites = activeRuleCount(store)
            guard sites > 0 else { return "Off — nothing goes through a tunnel." }
            return
                "Off — nothing goes through a tunnel. Turn on to send your \(count(sites, "site")) through their tunnels; everything else stays as it is."
        case .starting:
            return "Starting…"
        case .stopping:
            return "Stopping…"
        case .error:
            return "Routing engine failed — see Logs"
        case .on:
            let tunnels = store.tunnels.filter(\.isEnabled).count
            guard tunnels > 0 else { return "On — no tunnels" }
            let sites = activeRuleCount(store)
            if let defaultExit {
                let otherSites = RuleValidator.activeRules(store)
                    .filter { $0.key != defaultExit.id }
                    .values.reduce(0) { $0 + $1.count }
                guard otherSites > 0 else {
                    return "On — everything goes via \(defaultExit.name)"
                }
                return
                    "On — everything goes via \(defaultExit.name), \(count(otherSites, "site")) via other tunnels"
            }
            return "On — \(count(sites, "site")) via \(count(tunnels, "tunnel")), the rest as usual"
        case .degraded(let failing):
            if let defaultExit, failing.contains(defaultExit.id) {
                return
                    "\(defaultExit.name) can't connect — sites without a rule are blocked until it is back"
            }
            let names = failing.compactMap { store.tunnel(id: $0)?.name }
            let subject: String
            switch names.count {
            case 0: subject = "A tunnel"
            case 1: subject = names[0]
            case 2: subject = names.joined(separator: " and ")
            default: subject = names.dropLast().joined(separator: ", ") + " and \(names.last!)"
            }
            let enabled = store.tunnels.filter(\.isEnabled).count
            let up = max(0, enabled - failing.count)
            var result = "\(subject) can't connect — \(count(up, "tunnel")) up"
            if let defaultExit { result += ", everything else via \(defaultExit.name)" }
            return result
        }
    }

    /// Tunnel rules that currently route something: enabled, not shadowed, tunnel enabled.
    public static func activeRuleCount(_ store: Store) -> Int {
        RuleValidator.activeRules(store).values.reduce(0) { $0 + $1.count }
    }

    /// Direct rules in effect (F8).
    public static func activeExceptionCount(_ store: Store) -> Int {
        RuleValidator.activeExceptions(store).count
    }

    /// The default tunnel that is actually routing "everything else" (F8).
    public static func effectiveDefaultTunnel(_ store: Store, missingSecrets: Set<UUID> = [])
        -> Tunnel?
    {
        guard let tunnel = store.effectiveDefaultTunnel, !missingSecrets.contains(tunnel.id)
        else { return nil }
        return tunnel
    }

    // MARK: - Tunnel cards and rows

    /// Popover card for one tunnel. `latency` (F14) turns a connected card into *Not
    /// reachable* while its probes fail; `now` dates the "for N min" in that line.
    public static func card(
        tunnel: Tunnel, state: TunnelState?, global: GlobalState, ruleCount: Int,
        missingSecret: Bool = false, isDefault: Bool = false, latency: LatencySample? = nil,
        now: Date = Date()
    ) -> TunnelPresentation {
        let sites = count(ruleCount, "site")
        if !tunnel.isEnabled {
            return TunnelPresentation(
                glyph: .idle, status: "Off", detail: sites, isDimmed: true, actions: [.enable],
                isDefault: isDefault)
        }
        if missingSecret {
            let what: String
            switch tunnel.kind {
            case .openVPN: what = "config"
            case .vless: what = "UUID"
            case .wireGuard: what = "private key"
            case .shadowsocks, .trojan: what = "password"
            case .vmess: what = "UUID"
            }
            return TunnelPresentation(
                glyph: .failed, status: "Not ready", detail: "\(what) missing", isError: true,
                actions: [.edit(.replaceConfig)], isDefault: isDefault)
        }
        switch global {
        case .off, .stopping:
            return TunnelPresentation(
                glyph: .idle, status: "Not running", detail: sites, isDimmed: true,
                isDefault: isDefault)
        case .error:
            return TunnelPresentation(
                glyph: .idle, status: "Not routed", detail: sites, isDimmed: true,
                isDefault: isDefault)
        case .starting, .on, .degraded:
            break
        }
        // F14: probes through the tunnel failed N times in a row.
        if let latency, latency.unreachable, !tunnel.kind.isOpenVPN || state?.isConnected == true {
            return TunnelPresentation(
                glyph: .failed, status: "Not reachable",
                detail:
                    "\(LatencyFormat.unreachableDetail(latency, now: now)) · \(waiting(ruleCount))",
                isError: true, actions: [.reconnect], isDefault: isDefault)
        }
        guard tunnel.kind.isOpenVPN else {
            return TunnelPresentation(
                glyph: .up, status: "Connected", detail: sites, isDefault: isDefault)
        }
        switch state {
        case .none, .disabled:
            return TunnelPresentation(
                glyph: .transitioning, status: "Connecting…", detail: ordinal(1),
                isDefault: isDefault)
        case .connecting(let attempt):
            return TunnelPresentation(
                glyph: .transitioning, status: "Connecting…", detail: ordinal(attempt),
                isDefault: isDefault)
        case .reconnecting(let attempt, _, _):
            return TunnelPresentation(
                glyph: .transitioning, status: "Reconnecting…", detail: ordinal(attempt),
                actions: [.reconnect], isDefault: isDefault)
        case .connected:
            return TunnelPresentation(
                glyph: .up, status: "Connected", detail: sites, isDefault: isDefault)
        case .failed(let reason, _):
            return TunnelPresentation(
                glyph: .failed, status: "Can't connect", detail: failureMessage(code: reason),
                isError: true,
                actions: [.reconnect, .edit(failureAction(code: reason) ?? .showLog)],
                isDefault: isDefault)
        }
    }

    // MARK: - Groups (F16)

    /// `Fastest` / `First live`.
    public static func policyWord(_ policy: GroupPolicy) -> String {
        switch policy {
        case .fastest: "Fastest"
        case .firstLive: "First live"
        }
    }

    /// `fastest of Home, Lab` — every member in the group's order.
    public static func policyPhrase(group: TunnelGroup, store: Store) -> String {
        let names = group.members.compactMap { store.tunnel(id: $0)?.name }
        return "\(policyWord(group.policy).lowercased()) of \(names.joined(separator: ", "))"
    }

    /// The one-line meaning next to the *Pick by* control and in the New group sheet.
    public static func policyMeaning(_ policy: GroupPolicy, short: Bool) -> String {
        switch (policy, short) {
        case (.fastest, true): "the member that answers quickest right now"
        case (.firstLive, true): "the top member that works; the ones below are backups"
        case (.fastest, false):
            "Whichever member answers quickest right now — switches when another one gets faster."
        case (.firstLive, false):
            "Always the top member that works; the ones below are backups, in order."
        }
    }

    /// The member sing-box is using, from the snapshot, when it is still one of the group's.
    public static func activeMember(
        group: TunnelGroup, store: Store, groups: [String: GroupState]
    ) -> Tunnel? {
        guard let id = groups[group.id.uuidString.lowercased()]?.activeMember,
            let uuid = UUID(uuidString: id), group.members.contains(uuid)
        else { return nil }
        return store.tunnel(id: uuid)
    }

    /// Members that can carry traffic right now: enabled, with their secret, and not
    /// unreachable or failed. Empty means the card says *No member reachable*.
    static func liveMembers(
        group: TunnelGroup, store: Store, states: [String: TunnelState],
        latency: [String: LatencySample], missingSecrets: Set<UUID>
    ) -> [Tunnel] {
        store.enabledMembers(of: group).filter { member in
            !missingSecrets.contains(member.id)
                && memberSkipReason(
                    member, state: states[member.id.uuidString.lowercased()],
                    latency: latency[member.id.uuidString.lowercased()], missingSecret: false)
                    == nil
        }
    }

    /// Why a member is skipped (`off` / `not reachable`), or nil when it is live.
    private static func memberSkipReason(
        _ member: Tunnel, state: TunnelState?, latency: LatencySample?, missingSecret: Bool
    ) -> String? {
        if !member.isEnabled || missingSecret { return "off" }
        if latency?.unreachable == true { return "not reachable" }
        if member.kind.isOpenVPN, case .failed = state { return "not reachable" }
        return nil
    }

    /// Popover card for a group: the policy word, the member in use and the site count;
    /// red *No member reachable* when nothing can carry its sites right now.
    public static func groupCard(
        group: TunnelGroup, store: Store, global: GlobalState,
        latency: [String: LatencySample] = [:], groups: [String: GroupState] = [:],
        states: [String: TunnelState] = [:], missingSecrets: Set<UUID> = []
    ) -> TunnelPresentation {
        let ruleCount = store.rules(forGroup: group.id).count
        let sites = count(ruleCount, "site")
        // Default only while it actually takes "everything else" (like a tunnel card).
        let isDefault =
            store.defaultTunnelID == group.id
            && effectiveDefaultExitName(store, missingSecrets: missingSecrets) != nil
        if !group.isEnabled {
            return TunnelPresentation(
                glyph: .idle, status: "Off", detail: sites, isDimmed: true, actions: [.enable],
                isDefault: isDefault)
        }
        switch global {
        case .off, .stopping:
            return TunnelPresentation(
                glyph: .idle, status: "Not running", detail: sites, isDimmed: true,
                isDefault: isDefault)
        case .error:
            return TunnelPresentation(
                glyph: .idle, status: "Not routed", detail: sites, isDimmed: true,
                isDefault: isDefault)
        case .starting, .on, .degraded:
            break
        }
        let live = liveMembers(
            group: group, store: store, states: states, latency: latency,
            missingSecrets: missingSecrets)
        guard !live.isEmpty else {
            let fallback: String
            if isDefault {
                fallback = "its \(sites) are blocked for now"
            } else if let name = effectiveDefaultExitName(store, missingSecrets: missingSecrets) {
                fallback = "its \(sites) go via \(name) for now"
            } else {
                fallback = "its \(sites) stay outside a tunnel for now"
            }
            return TunnelPresentation(
                glyph: .failed, status: "No member reachable", detail: fallback, isError: true,
                isDefault: isDefault)
        }
        var detail = sites
        if let active = activeMember(group: group, store: store, groups: groups) {
            detail = "using \(active.name) · \(sites)"
        }
        return TunnelPresentation(
            glyph: .group, status: policyWord(group.policy), detail: detail, isDefault: isDefault)
    }

    /// Member rows under the group card and in the expanded group, in the group's order.
    public static func groupMembers(
        group: TunnelGroup, store: Store, global: GlobalState,
        latency: [String: LatencySample] = [:], groups: [String: GroupState] = [:],
        states: [String: TunnelState] = [:], missingSecrets: Set<UUID> = []
    ) -> [GroupMemberRow] {
        let running = global.isRunning && group.isEnabled
        let active = running ? activeMember(group: group, store: store, groups: groups) : nil
        return group.members.compactMap { id -> GroupMemberRow? in
            guard let member = store.tunnel(id: id) else { return nil }
            let key = id.uuidString.lowercased()
            let sample = latency[key]
            let missing = missingSecrets.contains(id)
            let card = card(
                tunnel: member, state: states[key], global: global, ruleCount: 0,
                missingSecret: missing, latency: sample)
            let reason = memberSkipReason(
                member, state: states[key], latency: sample, missingSecret: missing)
            // A skip reason wins over the tick: a selector left pointing at a dead member
            // is not "in use" in any sense the user cares about.
            if member.id == active?.id, reason == nil {
                return GroupMemberRow(
                    tunnel: member, glyph: card.glyph, note: "✓ in use", isActive: true,
                    latency: sample)
            }
            let note = running || reason == "off" ? reason.map { "skipped — \($0)" } ?? "" : ""
            return GroupMemberRow(
                tunnel: member, glyph: card.glyph, note: note, latency: running ? sample : nil)
        }
    }

    /// Subtitle of a Settings › Tunnels group row: `Group · fastest of Home, Lab · using
    /// Home · N sites`, with the status word in front when it is not just running.
    public static func groupRowSummary(
        group: TunnelGroup, store: Store, global: GlobalState,
        latency: [String: LatencySample] = [:], groups: [String: GroupState] = [:],
        states: [String: TunnelState] = [:], missingSecrets: Set<UUID> = []
    ) -> (text: String, glyph: StatusGlyph, isError: Bool) {
        let card = groupCard(
            group: group, store: store, global: global, latency: latency, groups: groups,
            states: states, missingSecrets: missingSecrets)
        var parts: [String] = []
        if card.glyph != .group { parts.append(card.status) }
        parts.append("Group")
        parts.append(policyPhrase(group: group, store: store))
        if card.glyph == .group,
            let active = activeMember(group: group, store: store, groups: groups)
        {
            parts.append("using \(active.name)")
        }
        let ruleCount = store.rules(forGroup: group.id).count
        parts.append(
            card.isDefault
                ? "routes everything else and \(count(ruleCount, "site"))"
                : count(ruleCount, "site"))
        return (parts.joined(separator: " · "), card.glyph, card.isError)
    }

    /// Header hint of a group's section on the Rules page: `fastest of Home, Lab · using
    /// Home right now`, or what happens to its sites while it cannot deliver.
    public static func groupHint(
        group: TunnelGroup, store: Store, global: GlobalState,
        latency: [String: LatencySample] = [:], groups: [String: GroupState] = [:],
        states: [String: TunnelState] = [:], missingSecrets: Set<UUID> = []
    ) -> (text: String, isError: Bool) {
        let card = groupCard(
            group: group, store: store, global: global, latency: latency, groups: groups,
            states: states, missingSecrets: missingSecrets)
        if !group.isEnabled {
            if let name = effectiveDefaultExitName(store, missingSecrets: missingSecrets) {
                return ("off — its sites go via \(name) for now", false)
            }
            return ("off — its sites stay outside a tunnel for now", false)
        }
        if card.isError { return ("no member reachable — its sites wait", true) }
        var text = policyPhrase(group: group, store: store)
        if card.glyph == .group,
            let active = activeMember(group: group, store: store, groups: groups)
        {
            text += " · using \(active.name) right now"
        }
        return (text, false)
    }

    /// Name of the tunnel or group taking "everything else" (F8, F16), nil when direct.
    public static func effectiveDefaultExitName(_ store: Store, missingSecrets: Set<UUID> = [])
        -> String?
    {
        switch store.effectiveDefaultExit {
        case .tunnel(let tunnel):
            return missingSecrets.contains(tunnel.id) ? nil : tunnel.name
        case .group(let group):
            let usable = store.enabledMembers(of: group).contains {
                !missingSecrets.contains($0.id)
            }
            return usable ? group.name : nil
        case nil:
            return nil
        }
    }

    /// `1 site waits` / `3 sites wait` — what a tunnel that cannot deliver holds up.
    static func waiting(_ ruleCount: Int) -> String {
        "\(count(ruleCount, "site")) wait\(ruleCount == 1 ? "s" : "")"
    }

    /// One-line summary for a Settings › Tunnels row.
    public static func rowSummary(
        tunnel: Tunnel, state: TunnelState?, global: GlobalState, missingSecret: Bool = false,
        isDefault: Bool = false, ruleCount: Int = 0, latency: LatencySample? = nil,
        now: Date = Date()
    ) -> (text: String, glyph: StatusGlyph, isError: Bool) {
        let presentation = card(
            tunnel: tunnel, state: state, global: global, ruleCount: ruleCount,
            missingSecret: missingSecret, isDefault: isDefault, latency: latency, now: now)
        // The card's detail repeats the site count for the quiet states; the row appends it
        // itself, so only a reason or an attempt is carried over.
        var parts = [presentation.status]
        if presentation.status == "Not reachable", let latency {
            parts.append(LatencyFormat.unreachableDetail(latency, now: now))
        } else if presentation.isError || presentation.glyph == .transitioning {
            parts.append(presentation.detail)
        }
        parts.append(typeBadge(tunnel.kind))
        parts.append(
            isDefault
                ? "routes everything else and \(count(ruleCount, "site"))"
                : count(ruleCount, "site"))
        return (parts.joined(separator: " · "), presentation.glyph, presentation.isError)
    }

    /// `vpn.example.com:1194 udp` / `host.example.com:443 · REALITY · vision`.
    public static func endpointDescription(_ kind: TunnelKind) -> String {
        switch kind {
        case .openVPN(let meta):
            guard let first = meta.remotes.first else { return "no remote" }
            var text = "\(first.host):\(first.port) \(first.proto)"
            if meta.remotes.count > 1 { text += " +\(meta.remotes.count - 1)" }
            return text
        case .vless(let meta):
            var parts = ["\(meta.server):\(meta.port)"]
            switch meta.security {
            case .reality: parts.append("REALITY")
            case .tls: parts.append("TLS")
            case .none: parts.append("no TLS")
            }
            switch meta.transport {
            case .tcp: break
            case .ws: parts.append("ws")
            case .grpc: parts.append("gRPC")
            }
            if meta.flow == "xtls-rprx-vision" { parts.append("vision") }
            return parts.joined(separator: " · ")
        case .wireGuard(let meta):
            guard let first = meta.peers.first else { return "no peer" }
            return "\(first.host):\(first.port)"
        case .shadowsocks(let meta):
            return "\(meta.server):\(meta.port) · \(meta.method)"
        case .trojan(let meta):
            var parts = ["\(meta.server):\(meta.port)", securityDescription(meta.security)]
            appendTransport(meta.transport, to: &parts)
            return parts.joined(separator: " · ")
        case .vmess(let meta):
            var parts = ["\(meta.server):\(meta.port)", meta.security]
            appendTransport(meta.transport, to: &parts)
            return parts.joined(separator: " · ")
        }
    }

    public static func typeBadge(_ kind: TunnelKind) -> String {
        switch kind {
        case .openVPN: "OpenVPN"
        case .vless: "VLESS"
        case .wireGuard: "WireGuard"
        case .shadowsocks: "Shadowsocks"
        case .trojan: "Trojan"
        case .vmess: "VMess"
        }
    }

    /// `1st try`, `2nd try`, `11th try`, `21st try`.
    public static func ordinal(_ number: Int) -> String {
        let remainder = number % 100
        let suffix: String
        if (11...13).contains(remainder) {
            suffix = "th"
        } else {
            switch number % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(number)\(suffix) try"
    }

    /// The match kind in the user's words (docs/design/02-ux.md, "Wording").
    public static func matchWord(_ match: RuleMatch) -> String {
        switch match {
        case .suffix: "and subdomains"
        case .exact: "exactly this"
        case .wildcard: "pattern"
        case .app: "the app"
        case .ip: "address range"
        }
    }

    /// General › Logs › Detail item for a log level.
    public static func logDetailName(_ level: LogLevel) -> String {
        switch level {
        case .error: "Errors only"
        case .warning: "Problems"
        case .info: "Normal"
        case .debug: "Everything"
        }
    }

    private static func securityDescription(_ security: TLSSecurity) -> String {
        switch security {
        case .reality: "REALITY"
        case .tls: "TLS"
        case .none: "no TLS"
        }
    }

    private static func appendTransport(_ transport: ProxyTransport, to parts: inout [String]) {
        switch transport {
        case .tcp: break
        case .ws: parts.append("ws")
        case .grpc: parts.append("gRPC")
        }
    }

    /// `1 site`, `3 sites`.
    public static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
