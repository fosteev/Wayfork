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
                ForEach(enabledTunnels) { tunnel in
                    TunnelCardView(tunnel: tunnel)
                }
                if model.globalState.isRunning {
                    DirectRowView()
                }
            }
            if !model.globalState.isOff, !enabledTunnels.isEmpty {
                Divider()
                QuickAddView()
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
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
                .disabled(model.transition != nil)
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
            Text("All tunnels are disabled.").font(.system(size: 12))
            Button("Manage tunnels…") { model.openSettings(section: .tunnels) }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No tunnels yet.").font(.system(size: 12))
            Text("Import an OpenVPN config or add a VLESS URL in Settings › Tunnels.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Add a tunnel…") { model.openSettings(section: .tunnels) }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
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

/// One tunnel card: glyph, name, badge, action; state details on the second line.
struct TunnelCardView: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel

    var body: some View {
        let card = model.card(for: tunnel)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StatusGlyphView(glyph: card.glyph)
                Text(tunnel.name).fontWeight(.semibold).lineLimit(1)
                TypeBadge(kind: tunnel.kind)
                Spacer(minLength: 4)
                if showsRate(card) {
                    RateLabel(counters: model.trafficCounters(for: tunnel))
                }
                actionButton(card.action)
            }
            Text(card.detail)
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

    /// Rates only for connected / ready tunnels while routing is on (F9).
    private func showsRate(_ card: TunnelPresentation) -> Bool {
        model.globalState.isRunning && card.glyph == .up
    }

    @ViewBuilder
    private func actionButton(_ action: TunnelCardAction?) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .reconnect:
            Button {
                model.reconnect(tunnel.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Reconnect")
        case .edit(let failure):
            Button {
                model.perform(failure, tunnel: tunnel)
            } label: {
                Image(systemName: failure == .showLog ? "doc.text.magnifyingglass" : "pencil")
            }
            .controlSize(.small)
            .help(failure == .showLog ? "Show Log" : "Fix in Settings")
        case .enable:
            Button("Enable") { model.setEnabled(tunnelID: tunnel.id, true) }
                .controlSize(.small)
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

/// Slim row after the cards: what bypasses the tunnels (F9). No background, no action.
struct DirectRowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 7) {
            Text(
                TrafficFormat.directRowTitle(hasDefaultTunnel: model.effectiveDefaultTunnel != nil)
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer(minLength: 4)
            RateLabel(counters: model.directTraffic)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }
}

/// `[Route domain…] [Tunnel ▾] [Add]` (docs/design/02-ux.md, "Quick add").
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var target: RuleTarget?
    @State private var error: String?

    private var enabledTunnels: [Tunnel] { model.store.tunnels.filter(\.isEnabled) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Route domain or IP…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .invalidOutline(error != nil)
                    .onSubmit(submit)
                Picker("Tunnel", selection: $target) {
                    ForEach(enabledTunnels) { tunnel in
                        Text(tunnel.name).tag(Optional(RuleTarget.tunnel(tunnel.id)))
                    }
                    Divider()
                    Text("Direct").tag(Optional(RuleTarget.direct))
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
        .onChange(of: input) { error = nil }
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
