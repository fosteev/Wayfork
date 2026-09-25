part of 'app_model.dart';

// Tunnel groups (F16, docs/design/01-data-model.md, "Tunnel groups"): several
// tunnels behind one name; rules and the default exit may point at a group
// like at a tunnel.

extension AppModelGroups on AppModel {
  // Derived

  /// Which member sing-box is using (from the snapshot), by group id.
  Map<String, GroupState> get groupStates => _traffic?.groups ?? const {};

  Map<String, LatencySample> get _latencySamples =>
      _traffic?.latency ?? const {};

  Map<String, TunnelState> get _tunnelStates => _status?.tunnels ?? const {};

  TunnelPresentation groupCard(TunnelGroup group) => StatusText.groupCard(
    group: group,
    store: _store,
    global: globalState,
    latency: _latencySamples,
    groups: groupStates,
    states: _tunnelStates,
    missingSecrets: _missingSecrets,
  );

  List<GroupMemberRow> groupMembers(TunnelGroup group) =>
      StatusText.groupMembers(
        group: group,
        store: _store,
        global: globalState,
        latency: _latencySamples,
        groups: groupStates,
        states: _tunnelStates,
        missingSecrets: _missingSecrets,
      );

  TunnelRowSummary groupRowSummary(TunnelGroup group) =>
      StatusText.groupRowSummary(
        group: group,
        store: _store,
        global: globalState,
        latency: _latencySamples,
        groups: groupStates,
        states: _tunnelStates,
        missingSecrets: _missingSecrets,
      );

  HintText groupHint(TunnelGroup group) => StatusText.groupHint(
    group: group,
    store: _store,
    global: globalState,
    latency: _latencySamples,
    groups: groupStates,
    states: _tunnelStates,
    missingSecrets: _missingSecrets,
  );

  /// Whether `id` (a tunnel or a group) is the exit actually taking
  /// "everything else".
  bool isEffectiveDefault(String id) =>
      _store.defaultTunnelID == id &&
      StatusText.effectiveDefaultExitName(
            _store,
            missingSecrets: _missingSecrets,
          ) !=
          null;

  /// The member in use, when the snapshot names one of the group's members.
  Tunnel? activeMember(TunnelGroup group) =>
      StatusText.activeMember(group: group, store: _store, groups: groupStates);

  /// The group's latency is the active member's.
  LatencySample? groupLatency(TunnelGroup group) {
    final active = activeMember(group);
    return active == null ? null : latency(active);
  }

  /// The accumulator keys a group's own traffic by the group id, like a
  /// tunnel's.
  TrafficCounters? groupTraffic(TunnelGroup group) =>
      _traffic?.countersForTunnel(group.id);

  /// Tunnels a group could still take: enabled or not, but not already a
  /// member.
  List<Tunnel> candidateMembers(TunnelGroup group) =>
      _store.tunnels.where((t) => !group.members.contains(t.id)).toList();

  /// `Group N` for the New group dialog.
  String get nextGroupName => uniqueName('Group ${_store.groups.length + 1}');

  // Mutations

  /// Creates a group from the dialog. Returns an error message, or null when
  /// it went through.
  Future<String?> createGroup({
    required String name,
    required List<String> members,
    required GroupPolicy policy,
  }) async {
    final trimmed = name.trim();
    final problem = _validateGroupName(trimmed, excluding: null);
    if (problem != null) return problem;
    final known = members.where((id) => _store.tunnel(id) != null).toList();
    if (known.length < TunnelGroup.minimumMembers) {
      return 'Pick at least two tunnels';
    }
    final group = TunnelGroup(name: trimmed, members: known, policy: policy);
    await update((store) => store.copyWith(groups: [...store.groups, group]));
    logs.app(
      LogLevel.info,
      'group created: $trimmed (${known.length} members, ${policy.jsonValue})',
    );
    return null;
  }

  Future<String?> renameGroup(String groupID, String rawName) async {
    final name = rawName.trim();
    final problem = _validateGroupName(name, excluding: groupID);
    if (problem != null) return problem;
    await _updateGroup(groupID, (group) => group.copyWith(name: name));
    return null;
  }

  Future<void> setGroupPolicy(String groupID, GroupPolicy policy) =>
      _updateGroup(groupID, (group) => group.copyWith(policy: policy));

  Future<void> setGroupEnabled(String groupID, bool enabled) =>
      _updateGroup(groupID, (group) => group.copyWith(isEnabled: enabled));

  /// Moves a member before `before` (or to the end when null).
  Future<void> moveMember(String groupID, String memberID, {String? before}) =>
      _updateGroup(groupID, (group) {
        final members = [...group.members];
        if (!members.remove(memberID)) return group;
        final index = before == null ? -1 : members.indexOf(before);
        members.insert(index < 0 ? members.length : index, memberID);
        return group.copyWith(members: members);
      });

  Future<void> addMember(String groupID, String tunnelID) async {
    if (_store.tunnel(tunnelID) == null) return;
    await _updateGroup(
      groupID,
      (group) => group.members.contains(tunnelID)
          ? group
          : group.copyWith(members: [...group.members, tunnelID]),
    );
  }

  /// Whether removing a member is possible without deleting the group.
  bool canRemoveMember(TunnelGroup group) =>
      group.members.length > TunnelGroup.minimumMembers;

  /// Removes a member; the UI deletes the group instead when it is at the
  /// minimum.
  Future<void> removeMember(String groupID, String tunnelID) => _updateGroup(
    groupID,
    (group) => group.copyWith(
      members: group.members.where((m) => m != tunnelID).toList(),
    ),
  );

  /// The confirmation text for [deleteGroup]; null when the group is unknown.
  String? deleteGroupMessage(String groupID) {
    final group = _store.group(groupID);
    if (group == null) return null;
    final rules = _store.rulesForGroup(groupID).length;
    return rules > 0
        ? 'Delete ${group.name} and its ${StatusText.count(rules, 'site')}? '
              'The rules go with it; the tunnels stay.'
        : 'Delete ${group.name}? The tunnels stay.';
  }

  /// Removes the group and its rules (the UI confirms first).
  Future<void> deleteGroup(String groupID) async {
    final group = _store.group(groupID);
    if (group == null) return;
    await update(
      (store) => store.copyWith(
        groups: store.groups.where((g) => g.id != groupID).toList(),
        rules: store.rules
            .where((rule) => rule.target.groupID != groupID)
            .toList(),
        defaultTunnelID: store.defaultTunnelID == groupID
            ? null
            : store.defaultTunnelID,
      ),
    );
    if (expandedTunnelID == groupID) expandedTunnelID = null;
    logs.app(LogLevel.info, 'deleted group ${group.name}');
    _changed();
  }

  /// Groups that would drop below the minimum once `tunnelID` is gone.
  List<TunnelGroup> groupsLeftTooSmall({required String without}) => _store
      .groups
      .where(
        (group) =>
            group.members.contains(without) &&
            group.members.length - 1 < TunnelGroup.minimumMembers,
      )
      .toList();

  Future<void> _updateGroup(
    String id,
    TunnelGroup Function(TunnelGroup group) mutate,
  ) => update(
    (store) => store.copyWith(
      groups: [
        for (final group in store.groups)
          if (group.id == id) mutate(group) else group,
      ],
    ),
  );

  String? _validateGroupName(String name, {required String? excluding}) {
    if (name.isEmpty) return "Name can't be empty";
    if (name.length > Tunnel.nameMaxLength) {
      return 'Name is limited to ${Tunnel.nameMaxLength} characters';
    }
    if (!_store.isNameAvailable(name, excluding: excluding)) {
      return 'Another tunnel or group is already called $name';
    }
    return null;
  }
}
