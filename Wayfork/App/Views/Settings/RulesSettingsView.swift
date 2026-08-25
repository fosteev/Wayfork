import SwiftUI
import WayforkCore

/// Settings › Rules: one group per tunnel, inline editing, drag to reorder / move
/// (docs/design/02-ux.md, "Rules").
struct RulesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedRuleID: UUID?
    @State private var editing: RuleEditState?
    @State private var groupErrors: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PageTitle(text: "Rules")
                Spacer()
                TextField("Search domains", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            if model.store.tunnels.isEmpty {
                Text("Add a tunnel first; rules point domains at tunnels.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else if model.store.rules.isEmpty, editing == nil {
                Text(
                    "No rules yet. Everything goes direct. Add a rule here or from the menu bar."
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
            ForEach(model.store.tunnels) { tunnel in
                RuleGroupView(
                    tunnel: tunnel, search: search, selectedRuleID: $selectedRuleID,
                    editing: $editing, error: groupError(tunnel.id))
            }
        }
    }

    private func groupError(_ tunnelID: UUID) -> Binding<String?> {
        Binding(
            get: { groupErrors[tunnelID] },
            set: { groupErrors[tunnelID] = $0 })
    }
}

/// Row being edited: an existing rule (`ruleID`) or a new one at the end of a group.
struct RuleEditState: Equatable {
    var ruleID: UUID?
    var tunnelID: UUID
    var text: String
    var match: RuleMatch
}

private struct RuleGroupView: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel
    let search: String
    @Binding var selectedRuleID: UUID?
    @Binding var editing: RuleEditState?
    @Binding var error: String?

    private var rules: [Rule] { model.store.rules(for: tunnel.id) }

    private var visibleRules: [Rule] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rules }
        return rules.filter {
            $0.pattern.contains(needle) || ($0.note ?? "").lowercased().contains(needle)
        }
    }

    private var isAddingHere: Bool { editing?.ruleID == nil && editing?.tunnelID == tunnel.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(visibleRules) { rule in
                Divider()
                RuleRowView(
                    rule: rule, tunnel: tunnel, issues: model.ruleIssues[rule.id] ?? [],
                    isSelected: selectedRuleID == rule.id,
                    editing: editingBinding(for: rule), error: $error,
                    select: { selectedRuleID = rule.id }
                )
                .draggable(rule.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.compactMap(UUID.init(uuidString:)).first else {
                        return false
                    }
                    model.moveRule(id: dragged, toTunnel: tunnel.id, before: rule.id)
                    return true
                }
            }
            if isAddingHere {
                Divider()
                NewRuleRow(editing: $editing, error: $error, tunnelID: tunnel.id)
            }
            if let error {
                Divider()
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(EdgeInsets(top: 4, leading: 12, bottom: 6, trailing: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(GroupBackground())
        .opacity(tunnel.isEnabled ? 1 : 0.55)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusGlyphView(glyph: model.rowSummary(for: tunnel).glyph)
            Text(tunnel.name).fontWeight(.semibold)
            TypeBadge(kind: tunnel.kind)
            Chip(text: StatusText.count(rules.count, "rule"))
            if !search.isEmpty, visibleRules.count != rules.count {
                Text("\(visibleRules.count) shown").font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                error = nil
                editing = RuleEditState(ruleID: nil, tunnelID: tunnel.id, text: "", match: .suffix)
            } label: {
                Image(systemName: "plus")
            }
            .controlSize(.small)
            .help("Add a rule to \(tunnel.name)")
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .background(Color.primary.opacity(0.03))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.compactMap(UUID.init(uuidString:)).first else { return false }
            model.moveRule(id: dragged, toTunnel: tunnel.id, before: nil)
            return true
        }
    }

    private func editingBinding(for rule: Rule) -> Binding<RuleEditState?> {
        Binding(
            get: { editing?.ruleID == rule.id ? editing : nil },
            set: { editing = $0 })
    }
}

private struct RuleRowView: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    let tunnel: Tunnel
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
            if let binding = Binding($editing) {
                TextField("domain", text: binding.text)
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
                        if text.contains("*") { binding.wrappedValue.match = .wildcard }
                    }
                Picker("Match", selection: binding.match) {
                    ForEach(RuleMatch.allCases, id: \.self) { Text(matchTitle($0)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 100)
            } else {
                Text(rule.pattern)
                    .font(.system(size: 12, design: .monospaced))
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
                    ForEach(RuleMatch.allCases, id: \.self) { Text(matchTitle($0)).tag($0) }
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
                .help("Drag to reorder or move to another tunnel")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startEditing() }
        .onTapGesture { select() }
        .contextMenu {
            Button("Edit") { startEditing() }
            Menu("Move to") {
                ForEach(model.store.tunnels.filter { $0.id != tunnel.id }) { other in
                    Button(other.name) {
                        model.moveRule(id: rule.id, toTunnel: other.id, before: nil)
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
            Chip(text: "paused")
        }
        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
            switch issue {
            case .shadowed(let by):
                Chip(text: "shadowed", tint: .orange)
                    .help(
                        "\(rule.pattern) is already routed via \(model.store.rules.first { $0.id == by }.map { model.tunnelName($0.tunnelID) } ?? "an earlier tunnel")"
                    )
            case .duplicate:
                Chip(text: "duplicate", tint: .orange)
                    .help("Same pattern and match as an earlier rule of this tunnel")
            case .coversTunnelServer(let name):
                Chip(text: "warning", tint: .red)
                    .help("This pattern covers the server of \(name); its own traffic would loop")
            case .tunnelDisabled:
                Text("tunnel disabled — goes direct").font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .tunnelMissing:
                Chip(text: "no tunnel", tint: .red)
            }
        }
    }

    private func startEditing() {
        error = nil
        editing = RuleEditState(
            ruleID: rule.id, tunnelID: rule.tunnelID, text: rule.pattern, match: rule.match)
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
    let tunnelID: UUID
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
            TextField("example.com", text: text)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .onAppear { focused = true }
                .onChange(of: editing?.text ?? "") { _, value in
                    if value.contains("*") { editing?.match = .wildcard }
                }
            Picker("Match", selection: match) {
                ForEach(RuleMatch.allCases, id: \.self) { Text(matchTitle($0)).tag($0) }
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
        if let message = model.addRule(
            pattern: editing.text, match: editing.match, tunnelID: tunnelID)
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
    switch match {
    case .suffix: "Suffix"
    case .exact: "Exact"
    case .wildcard: "Wildcard"
    }
}
