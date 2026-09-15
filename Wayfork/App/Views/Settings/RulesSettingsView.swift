import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WayforkCore

/// Settings › Rules: the Direct group (exceptions, F8) followed by one group per tunnel,
/// inline editing, drag to reorder / move (docs/design/02-ux.md, "Rules").
struct RulesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedRuleID: UUID?
    @State private var editing: RuleEditState?
    @State private var groupErrors: [RuleTarget: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PageTitle(text: "Rules")
                Spacer()
                TextField("Search sites and apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            if model.store.tunnels.isEmpty {
                Text("Add a tunnel first — a rule sends a site through a tunnel.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else if model.store.rules.isEmpty, editing == nil {
                Text(
                    "No sites yet. Everything stays on your normal connection. Add a site here or from the menu bar."
                )
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                ScrollView { groups }
            } else {
                ScrollView { groups }
            }
        }
        .padding(20)
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand {
            guard editing == nil, let selectedRuleID else { return }
            model.removeRule(id: selectedRuleID)
            self.selectedRuleID = nil
        }
    }

    private var groups: some View {
        VStack(spacing: 12) {
            if model.globalState.isRunning {
                RecentStripView()
            }
            RuleGroupView(
                group: .direct, search: search, selectedRuleID: $selectedRuleID,
                editing: $editing, error: groupError(.direct))
            ForEach(model.store.tunnels) { tunnel in
                RuleGroupView(
                    group: .tunnel(tunnel), search: search, selectedRuleID: $selectedRuleID,
                    editing: $editing, error: groupError(.tunnel(tunnel.id)))
            }
        }
    }

    private func groupError(_ target: RuleTarget) -> Binding<String?> {
        Binding(
            get: { groupErrors[target] },
            set: { groupErrors[target] = $0 })
    }
}

/// Row being edited: an existing rule (`ruleID`) or a new one at the end of a group.
struct RuleEditState: Equatable {
    var ruleID: UUID?
    var target: RuleTarget
    var text: String
    var match: RuleMatch
}

/// A group in the Rules list: the Direct group (exceptions) or one tunnel.
private enum RuleGroup: Hashable {
    case direct
    case tunnel(Tunnel)

    var target: RuleTarget {
        switch self {
        case .direct: .direct
        case .tunnel(let tunnel): .tunnel(tunnel.id)
        }
    }

    var name: String {
        switch self {
        case .direct: "Direct"
        case .tunnel(let tunnel): tunnel.name
        }
    }

    var tunnel: Tunnel? {
        if case .tunnel(let tunnel) = self { return tunnel }
        return nil
    }
}

/// **Recent** as a strip above the groups (F15): three rows, *Show all* for the rest;
/// collapses to its header when nothing is new (docs/design/02-ux.md, "Variant C" › Rules).
private struct RecentStripView: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false
    static let rowLimit = 3

    var body: some View {
        let rows = model.recentHosts
        let shown = showAll ? rows : Array(rows.prefix(Self.rowLimit))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Recent").fontWeight(.semibold)
                Text(hint(rows.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if rows.count > Self.rowLimit {
                    Button(showAll ? "Show fewer" : "Show all \(rows.count)") { showAll.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .background(Color.primary.opacity(0.03))
            if !shown.isEmpty {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(shown) { row in
                            Divider()
                            RecentRowView(row: row)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 26)
                        }
                    }
                }
                .frame(maxHeight: showAll ? 200 : .infinity)
            }
        }
        .background(GroupBackground())
    }

    private func hint(_ count: Int) -> String {
        let went = model.recentExitName.map { "via \($0)" } ?? "direct"
        let minutes = Int(AppModel.recentWindow) / 60
        return count == 0
            ? "nothing new in the last \(minutes) min"
            : "went \(went) in the last \(minutes) min — pick a tunnel to make a rule"
    }
}

private struct RuleGroupView: View {
    @Environment(AppModel.self) private var model
    let group: RuleGroup
    let search: String
    @Binding var selectedRuleID: UUID?
    @Binding var editing: RuleEditState?
    @Binding var error: String?

    private var rules: [Rule] { model.store.rules(for: group.target) }

    private var visibleRules: [Rule] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rules }
        return rules.filter { rule in
            rule.pattern.lowercased().contains(needle)
                || (rule.note ?? "").lowercased().contains(needle)
                || (rule.isApp
                    && AppBundleInfo.info(for: rule.pattern).name.lowercased().contains(needle))
        }
    }

    private var isAddingHere: Bool {
        editing?.ruleID == nil && editing?.target == group.target
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(visibleRules) { rule in
                Divider()
                RuleRowView(
                    rule: rule, group: group, issues: model.ruleIssues[rule.id] ?? [],
                    isSelected: selectedRuleID == rule.id,
                    editing: editingBinding(for: rule), error: $error,
                    select: { selectedRuleID = rule.id }
                )
                .draggable(rule.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.compactMap(UUID.init(uuidString:)).first else {
                        return false
                    }
                    model.moveRule(id: dragged, to: group.target, before: rule.id)
                    return true
                }
            }
            if rules.isEmpty, !isAddingHere, group != .direct {
                Divider()
                Text(
                    model.globalState.isRunning
                        ? "No sites yet — add one, or pick a tunnel for a site in Recent above."
                        : "No sites yet — add one with \"Add site\"."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
            if isAddingHere {
                Divider()
                NewRuleRow(editing: $editing, error: $error, target: group.target)
            }
            if let error {
                Divider()
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(EdgeInsets(top: 4, leading: 12, bottom: 6, trailing: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if group == .direct {
                Divider()
                Text(
                    "Local names (.local, .lan, .internal, .home.arpa) are always direct."
                )
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(EdgeInsets(top: 5, leading: 12, bottom: 6, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(GroupBackground())
        .opacity(group.tunnel?.isEnabled == false ? 0.55 : 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let tunnel = group.tunnel {
                    let summary = model.rowSummary(for: tunnel)
                    StatusGlyphView(glyph: summary.glyph)
                    Text(tunnel.name).fontWeight(.semibold)
                    if model.effectiveDefaultTunnel?.id == tunnel.id {
                        AccentBadge(text: "Default")
                    }
                    if let hint = tunnelHint(tunnel, summary: summary) {
                        Text(hint.text)
                            .font(.system(size: 11))
                            .foregroundStyle(hint.isError ? Color.red : Color.secondary)
                            .lineLimit(1)
                    }
                } else {
                    StatusGlyphView(glyph: .idle)
                    Text("Not via any tunnel").fontWeight(.semibold)
                    Text("stay on your normal connection, whatever other rules say")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !search.isEmpty, visibleRules.count != rules.count {
                    Text("\(visibleRules.count) shown").font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                // F10: Site adds an empty row in edit mode; Application… opens a file dialog.
                Menu {
                    Button("Site") {
                        error = nil
                        editing = RuleEditState(
                            ruleID: nil, target: group.target, text: "", match: .suffix)
                    }
                    Button("Application…") { chooseApplication() }
                } label: {
                    Label("Add site", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .controlSize(.small)
                .fixedSize()
                .help(
                    group == .direct
                        ? "Add a site that stays outside every tunnel"
                        : "Add a site to route via \(group.name)")
            }
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .background(Color.primary.opacity(0.03))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.compactMap(UUID.init(uuidString:)).first else { return false }
            model.moveRule(id: dragged, to: group.target, before: nil)
            return true
        }
    }

    /// Header hint after the tunnel name: what happens to its sites right now.
    private func tunnelHint(
        _ tunnel: Tunnel, summary: (text: String, glyph: StatusGlyph, isError: Bool)
    )
        -> (text: String, isError: Bool)?
    {
        if model.effectiveDefaultTunnel?.id == tunnel.id {
            return ("everything without a rule goes here, plus:", false)
        }
        if !tunnel.isEnabled {
            if let fallback = model.effectiveDefaultTunnel {
                return ("off — its sites go via \(fallback.name) for now", false)
            }
            return ("off — its sites stay outside a tunnel for now", false)
        }
        if summary.isError { return ("can't connect — its sites wait", true) }
        return nil
    }

    private func editingBinding(for rule: Rule) -> Binding<RuleEditState?> {
        Binding(
            get: { editing?.ruleID == rule.id ? editing : nil },
            set: { editing = $0 })
    }

    /// Open panel limited to application bundles (docs/design/02-ux.md, F10).
    private func chooseApplication() {
        editing = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message =
            group == .direct
            ? "Choose an application that stays outside every tunnel"
            : "Choose an application to route via \(group.name)"
        panel.prompt = "Add Rule"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = model.addRule(pattern: url.path, match: .app, target: group.target)
    }
}

private struct RuleRowView: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    let group: RuleGroup
    let issues: [RuleIssue]
    let isSelected: Bool
    @Binding var editing: RuleEditState?
    @Binding var error: String?
    let select: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { rule.isEnabled }, set: { model.setRuleEnabled(id: rule.id, $0) })
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            if rule.isApp {
                AppRuleLabel(path: rule.pattern)
                    .frame(width: 230, alignment: .leading)
                Text(StatusText.matchWord(.app))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
            } else if let binding = Binding($editing) {
                TextField("example.com or 10.0.0.0/24", text: binding.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand {
                        editing = nil
                        error = nil
                    }
                    .onAppear { focused = true }
                    .onChange(of: binding.wrappedValue.text) { _, text in
                        if let pattern = fakeIPReplacement(text, model: model) {
                            binding.wrappedValue.text = pattern
                            return
                        }
                        binding.wrappedValue.match = inferredMatch(
                            text, current: binding.wrappedValue.match)
                    }
                Picker("Match", selection: binding.match) {
                    ForEach(RuleMatch.typedCases, id: \.self) { Text(matchTitle($0)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 100)
            } else {
                Text(rule.pattern)
                    .font(.system(size: 12, design: .monospaced))
                    .opacity(rule.isEnabled ? 1 : 0.5)
                    .frame(width: 230, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Picker(
                    "Match",
                    selection: Binding(
                        get: { rule.match },
                        set: {
                            error = model.updateRule(id: rule.id, pattern: rule.pattern, match: $0)
                        })
                ) {
                    ForEach(RuleMatch.typedCases, id: \.self) { Text(matchTitle($0)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 100)
            }
            chips
            TextField(
                "Note",
                text: Binding(
                    get: { rule.note ?? "" }, set: { model.setRuleNote(id: rule.id, note: $0) })
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 160)
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder or move to another group")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !rule.isApp { startEditing() } }
        .onTapGesture { select() }
        .contextMenu {
            if rule.isApp {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: rule.pattern)
                    ])
                }
                .disabled(!AppBundleInfo.info(for: rule.pattern).exists)
            } else {
                Button("Edit") { startEditing() }
            }
            Menu("Move to") {
                if group != .direct {
                    Button("Not via any tunnel") {
                        model.moveRule(id: rule.id, to: .direct, before: nil)
                    }
                }
                ForEach(model.store.tunnels.filter { $0.id != group.tunnel?.id }) { other in
                    Button(other.name) {
                        model.moveRule(id: rule.id, to: .tunnel(other.id), before: nil)
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { model.removeRule(id: rule.id) }
        }
    }

    @ViewBuilder
    private var chips: some View {
        if !rule.isEnabled {
            note("paused")
        }
        if rule.isApp, !AppBundleInfo.info(for: rule.pattern).exists {
            Chip(text: "app not found", tint: .orange)
                .help("\(rule.pattern) is missing; the rule matches again once it is back")
        }
        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
            switch issue {
            case .shadowed(let by):
                note(shadowedNote(by: by))
            case .duplicate:
                Chip(text: "duplicate", tint: .orange)
                    .help("Same pattern and match as an earlier rule of this group")
            case .coversTunnelServer(let name):
                Chip(text: "warning", tint: .red)
                    .help("This covers \(name)'s own server — its traffic would loop")
            case .tunnelDisabled:
                note("paused — \(group.name) is off")
            case .tunnelMissing:
                Chip(text: "no tunnel", tint: .red)
            case .coversLocalNetwork(let interface, let network):
                Chip(text: "warning", tint: .orange)
                    .help(
                        "Covers your LAN (\(interface), \(network)); devices in it go through the tunnel while Wayfork is on"
                    )
            }
        }
    }

    /// 11 pt secondary sentence in place of a chip (docs/design/02-ux.md, "Wording").
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }

    private func shadowedNote(by: UUID) -> String {
        guard let earlier = model.store.rules.first(where: { $0.id == by }) else {
            return "never used — an earlier group has it"
        }
        switch earlier.target {
        case .direct: return "never used — \"Not via any tunnel\" has it"
        case .tunnel(let id): return "never used — \(model.tunnelName(id)) has it"
        }
    }

    private func startEditing() {
        error = nil
        editing = RuleEditState(
            ruleID: rule.id, target: rule.target, text: rule.pattern, match: rule.match)
    }

    private func commit() {
        guard let editing else { return }
        if let message = model.updateRule(id: rule.id, pattern: editing.text, match: editing.match)
        {
            error = message
        } else {
            error = nil
            self.editing = nil
        }
    }
}

/// Empty row in edit mode appended by the group's `+`.
private struct NewRuleRow: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: RuleEditState?
    @Binding var error: String?
    let target: RuleTarget
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 })
    }

    private var match: Binding<RuleMatch> {
        Binding(get: { editing?.match ?? .suffix }, set: { editing?.match = $0 })
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Enabled", isOn: .constant(true)).toggleStyle(.checkbox).labelsHidden()
                .disabled(true)
            TextField("example.com or 10.0.0.0/24", text: text)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .onAppear { focused = true }
                .onChange(of: editing?.text ?? "") { _, value in
                    if let pattern = fakeIPReplacement(value, model: model) {
                        editing?.text = pattern
                        return
                    }
                    editing?.match = inferredMatch(value, current: editing?.match ?? .suffix)
                }
            Picker("Match", selection: match) {
                ForEach(RuleMatch.typedCases, id: \.self) { Text(matchTitle($0)).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 100)
            Text("Enter to add, Esc to discard").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
    }

    private func commit() {
        guard let editing else { return }
        if let message = model.addRule(pattern: editing.text, match: editing.match, target: target)
        {
            error = message
        } else {
            error = nil
            cancel()
        }
    }

    private func cancel() {
        editing = nil
    }
}

private func matchTitle(_ match: RuleMatch) -> String {
    StatusText.matchWord(match)
}

/// A fake IP pasted into a pattern field turns into the wildcard rule of the name behind it
/// (`FakeIP`); nil when the text is anything else or the name is unknown.
@MainActor
private func fakeIPReplacement(_ text: String, model: AppModel) -> String? {
    if case .pattern(let pattern, _)? = FakeIP.translate(text, index: model.fakeIPs) {
        return pattern
    }
    return nil
}

/// Match to use after typing (F11): `*` → wildcard, an address or subnet → IP, and back to
/// suffix when an IP is edited into a name; Exact and Wildcard are otherwise left alone.
private func inferredMatch(_ text: String, current: RuleMatch) -> RuleMatch {
    switch RulePattern.inferMatch(text) {
    case .wildcard: .wildcard
    case .ip: .ip
    default: current == .ip ? .suffix : current
    }
}
