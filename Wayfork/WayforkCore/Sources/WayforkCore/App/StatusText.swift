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

    /// Short text; tunnel codes read as the tail of "failed: …".
    public var message: String {
        switch self {
        case .ovpnAuthFailed: "server rejected username/password"
        case .ovpnNeedsCredentials: "username and password required"
        case .ovpnKeyPassphrase: "wrong key passphrase"
        case .ovpnNeedsKeyPassphrase: "key passphrase required"
        case .ovpnConfigError: "OpenVPN rejected the config"
        case .ovpnUnsupportedPrompt: "OpenVPN asked for something Wayfork cannot provide"
        case .ovpnExited: "OpenVPN exited (automatic reconnect is off)"
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

/// What the ✎ / "Show Log" button next to a failure does.
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
    /// Green filled: connected / ready.
    case up
    /// Grey hollow: disabled / not running.
    case idle
    /// Orange half: connecting / reconnecting.
    case transitioning
    /// Red cross: failed.
    case failed
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
    /// Line 2 of the card, e.g. `connected · 10.8.0.6 on utun101 · 3 rules`.
    public var detail: String
    public var isError: Bool
    public var isDimmed: Bool
    public var action: TunnelCardAction?

    public init(
        glyph: StatusGlyph, detail: String, isError: Bool = false, isDimmed: Bool = false,
        action: TunnelCardAction? = nil
    ) {
        self.glyph = glyph
        self.detail = detail
        self.isError = isError
        self.isDimmed = isDimmed
        self.action = action
    }
}

/// User-facing strings derived from store + runtime status (docs/design/02-ux.md).
public enum StatusText {
    // MARK: - Failures

    /// `failed: <message>` for tunnel codes; the catalogue message for engine/helper codes;
    /// `failed: <code>` for anything unknown.
    public static func failureMessage(code: String) -> String {
        guard let known = FailureCode(rawValue: code) else { return "failed: \(code)" }
        return known.rawValue.hasPrefix("ovpn.") ? "failed: \(known.message)" : known.message
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
        let defaultTunnel = effectiveDefaultTunnel(store, missingSecrets: missingSecrets)
        switch state {
        case .off:
            return "Off — all traffic goes direct"
        case .starting:
            return "Starting…"
        case .stopping:
            return "Stopping…"
        case .error:
            return "Routing engine failed — see Logs"
        case .on:
            let tunnels = store.tunnels.filter(\.isEnabled).count
            guard tunnels > 0 else { return "On — no tunnels" }
            if let defaultTunnel {
                return
                    "On — everything via \(defaultTunnel.name) · \(count(activeRuleCount(store), "rule")), \(count(activeExceptionCount(store), "exception"))"
            }
            return
                "On — routing \(count(activeRuleCount(store), "domain")) through \(count(tunnels, "tunnel"))"
        case .degraded(let failing):
            if let defaultTunnel, failing.contains(defaultTunnel.id) {
                return
                    "Degraded — \(defaultTunnel.name) (default) is down · unmatched traffic is blocked"
            }
            let names = failing.compactMap { store.tunnel(id: $0)?.name }
            let verb = names.count == 1 ? "is" : "are"
            let subject = names.isEmpty ? "a tunnel" : names.joined(separator: ", ")
            let enabled = store.tunnels.filter(\.isEnabled).count
            let up = max(0, enabled - failing.count)
            return
                "Degraded — \(subject) \(verb) failing · \(count(activeRuleCount(store), "domain")), \(count(up, "tunnel")) up"
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

    /// Card / row suffix for the default tunnel.
    static let defaultSuffix = " · everything else"

    // MARK: - Tunnel cards and rows

    /// Popover card for one tunnel.
    public static func card(
        tunnel: Tunnel, state: TunnelState?, global: GlobalState, ruleCount: Int,
        missingSecret: Bool = false, isDefault: Bool = false
    ) -> TunnelPresentation {
        let rules = count(ruleCount, "rule") + (isDefault ? defaultSuffix : "")
        if !tunnel.isEnabled {
            return TunnelPresentation(
                glyph: .idle, detail: "disabled · \(rules)", isDimmed: true, action: .enable)
        }
        if missingSecret {
            let what = tunnel.kind.isOpenVPN ? "config" : "UUID"
            return TunnelPresentation(
                glyph: .failed, detail: "\(what) missing · \(rules)", isError: true,
                action: .edit(tunnel.kind.isOpenVPN ? .replaceConfig : .replaceConfig))
        }
        switch global {
        case .off, .stopping:
            return TunnelPresentation(
                glyph: .idle, detail: "not running · \(rules)", isDimmed: true)
        case .error:
            return TunnelPresentation(glyph: .idle, detail: "not routed · \(rules)", isDimmed: true)
        case .starting, .on, .degraded:
            break
        }
        guard tunnel.kind.isOpenVPN else {
            let host = tunnel.kind.vless?.server ?? ""
            return TunnelPresentation(glyph: .up, detail: "ready · \(host) · \(rules)")
        }
        switch state {
        case .none, .disabled:
            return TunnelPresentation(glyph: .transitioning, detail: "connecting…")
        case .connecting(let attempt):
            return TunnelPresentation(
                glyph: .transitioning, detail: "connecting… attempt \(attempt)",
                action: .reconnect)
        case .reconnecting(let attempt, _, let reason):
            var detail = "reconnecting… attempt \(attempt)"
            if let reason, !reason.isEmpty { detail += " · \(reason)" }
            return TunnelPresentation(glyph: .transitioning, detail: detail, action: .reconnect)
        case .connected(_, let ip, let interface):
            var detail = "connected · "
            if let ip, !ip.isEmpty { detail += "\(ip) on " }
            detail += "\(interface) · \(rules)"
            return TunnelPresentation(glyph: .up, detail: detail, action: .reconnect)
        case .failed(let reason, _):
            return TunnelPresentation(
                glyph: .failed, detail: failureMessage(code: reason), isError: true,
                action: .edit(failureAction(code: reason) ?? .showLog))
        }
    }

    /// One-line summary for a Settings › Tunnels row, e.g.
    /// `connected · vpn.example.com:1194 udp · 10.8.0.6 on utun101`.
    public static func rowSummary(
        tunnel: Tunnel, state: TunnelState?, global: GlobalState, missingSecret: Bool = false,
        isDefault: Bool = false
    ) -> (text: String, glyph: StatusGlyph, isError: Bool) {
        let endpoint = endpointDescription(tunnel.kind) + (isDefault ? defaultSuffix : "")
        if !tunnel.isEnabled { return ("disabled · \(endpoint)", .idle, false) }
        if missingSecret {
            let what = tunnel.kind.isOpenVPN ? "config missing" : "UUID missing"
            return ("\(what) · \(endpoint)", .failed, true)
        }
        guard global.isRunning || global == .starting else {
            return ("not running · \(endpoint)", .idle, false)
        }
        guard tunnel.kind.isOpenVPN else { return ("ready · \(endpoint)", .up, false) }
        switch state {
        case .none, .disabled, .connecting:
            return ("connecting… · \(endpoint)", .transitioning, false)
        case .reconnecting(let attempt, _, let reason):
            var text = "reconnecting… attempt \(attempt)"
            if let reason, !reason.isEmpty { text += " · \(reason)" }
            return (text, .transitioning, false)
        case .connected(_, let ip, let interface):
            var text = "connected · \(endpoint)"
            if let ip, !ip.isEmpty {
                text += " · \(ip) on \(interface)"
            } else {
                text += " · \(interface)"
            }
            return (text, .up, false)
        case .failed(let reason, _):
            return (failureMessage(code: reason), .failed, true)
        }
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
        }
    }

    public static func typeBadge(_ kind: TunnelKind) -> String {
        kind.isOpenVPN ? "OpenVPN" : "VLESS"
    }

    /// `1 rule`, `3 rules`.
    public static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
