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
            if model.guideState.showsCard {
                GettingStartedCardView()
            }
            if model.store.tunnels.isEmpty {
                if let step = model.guideState.resumeStep {
                    // No tunnels: the guide resumes at Add a VPN at the latest (AppModel.openGuide).
                    resumeState(step.isAfter(.addVPN) ? .addVPN : step)
                } else {
                    emptyState
                }
                if !model.store.lists.isEmpty {
                    SizedScrollView(maxHeight: listMaxHeight) { PopoverRuleLists() }
                    QuickAddView()
                }
            } else if enabledTunnels.isEmpty && enabledGroups.isEmpty {
                SizedScrollView(maxHeight: listMaxHeight) {
                    VStack(alignment: .leading, spacing: 10) {
                        allDisabledState
                        PopoverRuleLists()
                    }
                }
                QuickAddView()
            } else {
                // Many tunnels plus Recent outgrow the screen; the list scrolls so the
                // quick add and the footer stay in reach.
                SizedScrollView(maxHeight: listMaxHeight) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tunnels")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                        ForEach(enabledTunnels) { tunnel in
                            TunnelCardView(tunnel: tunnel)
                        }
                        ForEach(enabledGroups) { group in
                            GroupCardView(group: group)
                        }
                        if model.globalState.isRunning {
                            DirectRowView()
                            Divider()
                        }
                        PopoverRuleLists()
                        if model.globalState.isRunning {
                            RecentSectionView()
                        }
                    }
                }
                Divider()
                QuickAddView()
            }
            ListRouteUndoView()
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    /// The list's ceiling: the screen minus the menu bar, the header, the quick add and
    /// the footer (up to about 300 pt of chrome with the failed line and the guide card),
    /// between 240 and 560 pt. The screen is the one under the pointer — the one whose menu
    /// bar was clicked; `NSScreen.main` follows the key window, often another display.
    private var listMaxHeight: CGFloat {
        let pointer = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let height = screen?.visibleFrame.height ?? 800
        return min(560, max(240, height - 300))
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
            // F19: one red line while something failed in the last 5 minutes.
            if model.recentFailedCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(FailedText.popoverLine(count: model.recentFailedCount))
                    Spacer()
                    Button("Show") { model.openLogs() }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .medium))
                }
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .padding(.leading, 26)
            }
        }
    }

    /// Disabled tunnels are managed in Settings; the popover only lists enabled ones.
    private var enabledTunnels: [Tunnel] { model.store.tunnels.filter(\.isEnabled) }
    /// Group cards follow the tunnel cards (F16).
    private var enabledGroups: [TunnelGroup] { model.store.groups.filter(\.isEnabled) }

    private var allDisabledState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Every tunnel is off.").font(.system(size: 12))
            Button("Manage tunnels…") { model.openSettings(section: .tunnels) }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    /// C12·c: the no-tunnels popover once the guide window was closed without an outcome.
    private func resumeState(_ step: GuideStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Finish setting up Wayfork")
                .font(.system(size: 14, weight: .semibold))
            Text("You stopped at \(GuideStrings.railTitle(step)).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Continue setup") { model.openGuide() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            Text("or drop a .ovpn file on this window")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
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
            FooterButton(title: ExitsText.footerTitle, shortcut: ExitsText.footerShortcut) {
                model.openLogs(connections: true)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Spacer()
            FooterButton(title: "Quit", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.system(size: 12))
    }
}

/// The content at its natural height while it fits `maxHeight`; a scroll view of exactly
/// `maxHeight` once it does not. A plain `ScrollView` cannot do this in the menu bar
/// window: the window sizes itself to the content's ideal height, and an unconstrained
/// scroll view takes whatever it is offered. The layout asks the scroll view for its ideal
/// height (its content's) and caps it; measuring through a preference never shrank the
/// window.
private struct SizedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        CappedHeightLayout(maxHeight: maxHeight) {
            ScrollView(.vertical) { content }
        }
    }
}

private struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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
        let latency = model.latency(for: tunnel)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StatusGlyphView(glyph: card.glyph)
                Text(tunnel.name).fontWeight(.semibold).lineLimit(1)
                if card.isDefault { AccentBadge(text: "Default") }
                Spacer(minLength: 4)
                if showsLatency(card) {
                    LatencyLabel(sample: latency)
                    if let latency { SparklineView(sample: latency) }
                }
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
                let lists = model.listNames(using: .tunnel(tunnel.id))
                if !lists.isEmpty {
                    separator
                    Text(lists).help("Lists: \(lists)")
                }
                // F20: a link to the Connections view while this exit's connections have
                // failed in the last 5 minutes.
                if model.globalState.isRunning, model.exitHasRecentFailures(id: tunnel.id) {
                    separator
                    Button("Details") { model.openLogs(connections: true) }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .medium))
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

    /// Latency for connected and unreachable tunnels while routing is on (F14).
    private func showsLatency(_ card: TunnelPresentation) -> Bool {
        model.globalState.isRunning && (card.glyph == .up || card.status == "Not reachable")
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

/// One group card (F16): accent square glyph, `Group` badge, the active member's latency
/// and sparkline, the group's own rates, then one line per member.
struct GroupCardView: View {
    @Environment(AppModel.self) private var model
    let group: TunnelGroup

    var body: some View {
        let card = model.groupCard(for: group)
        let counters = model.trafficCounters(for: group)
        let latency = model.latency(for: group)
        let running = model.globalState.isRunning && card.glyph == .group
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StatusGlyphView(glyph: card.glyph)
                Text(group.name).fontWeight(.semibold).lineLimit(1)
                AccentBadge(text: "Group")
                if card.isDefault { AccentBadge(text: "Default") }
                Spacer(minLength: 4)
                if running {
                    LatencyLabel(sample: latency)
                    if let latency { SparklineView(sample: latency) }
                }
                if card.actions.contains(.enable) {
                    Button("Enable") { model.setEnabled(groupID: group.id, true) }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 4) {
                Text(card.status)
                    .fontWeight(.medium)
                    .foregroundStyle(card.isError ? Color.red : Color.primary)
                if running, counters?.isIdle == true {
                    Text("·")
                    Text("Idle")
                } else if running {
                    Text("·")
                    RateLabel(counters: counters)
                }
                if !card.detail.isEmpty {
                    Text("·")
                    Text(card.detail)
                }
                let lists = model.listNames(using: .group(group.id))
                if !lists.isEmpty {
                    Text("·")
                    Text(lists).help("Lists: \(lists)")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(card.isError ? Color.red : Color.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, 17)
            if !card.isDimmed {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.groupMembers(for: group)) { row in
                        GroupMemberRowView(row: row, showsLatency: model.globalState.isRunning)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 17)
                .padding(.top, 2)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        )
        .opacity(card.isDimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.openSettings(section: .tunnels, tunnel: group.id) }
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

/// **Recent** (F15): up to five domains that went the default way, newest first, each
/// with a *Route via ▾* menu; × on hover hides a row for the session.
struct RecentSectionView: View {
    @Environment(AppModel.self) private var model
    static let rowLimit = 5

    var body: some View {
        let rows = model.recentHosts
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Recent").font(.system(size: 11, weight: .semibold))
                if !rows.isEmpty {
                    Text("— went \(went), last \(Int(AppModel.recentWindow) / 60) min")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(min(rows.count, Self.rowLimit)) of \(rows.count)")
                        .font(.system(size: 11)).monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            if rows.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(.tertiary)
                    Text(
                        "Sites you open from now on show up here — the ones that went \(went) because no rule said otherwise. One click sends any of them through another tunnel."
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            } else {
                ForEach(rows.prefix(Self.rowLimit)) { row in
                    RecentRowView(row: row)
                }
            }
        }
    }

    private var went: String {
        model.recentExitName.map { "via \($0)" } ?? "direct"
    }
}

/// One Recent row: app icon, domain, app name, *Route via ▾*, × on hover.
struct RecentRowView: View {
    @Environment(AppModel.self) private var model
    let row: RecentHost
    @State private var hovering = false

    var body: some View {
        let process = AppModel.recentProcess(row.processPath)
        HStack(spacing: 8) {
            Image(nsImage: process.icon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(row.host)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(process.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            RouteViaMenu(host: row.host)
            Button {
                model.hideRecent(row.host)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(hovering ? 1 : 0)
            .help("Hide until the next Turn On")
        }
        .padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        .background(
            RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { hovering = $0 }
    }
}

/// `Route via ▾`: the tunnels a row can go to; creates a suffix rule for the registrable
/// domain (the menu's header says which).
struct RouteViaMenu: View {
    @Environment(AppModel.self) private var model
    let host: String
    @State private var error: String?
    @State private var showNewList = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Menu {
                Text("Add \(model.recentRulePattern(host)) to list…")
                let preferred = model.preferredRuleListID
                ForEach(
                    model.store.lists.sorted { lhs, rhs in
                        if lhs.id == rhs.id { return false }
                        if lhs.id == preferred { return true }
                        if rhs.id == preferred { return false }
                        return (model.store.lists.firstIndex { $0.id == lhs.id } ?? 0)
                            < (model.store.lists.firstIndex { $0.id == rhs.id } ?? 0)
                    }
                ) { list in
                    Button("\(list.name) · \(model.listTargetName(list.target))") {
                        error = model.quickAdd(
                            input: model.recentRulePattern(host), listID: list.id)
                        if error == nil {
                            model.hideRecent(host)
                            model.tickGuideCard(.popoverRule)
                        }
                    }
                }
                Divider()
                Button("New list…") {
                    model.pendingListInput = model.recentRulePattern(host)
                    showNewList = true
                }
            } label: {
                Text("Add to list")
            }
            .controlSize(.small).fixedSize()
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showNewList) { NewRuleListSheet() }
    }
}

/// Quick add is scoped to a source list; equal patterns elsewhere stay untouched.
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var listID: UUID?
    @State private var error: String?
    @State private var showNewList = false

    private var isUpdate: Bool {
        guard let listID else { return false }
        if case .update = QuickAdd.evaluate(input: input, listID: listID, store: model.store) {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Site to route, e.g. example.com", text: $input)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .invalidOutline(error != nil).onSubmit(submit)
                if !model.store.lists.isEmpty {
                    Picker("List", selection: $listID) {
                        ForEach(model.store.lists) { list in
                            Text(list.name).tag(Optional(list.id))
                        }
                    }.labelsHidden().controlSize(.small).frame(maxWidth: 110)
                }
                Button(
                    model.store.lists.isEmpty ? "New list…" : (isUpdate ? "Update" : "Add"),
                    action: submit
                )
                .controlSize(.small)
                .disabled(
                    !model.store.lists.isEmpty && input.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
            if isUpdate {
                Text("Update in this list · uses the list route").font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
        }
        .onAppear {
            listID = model.preferredRuleListID
            if input.isEmpty,
                let candidate = QuickAdd.clipboardCandidate(
                    NSPasteboard.general.string(forType: .string))
            {
                input = candidate
            }
        }
        .onChange(of: input) {
            error = nil
            if case .pattern(let pattern, _)? = FakeIP.translate(input, index: model.fakeIPs) {
                input = pattern
            }
        }
        .onChange(of: model.store.lists.map(\.id)) {
            if listID.flatMap({ model.store.list(id: $0) }) == nil {
                listID = model.preferredRuleListID
            }
        }
        .sheet(isPresented: $showNewList) { NewRuleListSheet() }
    }

    private func submit() {
        guard !model.store.lists.isEmpty, let listID else {
            model.pendingListInput = input
            showNewList = true
            return
        }
        error = model.quickAdd(input: input, listID: listID)
        if error == nil {
            input = ""
            model.tickGuideCard(.popoverRule)
        }
    }
}

struct PopoverRuleLists: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.store.lists.count >= 2 {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Lists").font(.system(size: 11, weight: .semibold)).foregroundStyle(
                        .secondary)
                    Spacer()
                    Button("Manage…") { model.openSettings(section: .rules) }.buttonStyle(.link)
                        .font(.system(size: 11))
                }
                ForEach(model.menuRuleLists) { list in
                    HStack(spacing: 6) {
                        ListIcon(list: list)
                        Text(list.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !list.isEnabled {
                            Text("Paused").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        ListExitMenu(target: list.target) { model.changeListRoute(list.id, to: $0) }
                            .frame(maxWidth: 180)
                    }
                    .opacity(list.isEnabled ? 1 : 0.55)
                    .contextMenu {
                        Button(list.isEnabled ? "Pause list" : "Enable list") {
                            _ = model.editRuleList(list.id) { $0.isEnabled.toggle() }
                        }
                    }
                }
                let more = model.store.lists.filter(\.showInMenu).count - model.menuRuleLists.count
                if more > 0 {
                    Button("\(more) more in Settings…") { model.openSettings(section: .rules) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
    }
}
