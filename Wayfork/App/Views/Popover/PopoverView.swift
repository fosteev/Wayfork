import AppKit
import SwiftUI
import WayforkCore

/// The menu bar popover (docs/design/02-ux.md, "Popover").
struct PopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if model.store.tunnels.isEmpty {
                emptyState
            } else if enabledTunnels.isEmpty {
                allDisabledState
            } else {
                Text("Tunnels")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                ForEach(enabledTunnels) { tunnel in
                    TunnelCardView(tunnel: tunnel)
                }
                if model.globalState.isRunning {
                    DirectRowView()
                }
                Divider()
                QuickAddView()
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(model.menuBarIconName)
                    .renderingMode(.template)
                Text("Wayfork").fontWeight(.semibold)
                Spacer()
                Toggle(
                    "Routing",
                    isOn: Binding(get: { model.desiredOn }, set: { _ in model.toggle() })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(model.transition != nil || model.store.tunnels.isEmpty)
            }
            Text(model.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
                .lineLimit(2)
        }
    }

    /// Disabled tunnels are managed in Settings; the popover only lists enabled ones.
    private var enabledTunnels: [Tunnel] { model.store.tunnels.filter(\.isEnabled) }

    private var allDisabledState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Every tunnel is off.").font(.system(size: 12))
            Button("Manage tunnels…") { model.openSettings(section: .tunnels) }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(model.menuBarIconName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(.tertiary)
            Text("Add a VPN you already have")
                .font(.system(size: 14, weight: .semibold))
            Text(
                "An OpenVPN file (.ovpn), a VLESS or WireGuard link, or a subscription URL. Then tell Wayfork which sites go through it — the rest of your traffic is not touched."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
            Button("Add a tunnel…") { model.openSettings(section: .tunnels) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            Text("or drop a .ovpn file on this window")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            FooterButton(title: "Settings", shortcut: "⌘,") {
                model.openSettings(section: model.settingsSection)
            }
            .keyboardShortcut(",", modifiers: .command)
            FooterButton(title: "Logs", shortcut: "⌘L") { model.openLogs() }
                .keyboardShortcut("l", modifiers: .command)
            Spacer()
            FooterButton(title: "Quit", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.system(size: 12))
    }
}

private struct FooterButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text(shortcut).foregroundStyle(.tertiary).font(.system(size: 11))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One tunnel card: glyph, name and actions on line 1; status and facts on line 2.
struct TunnelCardView: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel

    var body: some View {
        let card = model.card(for: tunnel)
        let counters = model.trafficCounters(for: tunnel)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StatusGlyphView(glyph: card.glyph)
                Text(tunnel.name).fontWeight(.semibold).lineLimit(1)
                if card.isDefault { AccentBadge(text: "Default") }
                Spacer(minLength: 4)
                actionButtons(card.actions)
            }
            HStack(spacing: 4) {
                Text(card.status)
                    .fontWeight(.medium)
                    .foregroundStyle(card.isError ? Color.red : Color.primary)
                if showsRate(card), counters?.isIdle == true {
                    separator
                    Text("Idle")
                } else if showsRate(card) {
                    separator
                    RateLabel(counters: counters)
                    if let counters, counters.oneWayUDPFlows > 0 {
                        OneWayUDPHint(count: counters.oneWayUDPFlows)
                    }
                }
                if !card.detail.isEmpty {
                    separator
                    Text(card.detail)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(card.isError ? Color.red : Color.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, 17)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        )
        .opacity(card.isDimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.openSettings(section: .tunnels, tunnel: tunnel.id) }
    }

    private var separator: some View { Text("·") }

    /// Rates only for connected tunnels while routing is on (F9).
    private func showsRate(_ card: TunnelPresentation) -> Bool {
        model.globalState.isRunning && card.glyph == .up
    }

    @ViewBuilder
    private func actionButtons(_ actions: [TunnelCardAction]) -> some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            switch action {
            case .reconnect:
                Button {
                    model.reconnect(tunnel.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Retry")
            case .edit(let failure):
                Button("Fix…") { model.perform(failure, tunnel: tunnel) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open this tunnel in Settings")
            case .enable:
                Button("Enable") { model.setEnabled(tunnelID: tunnel.id, true) }
                    .controlSize(.small)
            }
        }
    }
}

/// `↓ 1.2 MB/s ↑ 85 KB/s` with the session totals as tooltip; `↓ — ↑ —` without a fresh
/// sample. Monospaced digits and fixed formatting keep the card from jittering (F9).
struct RateLabel: View {
    let counters: TrafficCounters?

    var body: some View {
        Text(TrafficFormat.rateLabel(counters))
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(counters?.isIdle == false ? .secondary : .tertiary)
            .lineLimit(1)
            .fixedSize()
            .help(counters.map(TrafficFormat.tooltip) ?? TrafficFormat.staleTooltip)
    }
}

/// Orange ⚠ next to the rates when a tunnel has UDP flows that send but receive nothing —
/// the signature of a server dropping UDP (H3, docs/design/02-ux.md).
struct OneWayUDPHint: View {
    let count: Int

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .help(TrafficFormat.oneWayUDPHint(count))
    }
}

/// Slim row after the cards: what bypasses the tunnels (F9). No background, no action.
struct DirectRowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 7) {
            StatusGlyphView(glyph: .idle)
            Text("Not via any tunnel")
                .font(.system(size: 12, weight: .medium))
            Text("· \(StatusText.count(StatusText.activeExceptionCount(model.store), "site"))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            RateLabel(counters: model.directTraffic)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }
}

/// `[Site to route…] [Tunnel ▾] [Add]` (docs/design/02-ux.md, "Quick add").
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var target: RuleTarget?
    @State private var error: String?

    private var enabledTunnels: [Tunnel] { model.store.tunnels.filter(\.isEnabled) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Site to route, e.g. example.com", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .invalidOutline(error != nil)
                    .onSubmit(submit)
                Picker("Tunnel", selection: $target) {
                    ForEach(enabledTunnels) { tunnel in
                        Text(tunnel.name).tag(Optional(RuleTarget.tunnel(tunnel.id)))
                    }
                    Divider()
                    Text("Not via any tunnel").tag(Optional(RuleTarget.direct))
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 120)
                Button(QuickAdd.isUpdate(input: input, store: model.store) ? "Update" : "Add") {
                    submit()
                }
                .controlSize(.small)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || target == nil)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.leading, 2)
            }
        }
        .onAppear(perform: prefill)
        .onChange(of: input) {
            error = nil
            // A pasted fake IP becomes the wildcard rule of the name behind it (`FakeIP`).
            if case .pattern(let pattern, _)? = FakeIP.translate(input, index: model.fakeIPs) {
                input = pattern
            }
        }
        .onChange(of: enabledTunnels.map(\.id)) { _, ids in
            if let tunnelID = target?.tunnelID, !ids.contains(tunnelID) {
                target = ids.first.map(RuleTarget.tunnel)
            }
            if target == nil { target = ids.first.map(RuleTarget.tunnel) }
        }
    }

    private func prefill() {
        if input.isEmpty,
            let candidate = QuickAdd.clipboardCandidate(
                NSPasteboard.general.string(forType: .string))
        {
            input = candidate
        }
        let ids = enabledTunnels.map(\.id)
        switch model.quickAddTarget {
        case .direct:
            target = .direct
        case .tunnel(let last) where ids.contains(last):
            target = .tunnel(last)
        default:
            target = ids.first.map(RuleTarget.tunnel)
        }
    }

    private func submit() {
        guard let target else { return }
        if let message = model.quickAdd(input: input, target: target) {
            error = message
        } else {
            input = ""
            error = nil
        }
    }
}
