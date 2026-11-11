import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WayforkCore

/// Settings › Rules: source lists in user priority, independent of their exits.
struct RulesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewList = false
    @State private var search = ""
    @State private var selectedRules: Set<UUID> = []
    @State private var editing: RuleEditState?
    @State private var error: String?

    private var results: [Rule] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.store.lists.flatMap { model.store.rules(in: $0.id) }.filter { rule in
            rule.pattern.lowercased().contains(needle)
                || (rule.note ?? "").lowercased().contains(needle)
                || (rule.isApp
                    && AppBundleInfo.info(for: rule.pattern).name.lowercased().contains(needle))
                || (rule.listID.flatMap { model.store.list(id: $0)?.name.lowercased() } ?? "")
                    .contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PageTitle(text: "Rules")
                Spacer()
                TextField("Search sites and apps", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                Button {
                    showNewList = true
                } label: {
                    Label("New list", systemImage: "plus")
                }
            }
            EverythingElseLine()
            HStack {
                Text("Rule lists")
                Spacer()
                Text("Matched from top to bottom")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if results.isEmpty {
                            Text("No matching rules").foregroundStyle(.secondary).padding()
                        }
                        ForEach(results) { rule in
                            if let list = rule.listID.flatMap({ model.store.list(id: $0) }) {
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack {
                                        ListIcon(list: list)
                                        Text("\(list.name) → \(model.listTargetName(list.target))")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                        Spacer()
                                    }.padding(.horizontal, 12).padding(.vertical, 4)
                                    row(rule, list: list)
                                }.background(GroupBackground())
                            }
                        }
                    } else {
                        if model.globalState.isRunning { RecentStripView() }
                        if model.store.lists.isEmpty {
                            Text("Create a list for sites and apps that share a route.")
                                .foregroundStyle(.secondary).padding(.vertical, 16)
                        }
                        ForEach(model.store.lists) { list in
                            RuleListCard(
                                list: list, selectedRules: $selectedRules, editing: $editing,
                                error: $error)
                        }
                        Text("Direct exceptions first, then lists top to bottom and rows in order.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .dropDestination(for: String.self) { items, _ in
                                guard let value = items.first, value.hasPrefix("list:"),
                                    let id = UUID(uuidString: String(value.dropFirst(5)))
                                else { return false }
                                model.update { try? $0.reorderList(id, to: $0.lists.count - 1) }
                                return true
                            }
                    }
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            ListRouteUndoView()
        }
        .padding(20).frame(minWidth: 800).focusable().focusEffectDisabled()
        .onDeleteCommand {
            guard editing == nil else { return }
            model.update { $0.rules.removeAll { selectedRules.contains($0.id) } }
            selectedRules = []
        }
        .sheet(isPresented: $showNewList) { NewRuleListSheet() }
    }

    private func row(_ rule: Rule, list: RuleList) -> some View {
        RuleRowView(
            rule: rule, group: list, issues: model.ruleIssues[rule.id] ?? [],
            isSelected: selectedRules.contains(rule.id),
            editing: Binding(
                get: { editing?.ruleID == rule.id ? editing : nil }, set: { editing = $0 }),
            error: $error, selectedRules: $selectedRules,
            select: { selectRule(rule.id, in: &selectedRules) })
    }
}

struct RuleEditState: Equatable {
    var ruleID: UUID?
    var listID: UUID
    var text: String
    var match: RuleMatch
    var network: RuleNetwork? = nil
}

@MainActor
private func selectRule(_ id: UUID, in selected: inout Set<UUID>) {
    if NSEvent.modifierFlags.contains(.command) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    } else {
        selected = [id]
    }
}

private struct RecentStripView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if model.recentHosts.isEmpty {
                Text("Nothing new in the last 5 min").font(.system(size: 11)).foregroundStyle(
                    .secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) { ForEach(model.recentHosts) { RecentRowView(row: $0) } }
                }
                .frame(maxHeight: 160)
            }
        } label: {
            HStack {
                Image(systemName: "clock")
                Text("Recent").fontWeight(.semibold)
                Text("\(model.recentHosts.count) · last 5 min — add to a list")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10).background(GroupBackground())
    }
}

private struct RuleListCard: View {
    @Environment(AppModel.self) private var model
    let list: RuleList
    @Binding var selectedRules: Set<UUID>
    @Binding var editing: RuleEditState?
    @Binding var error: String?
    @State private var expanded = false
    @State private var renaming = false
    @State private var name = ""

    private var rows: [Rule] { model.store.rules(in: list.id) }
    private var adding: Bool { editing?.ruleID == nil && editing?.listID == list.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                RuleColumnHeader()
                ForEach(rows) { rule in
                    Divider()
                    RuleRowView(
                        rule: rule, group: list, issues: model.ruleIssues[rule.id] ?? [],
                        isSelected: selectedRules.contains(rule.id),
                        editing: Binding(
                            get: { editing?.ruleID == rule.id ? editing : nil },
                            set: { editing = $0 }),
                        error: $error, selectedRules: $selectedRules,
                        select: { selectRule(rule.id, in: &selectedRules) }
                    )
                    .draggable(dragPayload(rule.id))
                    .dropDestination(for: String.self) { items, _ in
                        move(items, before: rule.id)
                    }
                }
                Divider()
                if adding {
                    NewRuleRow(editing: $editing, error: $error, listID: list.id)
                } else {
                    HStack {
                        Menu {
                            Button("Site or IP address") {
                                error = nil
                                editing = RuleEditState(
                                    ruleID: nil, listID: list.id, text: "", match: .suffix)
                            }
                            Button("Application…") { chooseApplication() }
                        } label: {
                            Label("Add site or app", systemImage: "plus")
                        }
                        .menuIndicator(.hidden).controlSize(.small)
                        Spacer()
                        if rows.isEmpty {
                            Text("No rules yet").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .background(GroupBackground())
        .opacity(list.isEnabled ? 1 : 0.55)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 10)
                }.buttonStyle(.plain)
                Menu {
                    ListColorChoices { color in
                        error = model.editRuleList(list.id) { $0.color = color }
                    }
                } label: {
                    ListIcon(list: list)
                }.menuStyle(.borderlessButton).frame(width: 24)
                if renaming {
                    TextField("List name", text: $name).textFieldStyle(.roundedBorder)
                        .onSubmit {
                            error = model.editRuleList(list.id) {
                                $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            if error == nil { renaming = false }
                        }.onExitCommand { renaming = false }
                } else {
                    Text(list.name).fontWeight(.semibold).lineLimit(1).help(list.name)
                        .onTapGesture(count: 2) {
                            name = list.name
                            renaming = true
                        }
                }
                Text(StatusText.count(rows.count, "rule"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 2)
                ListExitMenu(
                    target: list.target, select: { model.changeListRoute(list.id, to: $0) }
                )
                .frame(width: 180)
                Toggle(
                    "List enabled",
                    isOn: Binding(
                        get: { list.isEnabled },
                        set: { value in error = model.editRuleList(list.id) { $0.isEnabled = value }
                        })
                )
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                Menu {
                    Button("Rename…") {
                        name = list.name
                        renaming = true
                    }
                    Toggle(
                        "Show in menu bar",
                        isOn: Binding(
                            get: { list.showInMenu },
                            set: { value in
                                error = model.editRuleList(list.id) { $0.showInMenu = value }
                            }))
                    Divider()
                    Button("Delete list…", role: .destructive) { model.deleteRuleList(list.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }.menuIndicator(.hidden).fixedSize()
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .draggable("list:\(list.id.uuidString)").help("Drag to reorder lists")
            }
            if !list.isEnabled {
                Text("Paused — other lists, then Everything else").font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let warning = model.listExitWarning(model.store.resolvedTarget(list.target)) {
                Text("Exit \(warning)").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            if let value = items.first, value.hasPrefix("list:"),
                let id = UUID(uuidString: String(value.dropFirst(5)))
            {
                model.reorderRuleList(id, before: list.id)
                return true
            }
            return move(items, before: nil)
        }
    }

    private func dragPayload(_ id: UUID) -> String {
        let ids = selectedRules.contains(id) ? selectedRules : [id]
        return "rows:" + ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private func move(_ items: [String], before target: UUID?) -> Bool {
        guard let value = items.first, value.hasPrefix("rows:") else { return false }
        let ids = Set(
            value.dropFirst(5).split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        guard !ids.isEmpty else { return false }
        model.moveRules(ids, to: list.id, before: target)
        return true
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = model.addRule(pattern: url.path, match: .app, listID: list.id)
        if error == nil { model.tickGuideCard(.appRule) }
    }
}

private enum RuleColumns {
    static let match: CGFloat = 136
    static let network: CGFloat = 94
    static let traffic: CGFloat = 88
    static let handle: CGFloat = 14
}

private struct RuleColumnHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18, height: 1)
            Text("Site or app").frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            Text("Match").frame(width: RuleColumns.match, alignment: .leading)
            Text("Protocol").frame(width: RuleColumns.network, alignment: .leading)
            Text("Traffic").frame(width: RuleColumns.traffic, alignment: .trailing)
            Color.clear.frame(width: RuleColumns.handle, height: 1)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 24)
        .background(Color.primary.opacity(0.03))
    }
}

/// Observe traffic only in this cell so the rest of the rule editor does not read the
/// once-per-second snapshot. Columns stay fixed as the values change.
private struct RuleTrafficView: View {
    @Environment(AppModel.self) private var model
    let ruleID: UUID

    private var counters: TrafficCounters? {
        guard model.globalState.isRunning else { return nil }
        return model.traffic?.counters(forRule: ruleID)
    }

    var body: some View {
        let sample = counters
        VStack(spacing: 1) {
            rate("↓", value: sample?.downBytesPerSecond)
            rate("↑", value: sample?.upBytesPerSecond)
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(sample == nil || sample?.isIdle == true ? .tertiary : .secondary)
        .frame(width: RuleColumns.traffic)
        .help(
            sample.map(TrafficFormat.tooltip)
                ?? "Per-rule traffic is unavailable while off, without a fresh sample, or with an older helper."
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rule traffic: \(TrafficFormat.rateLabel(sample))")
    }

    private func rate(_ arrow: String, value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(arrow).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(value.map(TrafficFormat.rate) ?? "—")
        }
    }
}

private struct RuleRowView: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    let group: RuleList
    let issues: [RuleIssue]
    let isSelected: Bool
    @Binding var editing: RuleEditState?
    @Binding var error: String?
    @Binding var selectedRules: Set<UUID>
    let select: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false
    @State private var editingNote = false
    @State private var noteDraft = ""

    private var hasDetails: Bool {
        rule.target != nil || !rule.isEnabled || !issues.isEmpty
            || !(rule.note ?? "").isEmpty
            || (rule.isApp && !AppBundleInfo.info(for: rule.pattern).exists)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                    Text(StatusText.matchWord(.app))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: RuleColumns.match, alignment: .leading)
                } else if let binding = Binding($editing) {
                    TextField("example.com or 10.0.0.0/24", text: binding.text)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200, maxWidth: .infinity)
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
                    .frame(width: RuleColumns.match)
                } else {
                    Text(rule.pattern)
                        .font(.system(size: 12, design: .monospaced))
                        .opacity(rule.isEnabled ? 1 : 0.5)
                        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(rule.pattern)
                    Picker(
                        "Match",
                        selection: Binding(
                            get: { rule.match },
                            set: {
                                error = model.updateRule(
                                    id: rule.id, pattern: rule.pattern, match: $0)
                            })
                    ) {
                        ForEach(RuleMatch.typedCases, id: \.self) { Text(matchTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: RuleColumns.match)
                }
                Group {
                    if rule.isApp || rule.isIP {
                        networkPicker
                    } else {
                        Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(width: RuleColumns.network)
                RuleTrafficView(ruleID: rule.id)
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .frame(width: RuleColumns.handle)
                    .opacity(hovered || isSelected ? 1 : 0)
                    .help("Drag to reorder or move to another list")
            }
            if hasDetails {
                HStack(spacing: 8) {
                    if let target = rule.target {
                        Label(
                            target.isDirect ? "Direct" : model.targetName(target),
                            systemImage: "pin"
                        )
                        .font(.system(size: 10)).padding(.horizontal, 5).padding(.vertical, 2)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.5)))
                        .help("Pinned route; switching the list keeps this exit")
                    }
                    chips
                    if let note = rule.note, !note.isEmpty {
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).help(note)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 35)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !rule.isApp { startEditing() } }
        .onTapGesture { select() }
        .onHover { hovered = $0 }
        .popover(isPresented: $editingNote) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Note").fontWeight(.semibold)
                TextField("Optional note", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5)
                HStack {
                    Spacer()
                    Button("Cancel") { editingNote = false }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        model.setRuleNote(id: rule.id, note: noteDraft)
                        editingNote = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(14).frame(width: 300)
        }
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
            Button((rule.note ?? "").isEmpty ? "Add note…" : "Edit note…") {
                noteDraft = rule.note ?? ""
                editingNote = true
            }
            Menu("Move to list") {
                ForEach(model.store.lists.filter { $0.id != group.id }) { other in
                    Button(other.name) {
                        model.moveRules(
                            selectedRules.contains(rule.id) ? selectedRules : [rule.id],
                            to: other.id)
                    }
                }
            }
            Menu("Route this one via") {
                ConcreteExitChoices(selected: rule.target) { model.pinRule(rule.id, to: $0) }
            }
            if rule.target != nil { Button("Use list route") { model.pinRule(rule.id, to: nil) } }
            Divider()
            Button("Delete", role: .destructive) {
                let ids = selectedRules.contains(rule.id) ? selectedRules : [rule.id]
                model.update { $0.rules.removeAll { ids.contains($0.id) } }
                selectedRules.subtract(ids)
            }
        }
    }

    /// F23: which transport the rule covers; app and IP rows only.
    private var networkPicker: some View {
        NetworkPicker(
            selection: Binding(
                get: { rule.network },
                set: { error = model.setNetwork(id: rule.id, $0) }))
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
                    .help("Same pattern and match as an earlier rule of this list")
            case .coversTunnelServer(let name):
                Chip(text: "warning", tint: .red)
                    .help("This covers \(name)'s own server — its traffic would loop")
            case .tunnelDisabled:
                note("inert — \(model.targetName(model.store.target(for: rule))) is off")
            case .missingSecret:
                note("not used — exit needs its secret")
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
        let listName = earlier.listID.flatMap { model.store.list(id: $0)?.name } ?? "earlier list"
        return "never used — \(listName): \(earlier.pattern) has it"
    }

    private func startEditing() {
        error = nil
        editing = RuleEditState(
            ruleID: rule.id, listID: group.id, text: rule.pattern,
            match: rule.match)
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
    let listID: UUID
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
                .frame(width: 180)
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
            .frame(width: 90)
            if editing?.match == .ip {
                NetworkPicker(
                    selection: Binding(
                        get: { editing?.network }, set: { editing?.network = $0 }))
            }
            Text("Enter to add, Esc to discard").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
    }

    private func commit() {
        guard let editing else { return }
        if let message = model.addRule(
            pattern: editing.text, match: editing.match, listID: listID,
            network: editing.network)
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

/// F23: the inline "TCP + UDP / TCP only / UDP only" menu of app and IP rows
/// (docs/design/prototype/variant-c.html#C13). Unnarrowed reads in secondary colour.
private struct NetworkPicker: View {
    @Binding var selection: RuleNetwork?

    var body: some View {
        Picker("Network", selection: $selection) {
            Text("TCP + UDP").tag(RuleNetwork?.none)
            Text("TCP only").tag(RuleNetwork?.some(.tcp))
            Text("UDP only").tag(RuleNetwork?.some(.udp))
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 90)
        .foregroundStyle(selection == nil ? .secondary : .primary)
        .help("UDP carries calls, voice and games; TCP carries everything else.")
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

// Shared with the popover: choosing an exit always goes through the same model edit.
struct ListExitMenu: View {
    @Environment(AppModel.self) private var model
    let target: RuleListTarget
    let select: (RuleListTarget) -> Void

    var body: some View {
        Menu {
            ConcreteExitChoices(
                selected: {
                    if case .exit(let exit) = target { return exit }
                    return nil
                }()
            ) { select(.exit($0)) }
            Divider()
            Button {
                select(.everythingElse)
            } label: {
                Label(
                    "Same as Everything else",
                    systemImage: target == .everythingElse ? "checkmark" : "arrow.turn.down.right")
            }
            Text("Now: \(model.targetName(model.store.resolvedTarget(.everythingElse)))")
        } label: {
            HStack(spacing: 4) {
                if case .everythingElse = target {
                    Text("Everything else")
                } else {
                    Text(model.listTargetName(target)).lineLimit(1)
                }
                if case .exit(.group(let id)) = target,
                    let group = model.store.group(id: id),
                    let member = model.activeMember(of: group)
                {
                    Text(member.name).foregroundStyle(.secondary).font(.system(size: 10)).lineLimit(
                        1)
                }
                if target == .everythingElse {
                    Text(model.targetName(model.store.resolvedTarget(target)))
                        .foregroundStyle(.secondary).font(.system(size: 10)).lineLimit(1)
                }
            }
        }
        .controlSize(.small).fixedSize(horizontal: false, vertical: true)
        .help("Route via · \(model.listTargetName(target))")
    }
}

struct ConcreteExitChoices: View {
    @Environment(AppModel.self) private var model
    let selected: RuleTarget?
    let select: (RuleTarget) -> Void
    private let tunnelLimit = 6

    var body: some View {
        if !model.store.groups.isEmpty {
            Text("Groups")
            ForEach(model.store.groups) { group in
                Button {
                    select(.group(group.id))
                } label: {
                    HStack {
                        Text(exitTitle(group.name, target: .group(group.id)))
                            .foregroundStyle(
                                model.listExitWarning(.group(group.id)) == nil
                                    ? Color.primary : Color.secondary)
                        if let member = model.activeMember(of: group) { Text(member.name) }
                        LatencyLabel(sample: model.latency(for: group))
                    }
                }
            }
            Divider()
        }
        Text("Tunnels")
        ForEach(model.store.tunnels.prefix(tunnelLimit)) { tunnel in tunnelButton(tunnel) }
        if model.store.tunnels.count > tunnelLimit {
            Menu("\(model.store.tunnels.count - tunnelLimit) more…") {
                ForEach(model.store.tunnels.dropFirst(tunnelLimit)) { tunnel in tunnelButton(tunnel)
                }
            }
        }
        Divider()
        Button {
            select(.direct)
        } label: {
            Label("Direct", systemImage: selected == .direct ? "checkmark" : "network")
        }
    }

    private func tunnelButton(_ tunnel: Tunnel) -> some View {
        Button {
            select(.tunnel(tunnel.id))
        } label: {
            HStack {
                Text(exitTitle(tunnel.name, target: .tunnel(tunnel.id)))
                    .foregroundStyle(
                        model.listExitWarning(.tunnel(tunnel.id)) == nil
                            ? Color.primary : Color.secondary)
                LatencyLabel(sample: model.latency(for: tunnel))
            }
        }
    }

    private func exitTitle(_ name: String, target: RuleTarget) -> String {
        (selected == target ? "✓ " : "") + name
            + (model.listExitWarning(target).map { " — \($0)" } ?? "")
    }
}

struct EverythingElseLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text("Everything else").fontWeight(.medium)
            Text("without a matching rule").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ConcreteExitChoices(
                    selected: model.store.defaultTunnelID.map { id in
                        model.store.group(id: id) != nil ? .group(id) : .tunnel(id)
                    } ?? .direct
                ) { model.setDefaultTunnel($0.exitID) }
            } label: {
                Text(
                    model.store.defaultTunnelID.map {
                        model.store.exitName(id: $0) ?? "Missing exit"
                    } ?? "Direct"
                ).lineLimit(1)
                    .help(
                        model.store.defaultTunnelID.flatMap { model.store.exitName(id: $0) }
                            ?? "Direct")
            }.controlSize(.small).frame(width: 180)
            if model.defaultTunnelIssue != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help(
                        model.listExitWarning(
                            model.store.defaultTunnelID.map { id in
                                model.store.group(id: id) != nil ? .group(id) : .tunnel(id)
                            }) ?? "Default exit unavailable")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(GroupBackground())
    }
}

struct ListRouteUndoView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let undo = model.listRouteUndo {
            HStack {
                Text(undo.message).font(.system(size: 11)).lineLimit(1)
                Spacer()
                Button("Undo") { model.undoListRoute() }.buttonStyle(.link)
            }.padding(8).background(GroupBackground())
        }
    }
}

struct ListIcon: View {
    let list: RuleList
    static let colors: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .red, .gray]
    var body: some View {
        let index = list.color ?? Int(list.name.utf8.reduce(0) { ($0 + Int($1)) % 8 })
        Text(String(list.name.prefix(1)).uppercased())
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Self.colors[max(0, min(7, index))], in: RoundedRectangle(cornerRadius: 4))
    }
}

struct ListColorChoices: View {
    let select: (Int?) -> Void
    private let names = ["Orange", "Blue", "Green", "Purple", "Pink", "Teal", "Red", "Gray"]
    var body: some View {
        Button("Automatic color") { select(nil) }
        ForEach(0..<8) { index in Button(names[index]) { select(index) } }
    }
}

struct NewRuleListSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: Int?
    @State private var target: RuleListTarget = .everythingElse
    @State private var input = ""
    @State private var rows: [Rule] = []
    @State private var recentSelection: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New list").font(.system(size: 17, weight: .semibold))
            HStack(spacing: 10) {
                Text("Name").frame(width: 80, alignment: .trailing)
                Menu {
                    ListColorChoices { color = $0 }
                } label: {
                    ListIcon(
                        list: RuleList(
                            name: name.isEmpty ? "L" : name, color: color, target: target))
                }.menuStyle(.borderlessButton).frame(width: 24)
                TextField("e.g. Notion", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Text("Route via").frame(width: 80, alignment: .trailing)
                ListExitMenu(target: target) { target = $0 }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sites and apps").fontWeight(.medium)
                    FlowLayoutChips(
                        tokens: rows.map(\.pattern),
                        remove: { token in
                            rows.removeAll { $0.pattern == token }
                        },
                        hint: { token in
                            rows.first { $0.pattern == token }.map {
                                StatusText.matchWord($0.match)
                            } ?? ""
                        })
                    HStack {
                        TextField("Type a site, IP address, or drop an app", text: $input)
                            .textFieldStyle(.roundedBorder).onSubmit { _ = addInput() }
                            .onChange(of: input) {
                                if input.hasSuffix(",") {
                                    input.removeLast()
                                    _ = addInput()
                                }
                            }
                        Button("Choose App…", action: chooseApps).controlSize(.small)
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        let apps = urls.filter { $0.isFileURL && $0.pathExtension == "app" }
                        for app in apps { _ = addToken(app.path, match: .app) }
                        return !apps.isEmpty
                    }
                    Text("Return or comma adds a token. Domains include their subdomains.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    Text("From Recent — last 5 min").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if model.recentHosts.isEmpty {
                        Text("No recent sites").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(model.recentHosts) { row in
                        Toggle(
                            isOn: Binding(
                                get: { recentSelection.contains(row.host) },
                                set: { selected in
                                    if selected {
                                        recentSelection.insert(row.host)
                                    } else {
                                        recentSelection.remove(row.host)
                                    }
                                })
                        ) {
                            HStack {
                                Text(row.host).lineLimit(1)
                                Spacer()
                                Text(AppModel.recentProcess(row.processPath).name).font(
                                    .system(size: 11)
                                ).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }.padding(2)
            }.frame(maxHeight: 280)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Text("Goes to the top of the list order").font(.system(size: 11)).foregroundStyle(
                    .secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 500)
            .onAppear {
                if !model.pendingListInput.isEmpty {
                    input = model.pendingListInput
                    model.pendingListInput = ""
                }
            }
    }

    private func addInput() -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        if addToken(text, match: RulePattern.inferControlMatch(text)) {
            input = ""
            return true
        }
        return false
    }

    private func addToken(_ text: String, match: RuleMatch) -> Bool {
        var text = text
        var match = match
        var inferred: RuleMatch? = match
        if let message = model.translateFakeIP(&text, match: &inferred) {
            error = message
            return false
        }
        match = inferred ?? match
        do {
            let pattern = try RulePattern.normalize(text, match: match)
            if !rows.contains(where: { $0.pattern == pattern && $0.match == match }) {
                rows.append(Rule(pattern: pattern, match: match))
            }
            error = nil
            return true
        } catch let failure as RulePatternError {
            error = RuleEditing.message(for: failure)
            return false
        } catch {
            self.error = "Invalid rule"
            return false
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { _ = addToken(url.path, match: .app) }
    }

    private func create() {
        guard addInput() else { return }
        for host in recentSelection.sorted() {
            guard addToken(model.recentRulePattern(host), match: .suffix) else { return }
        }
        error = model.createRuleList(name: name, color: color, target: target, rows: rows)
        if error == nil { dismiss() }
    }
}
