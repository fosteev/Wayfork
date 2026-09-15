import AppKit
import SwiftUI
import WayforkCore

// Settings › Tunnels, the group rows (F16, docs/design/02-ux.md, "Variant C" › Settings ›
// Tunnels; boards C3 and C7).

/// Header row of a group: accent square, name, `Group · fastest of A, B · using A · N sites`,
/// the active member's latency, enabled toggle, chevron.
struct GroupRowView: View {
    @Environment(AppModel.self) private var model
    let group: TunnelGroup

    var body: some View {
        let summary = model.groupRowSummary(for: group)
        let expanded = model.expandedTunnelID == group.id
        HStack(spacing: 10) {
            StatusGlyphView(glyph: summary.glyph)
            Text(group.name).fontWeight(.semibold).lineLimit(1)
                .frame(minWidth: 70, alignment: .leading)
            Text(summary.text)
                .font(.system(size: 12))
                .foregroundStyle(summary.isError ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if model.globalState.isRunning, summary.glyph == .group {
                let latency = model.latency(for: group)
                LatencyLabel(sample: latency)
                if let latency { SparklineView(sample: latency) }
            }
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { group.isEnabled },
                    set: { model.setEnabled(groupID: group.id, $0) })
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                model.expandedTunnelID = expanded ? nil : group.id
            }
        }
    }
}

/// Expanded group (board C3): Name, Pick by, ordered Members with drag and `+ Add member…`,
/// Everything else, footer.
struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let group: TunnelGroup

    @State private var name = ""
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label("Name")
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .invalidOutline(nameError != nil)
                    if let nameError {
                        Text(nameError).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
            }
            GridRow {
                label("Pick by")
                HStack(spacing: 10) {
                    Picker(
                        "Pick by",
                        selection: Binding(
                            get: { group.policy },
                            set: { model.setPolicy(groupID: group.id, $0) })
                    ) {
                        ForEach(GroupPolicy.allCases, id: \.self) { policy in
                            Text(StatusText.policyWord(policy)).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text(StatusText.policyMeaning(group.policy, short: true))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            GridRow(alignment: .top) {
                label("Members")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.groupMembers(for: group)) { row in
                        memberRow(row)
                    }
                    Menu {
                        ForEach(model.candidateMembers(for: group)) { tunnel in
                            Button(tunnel.name) { model.addMember(groupID: group.id, tunnel.id) }
                        }
                    } label: {
                        Label("Add member…", systemImage: "plus")
                    }
                    .menuIndicator(.hidden)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(model.candidateMembers(for: group).isEmpty)
                }
            }
            GridRow {
                label("Everything else")
                DefaultExitToggle(id: group.id, name: group.name)
            }
            GridRow {
                Text("")
                HStack(spacing: 8) {
                    Text(StatusText.count(model.ruleCount(for: .group(group.id)), "site"))
                        .foregroundStyle(.secondary)
                    Button("Show rules") { model.settingsSection = .rules }.buttonStyle(.link)
                    Spacer()
                    Button("Delete…") { model.deleteGroup(group.id) }
                        .controlSize(.small)
                        .foregroundStyle(.red)
                }
            }
        }
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .onAppear { name = group.name }
        .onChange(of: model.pendingFocus, initial: true) { _, pending in
            guard let pending, model.expandedTunnelID == group.id else { return }
            nameFocused = pending == .name
            model.pendingFocus = nil
        }
        .onChange(of: nameFocused) { old, new in
            if old, !new { commitName() }
        }
    }

    /// Grip, dot, name, note, latency; drag to reorder, context menu to remove.
    private func memberRow(_ row: GroupMemberRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to change the order")
            GroupMemberRowView(row: row, showsLatency: model.globalState.isRunning)
                .frame(width: 300)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .draggable(row.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.compactMap(UUID.init(uuidString:)).first,
                group.members.contains(dragged), dragged != row.id
            else { return false }
            model.moveMember(groupID: group.id, dragged, before: row.id)
            return true
        }
        .contextMenu {
            Button(removeTitle) { model.removeMember(groupID: group.id, row.id) }
        }
    }

    /// The last two members cannot be removed — the group goes instead.
    private var removeTitle: String {
        group.members.count > TunnelGroup.minimumMembers ? "Remove from group" : "Delete group…"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func commitName() {
        guard name != group.name else { return }
        nameError = model.rename(groupID: group.id, to: name)
    }
}

/// Last row of the list: `+ New group…`, with a one-line hint until the first group exists.
struct NewGroupRow: View {
    @Environment(AppModel.self) private var model
    let showsHint: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            Text("New group…").fontWeight(.medium)
            if showsHint {
                Text("— several tunnels behind one name, the fastest or the first live one is used")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(Color.accentColor)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(
            model.store.tunnels.count < TunnelGroup.minimumMembers
                ? "A group needs at least two tunnels" : "Create a group of tunnels")
    }
}

/// New group sheet (board C7): name, members with tick + drag + latency, policy radios.
struct NewGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// Every tunnel in the order the user set; `ticked` are the future members.
    @State private var order: [UUID] = []
    @State private var ticked: Set<UUID> = []
    @State private var policy = GroupPolicy.fastest
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New group").font(.system(size: 15, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Name")
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                GridRow(alignment: .top) {
                    label("Members")
                    VStack(alignment: .leading, spacing: 4) {
                        VStack(spacing: 0) {
                            ForEach(Array(order.enumerated()), id: \.element) { index, id in
                                if let tunnel = model.store.tunnel(id: id) {
                                    if index > 0 { Divider() }
                                    memberRow(tunnel)
                                }
                            }
                        }
                        .background(GroupBackground())
                        .frame(width: 340)
                        Text(
                            "Tick the tunnels to include; drag to set the order. A tunnel that is down is skipped."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 340, alignment: .leading)
                    }
                }
                GridRow(alignment: .top) {
                    label("Pick by")
                    Picker("Pick by", selection: $policy) {
                        ForEach(GroupPolicy.allCases, id: \.self) { policy in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(StatusText.policyWord(policy))
                                Text(StatusText.policyMeaning(policy, short: false))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .tag(policy)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .frame(width: 340, alignment: .leading)
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ticked.count < TunnelGroup.minimumMembers)
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(width: 500)
        .onAppear {
            name = model.nextGroupName
            order = model.store.tunnels.map(\.id)
        }
    }

    private func memberRow(_ tunnel: Tunnel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Toggle(
                tunnel.name,
                isOn: Binding(
                    get: { ticked.contains(tunnel.id) },
                    set: { on in
                        if on { ticked.insert(tunnel.id) } else { ticked.remove(tunnel.id) }
                    })
            )
            .toggleStyle(.checkbox)
            Spacer()
            if model.globalState.isRunning {
                LatencyLabel(sample: model.latency(for: tunnel)).font(.system(size: 11))
            }
        }
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .contentShape(Rectangle())
        .draggable(tunnel.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.compactMap(UUID.init(uuidString:)).first,
                let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: tunnel.id),
                from != to
            else { return false }
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            return true
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 70, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func create() {
        let members = order.filter(ticked.contains)
        if let message = model.createGroup(name: name, members: members, policy: policy) {
            error = message
        } else {
            dismiss()
        }
    }
}
