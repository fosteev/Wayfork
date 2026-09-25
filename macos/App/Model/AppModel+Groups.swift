import Foundation
import WayforkCore

// Tunnel groups (F16, docs/design/01-data-model.md, "Tunnel groups"): several tunnels
// behind one name; rules and the default exit may point at a group like at a tunnel.

extension AppModel {
    // MARK: - Derived

    /// Which member sing-box is using (from the snapshot), by group id.
    var groupStates: [String: GroupState] { traffic?.groups ?? [:] }

    func groupCard(for group: TunnelGroup) -> TunnelPresentation {
        StatusText.groupCard(
            group: group, store: store, global: globalState, latency: traffic?.latency ?? [:],
            groups: groupStates, states: status?.tunnels ?? [:], missingSecrets: missingSecrets)
    }

    func groupMembers(for group: TunnelGroup) -> [GroupMemberRow] {
        StatusText.groupMembers(
            group: group, store: store, global: globalState, latency: traffic?.latency ?? [:],
            groups: groupStates, states: status?.tunnels ?? [:], missingSecrets: missingSecrets)
    }

    func groupRowSummary(for group: TunnelGroup) -> (
        text: String, glyph: StatusGlyph, isError: Bool
    ) {
        StatusText.groupRowSummary(
            group: group, store: store, global: globalState, latency: traffic?.latency ?? [:],
            groups: groupStates, states: status?.tunnels ?? [:], missingSecrets: missingSecrets)
    }

    func groupHint(for group: TunnelGroup) -> (text: String, isError: Bool) {
        StatusText.groupHint(
            group: group, store: store, global: globalState, latency: traffic?.latency ?? [:],
            groups: groupStates, states: status?.tunnels ?? [:], missingSecrets: missingSecrets)
    }

    /// Whether `id` (a tunnel or a group) is the exit actually taking "everything else".
    func isEffectiveDefault(_ id: UUID) -> Bool {
        store.defaultTunnelID == id
            && StatusText.effectiveDefaultExitName(store, missingSecrets: missingSecrets) != nil
    }

    /// The member in use, when the snapshot names one of the group's members.
    func activeMember(of group: TunnelGroup) -> Tunnel? {
        StatusText.activeMember(group: group, store: store, groups: groupStates)
    }

    /// The group's latency is the active member's (docs/design/05-daemon.md).
    func latency(for group: TunnelGroup) -> LatencySample? {
        activeMember(of: group).flatMap(latency(for:))
    }

    /// The accumulator keys a group's own traffic by the group id, like a tunnel's.
    func trafficCounters(for group: TunnelGroup) -> TrafficCounters? {
        traffic?.counters(forTunnel: group.id.uuidString.lowercased())
    }

    /// Tunnels a group could still take: enabled or not, but not already a member.
    func candidateMembers(for group: TunnelGroup) -> [Tunnel] {
        store.tunnels.filter { !group.members.contains($0.id) }
    }

    /// `Group N` for the New group sheet.
    var nextGroupName: String {
        uniqueName("Group \(store.groups.count + 1)")
    }

    // MARK: - Mutations

    /// Creates a group from the sheet. Returns an error message, or nil when it went through.
    @discardableResult
    func createGroup(name rawName: String, members: [UUID], policy: GroupPolicy) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = validateGroupName(name, excluding: nil) { return message }
        let known = members.filter { store.tunnel(id: $0) != nil }
        guard known.count >= TunnelGroup.minimumMembers else { return "Pick at least two tunnels" }
        let group = TunnelGroup(name: name, members: known, policy: policy)
        update { $0.groups.append(group) }
        logs.app(.info, "group created: \(name) (\(known.count) members, \(policy.rawValue))")
        return nil
    }

    @discardableResult
    func rename(groupID: UUID, to rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = validateGroupName(name, excluding: groupID) { return message }
        updateGroup(groupID) { $0.name = name }
        return nil
    }

    func setPolicy(groupID: UUID, _ policy: GroupPolicy) {
        updateGroup(groupID) { $0.policy = policy }
    }

    func setEnabled(groupID: UUID, _ enabled: Bool) {
        updateGroup(groupID) { $0.isEnabled = enabled }
    }

    /// Moves a member before `before` (or to the end when nil).
    func moveMember(groupID: UUID, _ memberID: UUID, before: UUID?) {
        updateGroup(groupID) { group in
            guard let from = group.members.firstIndex(of: memberID) else { return }
            group.members.remove(at: from)
            let to = before.flatMap { group.members.firstIndex(of: $0) } ?? group.members.endIndex
            group.members.insert(memberID, at: to)
        }
    }

    func addMember(groupID: UUID, _ tunnelID: UUID) {
        guard store.tunnel(id: tunnelID) != nil else { return }
        updateGroup(groupID) { group in
            guard !group.members.contains(tunnelID) else { return }
            group.members.append(tunnelID)
        }
    }

    /// Removes a member; a group at its minimum is deleted instead (after confirmation).
    func removeMember(groupID: UUID, _ tunnelID: UUID) {
        guard let group = store.group(id: groupID), group.members.contains(tunnelID) else { return }
        guard group.members.count > TunnelGroup.minimumMembers else {
            deleteGroup(groupID)
            return
        }
        updateGroup(groupID) { $0.members.removeAll { $0 == tunnelID } }
    }

    /// Asks for confirmation when rules are attached, then removes the group and its rules.
    func deleteGroup(_ groupID: UUID) {
        guard let group = store.group(id: groupID) else { return }
        let rules = store.rules(forGroup: groupID).count
        let message =
            rules > 0
            ? "Delete \(group.name) and its \(StatusText.count(rules, "site"))? The rules go with it; the tunnels stay."
            : "Delete \(group.name)? The tunnels stay."
        guard Alerts.confirm(title: "Delete group", message: message, destructive: "Delete")
        else { return }
        removeGroups([groupID])
        logs.app(.info, "deleted group \(group.name)")
    }

    /// Groups that would drop below the minimum once `tunnelID` is gone — deleted with the
    /// tunnel, after one combined confirmation (`deleteTunnel`).
    func groupsLeftTooSmall(without tunnelID: UUID) -> [TunnelGroup] {
        store.groups.filter {
            $0.members.contains(tunnelID)
                && $0.members.count - 1 < TunnelGroup.minimumMembers
        }
    }

    /// Store-level removal shared by the delete paths: the groups, their rules, the default.
    func removeGroups(_ ids: [UUID]) {
        update { store in
            store.groups.removeAll { ids.contains($0.id) }
            store.rules.removeAll { rule in rule.target.groupID.map(ids.contains) ?? false }
            if let id = store.defaultTunnelID, ids.contains(id) { store.defaultTunnelID = nil }
        }
        if let expanded = expandedTunnelID, ids.contains(expanded) { expandedTunnelID = nil }
    }

    private func updateGroup(_ id: UUID, _ mutate: (inout TunnelGroup) -> Void) {
        update { store in
            guard let index = store.groups.firstIndex(where: { $0.id == id }) else { return }
            mutate(&store.groups[index])
        }
    }

    private func validateGroupName(_ name: String, excluding id: UUID?) -> String? {
        guard !name.isEmpty else { return "Name can't be empty" }
        guard name.count <= Tunnel.nameMaxLength else {
            return "Name is limited to \(Tunnel.nameMaxLength) characters"
        }
        guard store.isNameAvailable(name, excluding: id) else {
            return "Another tunnel or group is already called \(name)"
        }
        return nil
    }
}
