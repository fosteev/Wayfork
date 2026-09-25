import 'package:collection/collection.dart';
import 'package:wayfork/core/app/global_state.dart';
import 'package:wayfork/core/app/latency_format.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/model/tunnel_group.dart';
import 'package:wayfork/core/rules/rule_validator.dart';

/// Error codes from the catalogue in docs/design/02-ux.md, with the text the UI
/// shows and the recovery it offers. The `helper.*` codes keep their names so
/// the catalogue stays shared with macOS; on Windows they describe the service.
enum FailureCode {
  ovpnAuthFailed('ovpn.authFailed'),
  ovpnNeedsCredentials('ovpn.needsCredentials'),
  ovpnKeyPassphrase('ovpn.keyPassphrase'),
  ovpnNeedsKeyPassphrase('ovpn.needsKeyPassphrase'),
  ovpnConfigError('ovpn.configError'),
  ovpnUnsupportedPrompt('ovpn.unsupportedPrompt'),
  ovpnExited('ovpn.exited'),
  ovpnStartFailed('ovpn.startFailed'),
  singboxStartFailed('singbox.startFailed'),
  singboxConfigInvalid('singbox.configInvalid'),
  helperVersionMismatch('helper.versionMismatch'),
  helperUnreachable('helper.unreachable');

  const FailureCode(this.code);

  final String code;

  static FailureCode? fromCode(String code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }

  bool get isTunnelCode => code.startsWith('ovpn.');

  /// Short text for the UI (docs/design/02-ux.md, "Error catalogue").
  String get message => switch (this) {
    ovpnAuthFailed => 'Server refused the login',
    ovpnNeedsCredentials => 'Login and password needed',
    ovpnKeyPassphrase => 'Wrong key passphrase',
    ovpnNeedsKeyPassphrase => 'Key passphrase needed',
    ovpnConfigError => 'OpenVPN rejected the file',
    ovpnUnsupportedPrompt =>
      "OpenVPN asked for something Wayfork can't provide",
    ovpnExited => 'OpenVPN stopped (reconnect on its own is off)',
    ovpnStartFailed => 'OpenVPN could not start',
    singboxStartFailed =>
      'Routing engine failed to start. Another VPN may be active.',
    singboxConfigInvalid => 'Routing config rejected',
    helperVersionMismatch =>
      'The Wayfork service does not match this app. Repair the installation.',
    helperUnreachable =>
      "Can't reach the Wayfork service. Repair the installation.",
  };

  FailureAction get action => switch (this) {
    ovpnAuthFailed || ovpnNeedsCredentials => FailureAction.editCredentials,
    ovpnKeyPassphrase ||
    ovpnNeedsKeyPassphrase => FailureAction.editKeyPassphrase,
    ovpnConfigError => FailureAction.replaceConfig,
    ovpnUnsupportedPrompt ||
    ovpnExited ||
    ovpnStartFailed ||
    singboxStartFailed => FailureAction.showLog,
    singboxConfigInvalid => FailureAction.exportDiagnostics,
    helperVersionMismatch ||
    helperUnreachable => FailureAction.repairInstallation,
  };
}

/// What the ✎ / "Show Log" button next to a failure does.
enum FailureAction {
  editCredentials,
  editKeyPassphrase,
  replaceConfig,
  showLog,
  exportDiagnostics,

  /// The Windows counterpart of "reinstall helper": run the installer's repair.
  repairInstallation,
}

/// Status glyph next to a tunnel (docs/design/02-ux.md, "Status glyphs").
enum StatusGlyph {
  /// Green filled: connected / ready.
  up,

  /// Grey hollow: disabled / not running.
  idle,

  /// Orange half: connecting / reconnecting.
  transitioning,

  /// Red cross: failed.
  failed,

  /// Accent square: a tunnel group (F16).
  group,
}

/// Action button on a Dashboard tunnel card.
sealed class TunnelCardAction {
  const TunnelCardAction();

  const factory TunnelCardAction.reconnect() = TunnelCardActionReconnect;
  const factory TunnelCardAction.edit(FailureAction action) =
      TunnelCardActionEdit;
  const factory TunnelCardAction.enable() = TunnelCardActionEnable;
}

final class TunnelCardActionReconnect extends TunnelCardAction {
  const TunnelCardActionReconnect();

  @override
  bool operator ==(Object other) => other is TunnelCardActionReconnect;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'reconnect';
}

final class TunnelCardActionEdit extends TunnelCardAction {
  const TunnelCardActionEdit(this.action);

  final FailureAction action;

  @override
  bool operator ==(Object other) =>
      other is TunnelCardActionEdit && action == other.action;

  @override
  int get hashCode => action.hashCode;

  @override
  String toString() => 'edit($action)';
}

final class TunnelCardActionEnable extends TunnelCardAction {
  const TunnelCardActionEnable();

  @override
  bool operator ==(Object other) => other is TunnelCardActionEnable;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'enable';
}

/// Everything a card needs to render (docs/design/02-ux.md, "Variant C").
final class TunnelPresentation {
  const TunnelPresentation({
    required this.glyph,
    required this.status,
    this.detail = '',
    this.isError = false,
    this.isDimmed = false,
    this.actions = const [],
    this.isDefault = false,
  });

  final StatusGlyph glyph;

  /// The bold word at the start of card line 2.
  final String status;

  /// The rest of card line 2, without the status word.
  final String detail;
  final bool isError;
  final bool isDimmed;
  final List<TunnelCardAction> actions;
  final bool isDefault;

  @override
  bool operator ==(Object other) =>
      other is TunnelPresentation &&
      glyph == other.glyph &&
      status == other.status &&
      detail == other.detail &&
      isError == other.isError &&
      isDimmed == other.isDimmed &&
      const ListEquality<TunnelCardAction>().equals(actions, other.actions) &&
      isDefault == other.isDefault;

  @override
  int get hashCode => Object.hash(
    glyph,
    status,
    detail,
    isError,
    isDimmed,
    const ListEquality<TunnelCardAction>().hash(actions),
    isDefault,
  );
}

/// One member line under a group card or in the expanded group (F16).
final class GroupMemberRow {
  const GroupMemberRow({
    required this.tunnel,
    required this.glyph,
    this.note = '',
    this.isActive = false,
    this.latency,
  });

  final Tunnel tunnel;
  final StatusGlyph glyph;

  /// `✓ in use` / `skipped — not reachable` / `skipped — off`; empty for a live
  /// backup.
  final String note;
  final bool isActive;
  final LatencySample? latency;

  String get id => tunnel.id;
}

/// One-line summary for a Tunnels row.
typedef TunnelRowSummary = ({String text, StatusGlyph glyph, bool isError});

/// A hint line with its tone.
typedef HintText = ({String text, bool isError});

/// User-facing strings derived from store + runtime status
/// (docs/design/02-ux.md, "Variant C").
abstract final class StatusText {
  // Failures

  static String failureMessage(String code) =>
      FailureCode.fromCode(code)?.message ?? "Can't connect ($code)";

  static FailureAction failureAction(String code) =>
      FailureCode.fromCode(code)?.action ?? FailureAction.showLog;

  // Header

  /// `missingSecrets`: tunnels the plan left out (a default without its secret
  /// is no default).
  static String summary({
    required GlobalState state,
    required Store store,
    Set<String> missingSecrets = const {},
  }) {
    // A tunnel or a group (F16) may take "everything else".
    final defaultName = effectiveDefaultExitName(
      store,
      missingSecrets: missingSecrets,
    );
    final defaultID = defaultName == null ? null : store.defaultTunnelID;
    switch (state) {
      case GlobalStateOff():
        final sites = activeRuleCount(store);
        if (sites == 0) return 'Off — nothing goes through a tunnel.';
        return 'Off — nothing goes through a tunnel. Turn on to send your '
            '${count(sites, 'site')} through their tunnels; everything else '
            'stays as it is.';
      case GlobalStateStarting():
        return 'Starting…';
      case GlobalStateStopping():
        return 'Stopping…';
      case GlobalStateError():
        return 'Routing engine failed — see Logs';
      case GlobalStateOn():
        final tunnels = store.tunnels.where((t) => t.isEnabled).length;
        if (tunnels == 0) return 'On — no tunnels';
        final sites = activeRuleCount(store);
        if (defaultName != null) {
          final otherSites = RuleValidator.activeRules(store).entries
              .where((entry) => entry.key != defaultID)
              .fold(0, (sum, entry) => sum + entry.value.length);
          if (otherSites == 0) return 'On — everything goes via $defaultName';
          return 'On — everything goes via $defaultName, '
              '${count(otherSites, 'site')} via other tunnels';
        }
        return 'On — ${count(sites, 'site')} via ${count(tunnels, 'tunnel')}, '
            'the rest as usual';
      case GlobalStateDegraded(failingTunnelIDs: final failing):
        if (defaultName != null && failing.contains(defaultID)) {
          return "$defaultName can't connect — sites without a rule are "
              'blocked until it is back';
        }
        final names = failing
            .map((id) => store.tunnel(id)?.name)
            .whereType<String>()
            .toList();
        final subject = switch (names.length) {
          0 => 'A tunnel',
          1 => names[0],
          2 => names.join(' and '),
          _ =>
            '${names.sublist(0, names.length - 1).join(', ')} and '
                '${names.last}',
        };
        final enabled = store.tunnels.where((t) => t.isEnabled).length;
        final up = enabled - failing.length < 0 ? 0 : enabled - failing.length;
        var result = "$subject can't connect — ${count(up, 'tunnel')} up";
        if (defaultName != null) result += ', everything else via $defaultName';
        return result;
    }
  }

  /// Tunnel and group rules that currently route something.
  static int activeRuleCount(Store store) => RuleValidator.activeRules(
    store,
  ).values.fold(0, (sum, rules) => sum + rules.length);

  /// Direct rules in effect (F8).
  static int activeExceptionCount(Store store) =>
      RuleValidator.activeExceptions(store).length;

  /// The default tunnel that is actually routing "everything else" (F8).
  static Tunnel? effectiveDefaultTunnel(
    Store store, {
    Set<String> missingSecrets = const {},
  }) {
    final tunnel = store.effectiveDefaultTunnel;
    if (tunnel == null || missingSecrets.contains(tunnel.id)) return null;
    return tunnel;
  }

  /// Name of the tunnel or group taking "everything else" (F8, F16), null when
  /// direct.
  static String? effectiveDefaultExitName(
    Store store, {
    Set<String> missingSecrets = const {},
  }) {
    switch (store.effectiveDefaultExit) {
      case DefaultExitTunnel(:final tunnel):
        return missingSecrets.contains(tunnel.id) ? null : tunnel.name;
      case DefaultExitGroup(:final group):
        final usable = store
            .enabledMembers(group)
            .any((member) => !missingSecrets.contains(member.id));
        return usable ? group.name : null;
      case null:
        return null;
    }
  }

  // Tunnel cards and rows

  /// Card for one tunnel. `latency` (F14) turns a connected card into *Not
  /// reachable* while its probes fail; `now` dates the "for N min" in that line.
  static TunnelPresentation card({
    required Tunnel tunnel,
    required TunnelState? state,
    required GlobalState global,
    required int ruleCount,
    bool missingSecret = false,
    bool isDefault = false,
    LatencySample? latency,
    DateTime? now,
  }) {
    final sites = count(ruleCount, 'site');
    if (!tunnel.isEnabled) {
      return TunnelPresentation(
        glyph: StatusGlyph.idle,
        status: 'Off',
        detail: sites,
        isDimmed: true,
        actions: const [TunnelCardAction.enable()],
        isDefault: isDefault,
      );
    }
    if (missingSecret) {
      final what = switch (tunnel.kind) {
        TunnelKindOpenVPN() => 'config',
        TunnelKindVLESS() || TunnelKindVMess() => 'UUID',
        TunnelKindWireGuard() => 'private key',
        TunnelKindShadowsocks() || TunnelKindTrojan() => 'password',
      };
      return TunnelPresentation(
        glyph: StatusGlyph.failed,
        status: 'Not ready',
        detail: '$what missing',
        isError: true,
        actions: const [TunnelCardAction.edit(FailureAction.replaceConfig)],
        isDefault: isDefault,
      );
    }
    switch (global) {
      case GlobalStateOff() || GlobalStateStopping():
        return TunnelPresentation(
          glyph: StatusGlyph.idle,
          status: 'Not running',
          detail: sites,
          isDimmed: true,
          isDefault: isDefault,
        );
      case GlobalStateError():
        return TunnelPresentation(
          glyph: StatusGlyph.idle,
          status: 'Not routed',
          detail: sites,
          isDimmed: true,
          isDefault: isDefault,
        );
      case GlobalStateStarting() || GlobalStateOn() || GlobalStateDegraded():
        break;
    }
    // F14: probes through the tunnel failed N times in a row.
    if (latency != null &&
        latency.unreachable &&
        (!tunnel.kind.isOpenVPN || state?.isConnected == true)) {
      return TunnelPresentation(
        glyph: StatusGlyph.failed,
        status: 'Not reachable',
        detail:
            '${LatencyFormat.unreachableDetail(latency, now: now ?? DateTime.now())}'
            ' · ${waiting(ruleCount)}',
        isError: true,
        actions: const [TunnelCardAction.reconnect()],
        isDefault: isDefault,
      );
    }
    if (!tunnel.kind.isOpenVPN) {
      return TunnelPresentation(
        glyph: StatusGlyph.up,
        status: 'Connected',
        detail: sites,
        isDefault: isDefault,
      );
    }
    switch (state) {
      case null || TunnelStateDisabled():
        return TunnelPresentation(
          glyph: StatusGlyph.transitioning,
          status: 'Connecting…',
          detail: ordinal(1),
          isDefault: isDefault,
        );
      case TunnelStateConnecting(:final attempt):
        return TunnelPresentation(
          glyph: StatusGlyph.transitioning,
          status: 'Connecting…',
          detail: ordinal(attempt),
          isDefault: isDefault,
        );
      case TunnelStateReconnecting(:final attempt):
        return TunnelPresentation(
          glyph: StatusGlyph.transitioning,
          status: 'Reconnecting…',
          detail: ordinal(attempt),
          actions: const [TunnelCardAction.reconnect()],
          isDefault: isDefault,
        );
      case TunnelStateConnected():
        return TunnelPresentation(
          glyph: StatusGlyph.up,
          status: 'Connected',
          detail: sites,
          isDefault: isDefault,
        );
      case TunnelStateFailed(:final reason):
        return TunnelPresentation(
          glyph: StatusGlyph.failed,
          status: "Can't connect",
          detail: failureMessage(reason),
          isError: true,
          actions: [
            const TunnelCardAction.reconnect(),
            TunnelCardAction.edit(failureAction(reason)),
          ],
          isDefault: isDefault,
        );
    }
  }

  /// `1 site waits` / `3 sites wait` — what a tunnel that cannot deliver holds
  /// up.
  static String waiting(int ruleCount) =>
      '${count(ruleCount, 'site')} wait${ruleCount == 1 ? 's' : ''}';

  /// One-line summary for a Tunnels row: `Status · detail · Protocol · N
  /// sites` (the default tunnel: `routes everything else and N sites`).
  static TunnelRowSummary rowSummary({
    required Tunnel tunnel,
    required TunnelState? state,
    required GlobalState global,
    bool missingSecret = false,
    bool isDefault = false,
    int ruleCount = 0,
    LatencySample? latency,
    DateTime? now,
  }) {
    final presentation = card(
      tunnel: tunnel,
      state: state,
      global: global,
      ruleCount: ruleCount,
      missingSecret: missingSecret,
      isDefault: isDefault,
      latency: latency,
      now: now,
    );
    // The card's detail repeats the site count for the quiet states; the row
    // appends it itself, so only a reason or an attempt is carried over.
    final parts = [presentation.status];
    if (presentation.status == 'Not reachable' && latency != null) {
      parts.add(
        LatencyFormat.unreachableDetail(latency, now: now ?? DateTime.now()),
      );
    } else if (presentation.isError ||
        presentation.glyph == StatusGlyph.transitioning) {
      parts.add(presentation.detail);
    }
    parts.add(typeBadge(tunnel.kind));
    parts.add(
      isDefault
          ? 'routes everything else and ${count(ruleCount, 'site')}'
          : count(ruleCount, 'site'),
    );
    return (
      text: parts.join(' · '),
      glyph: presentation.glyph,
      isError: presentation.isError,
    );
  }

  // Groups (F16)

  /// `Fastest` / `First live`.
  static String policyWord(GroupPolicy policy) => switch (policy) {
    GroupPolicy.fastest => 'Fastest',
    GroupPolicy.firstLive => 'First live',
  };

  /// `fastest of Home, Lab` — every member in the group's order.
  static String policyPhrase({
    required TunnelGroup group,
    required Store store,
  }) {
    final names = group.members
        .map((id) => store.tunnel(id)?.name)
        .whereType<String>()
        .join(', ');
    return '${policyWord(group.policy).toLowerCase()} of $names';
  }

  /// The one-line meaning next to *Pick by* and in the New group dialog.
  static String policyMeaning(GroupPolicy policy, {required bool short}) =>
      switch ((policy, short)) {
        (GroupPolicy.fastest, true) =>
          'the member that answers quickest right now',
        (GroupPolicy.firstLive, true) =>
          'the top member that works; the ones below are backups',
        (GroupPolicy.fastest, false) =>
          'Whichever member answers quickest right now — switches when '
              'another one gets faster.',
        (GroupPolicy.firstLive, false) =>
          'Always the top member that works; the ones below are backups, '
              'in order.',
      };

  /// The member sing-box is using, from the snapshot, when it is still one of
  /// the group's.
  static Tunnel? activeMember({
    required TunnelGroup group,
    required Store store,
    required Map<String, GroupState> groups,
  }) {
    final id = groups[group.id]?.activeMember?.toLowerCase();
    if (id == null || !group.members.contains(id)) return null;
    return store.tunnel(id);
  }

  /// Why a member is skipped (`off` / `not reachable`), or null when it is live.
  static String? _memberSkipReason(
    Tunnel member, {
    required TunnelState? state,
    required LatencySample? latency,
    required bool missingSecret,
  }) {
    if (!member.isEnabled || missingSecret) return 'off';
    if (latency?.unreachable == true) return 'not reachable';
    if (member.kind.isOpenVPN && state is TunnelStateFailed) {
      return 'not reachable';
    }
    return null;
  }

  static List<Tunnel> _liveMembers({
    required TunnelGroup group,
    required Store store,
    required Map<String, TunnelState> states,
    required Map<String, LatencySample> latency,
    required Set<String> missingSecrets,
  }) => store
      .enabledMembers(group)
      .where(
        (member) =>
            !missingSecrets.contains(member.id) &&
            _memberSkipReason(
                  member,
                  state: states[member.id],
                  latency: latency[member.id],
                  missingSecret: false,
                ) ==
                null,
      )
      .toList();

  /// Card for a group: the policy word, the member in use and the site count;
  /// red *No member reachable* when nothing can carry its sites right now.
  static TunnelPresentation groupCard({
    required TunnelGroup group,
    required Store store,
    required GlobalState global,
    Map<String, LatencySample> latency = const {},
    Map<String, GroupState> groups = const {},
    Map<String, TunnelState> states = const {},
    Set<String> missingSecrets = const {},
  }) {
    final ruleCount = store.rulesForGroup(group.id).length;
    final sites = count(ruleCount, 'site');
    // Default only while it actually takes "everything else".
    final isDefault =
        store.defaultTunnelID == group.id &&
        effectiveDefaultExitName(store, missingSecrets: missingSecrets) != null;
    if (!group.isEnabled) {
      return TunnelPresentation(
        glyph: StatusGlyph.idle,
        status: 'Off',
        detail: sites,
        isDimmed: true,
        actions: const [TunnelCardAction.enable()],
        isDefault: isDefault,
      );
    }
    switch (global) {
      case GlobalStateOff() || GlobalStateStopping():
        return TunnelPresentation(
          glyph: StatusGlyph.idle,
          status: 'Not running',
          detail: sites,
          isDimmed: true,
          isDefault: isDefault,
        );
      case GlobalStateError():
        return TunnelPresentation(
          glyph: StatusGlyph.idle,
          status: 'Not routed',
          detail: sites,
          isDimmed: true,
          isDefault: isDefault,
        );
      case GlobalStateStarting() || GlobalStateOn() || GlobalStateDegraded():
        break;
    }
    final live = _liveMembers(
      group: group,
      store: store,
      states: states,
      latency: latency,
      missingSecrets: missingSecrets,
    );
    if (live.isEmpty) {
      final String fallback;
      if (isDefault) {
        fallback = 'its $sites are blocked for now';
      } else {
        final name = effectiveDefaultExitName(
          store,
          missingSecrets: missingSecrets,
        );
        fallback = name == null
            ? 'its $sites stay outside a tunnel for now'
            : 'its $sites go via $name for now';
      }
      return TunnelPresentation(
        glyph: StatusGlyph.failed,
        status: 'No member reachable',
        detail: fallback,
        isError: true,
        isDefault: isDefault,
      );
    }
    var detail = sites;
    final active = activeMember(group: group, store: store, groups: groups);
    if (active != null) detail = 'using ${active.name} · $sites';
    return TunnelPresentation(
      glyph: StatusGlyph.group,
      status: policyWord(group.policy),
      detail: detail,
      isDefault: isDefault,
    );
  }

  /// Member rows under the group card and in the expanded group, in the group's
  /// order.
  static List<GroupMemberRow> groupMembers({
    required TunnelGroup group,
    required Store store,
    required GlobalState global,
    Map<String, LatencySample> latency = const {},
    Map<String, GroupState> groups = const {},
    Map<String, TunnelState> states = const {},
    Set<String> missingSecrets = const {},
  }) {
    final running = global.isRunning && group.isEnabled;
    final active = running
        ? activeMember(group: group, store: store, groups: groups)
        : null;
    final rows = <GroupMemberRow>[];
    for (final id in group.members) {
      final member = store.tunnel(id);
      if (member == null) continue;
      final sample = latency[id];
      final missing = missingSecrets.contains(id);
      final memberCard = card(
        tunnel: member,
        state: states[id],
        global: global,
        ruleCount: 0,
        missingSecret: missing,
        latency: sample,
      );
      final reason = _memberSkipReason(
        member,
        state: states[id],
        latency: sample,
        missingSecret: missing,
      );
      // A skip reason wins over the tick: a selector left pointing at a dead
      // member is not "in use" in any sense the user cares about.
      if (member.id == active?.id && reason == null) {
        rows.add(
          GroupMemberRow(
            tunnel: member,
            glyph: memberCard.glyph,
            note: '✓ in use',
            isActive: true,
            latency: sample,
          ),
        );
        continue;
      }
      final note = (running || reason == 'off') && reason != null
          ? 'skipped — $reason'
          : '';
      rows.add(
        GroupMemberRow(
          tunnel: member,
          glyph: memberCard.glyph,
          note: note,
          latency: running ? sample : null,
        ),
      );
    }
    return rows;
  }

  /// Subtitle of a Tunnels group row: `Group · fastest of Home, Lab · using
  /// Home · N sites`, with the status word in front when it is not just running.
  static TunnelRowSummary groupRowSummary({
    required TunnelGroup group,
    required Store store,
    required GlobalState global,
    Map<String, LatencySample> latency = const {},
    Map<String, GroupState> groups = const {},
    Map<String, TunnelState> states = const {},
    Set<String> missingSecrets = const {},
  }) {
    final presentation = groupCard(
      group: group,
      store: store,
      global: global,
      latency: latency,
      groups: groups,
      states: states,
      missingSecrets: missingSecrets,
    );
    final parts = <String>[];
    if (presentation.glyph != StatusGlyph.group) parts.add(presentation.status);
    parts.add('Group');
    parts.add(policyPhrase(group: group, store: store));
    final active = activeMember(group: group, store: store, groups: groups);
    if (presentation.glyph == StatusGlyph.group && active != null) {
      parts.add('using ${active.name}');
    }
    final ruleCount = store.rulesForGroup(group.id).length;
    parts.add(
      presentation.isDefault
          ? 'routes everything else and ${count(ruleCount, 'site')}'
          : count(ruleCount, 'site'),
    );
    return (
      text: parts.join(' · '),
      glyph: presentation.glyph,
      isError: presentation.isError,
    );
  }

  /// Header hint of a group's section on the Rules page.
  static HintText groupHint({
    required TunnelGroup group,
    required Store store,
    required GlobalState global,
    Map<String, LatencySample> latency = const {},
    Map<String, GroupState> groups = const {},
    Map<String, TunnelState> states = const {},
    Set<String> missingSecrets = const {},
  }) {
    final presentation = groupCard(
      group: group,
      store: store,
      global: global,
      latency: latency,
      groups: groups,
      states: states,
      missingSecrets: missingSecrets,
    );
    if (!group.isEnabled) {
      final name = effectiveDefaultExitName(
        store,
        missingSecrets: missingSecrets,
      );
      return (
        text: name == null
            ? 'off — its sites stay outside a tunnel for now'
            : 'off — its sites go via $name for now',
        isError: false,
      );
    }
    if (presentation.isError) {
      return (text: 'no member reachable — its sites wait', isError: true);
    }
    var text = policyPhrase(group: group, store: store);
    final active = activeMember(group: group, store: store, groups: groups);
    if (presentation.glyph == StatusGlyph.group && active != null) {
      text += ' · using ${active.name} right now';
    }
    return (text: text, isError: false);
  }

  // Wording helpers

  /// `vpn.example.com:1194 udp` / `host.example.com:443 · REALITY · vision`.
  static String endpointDescription(TunnelKind kind) {
    switch (kind) {
      case TunnelKindOpenVPN(:final meta):
        if (meta.remotes.isEmpty) return 'no remote';
        final first = meta.remotes.first;
        var text = '${first.host}:${first.port} ${first.proto}';
        if (meta.remotes.length > 1) text += ' +${meta.remotes.length - 1}';
        return text;
      case TunnelKindVLESS(:final meta):
        final parts = ['${meta.server}:${meta.port}'];
        switch (meta.security) {
          case TlsSecurity.reality:
            parts.add('REALITY');
          case TlsSecurity.tls:
            parts.add('TLS');
          case TlsSecurity.none:
            parts.add('no TLS');
        }
        switch (meta.transport) {
          case ProxyTransportTCP():
            break;
          case ProxyTransportWS():
            parts.add('ws');
          case ProxyTransportGRPC():
            parts.add('gRPC');
        }
        if (meta.flow == 'xtls-rprx-vision') parts.add('vision');
        return parts.join(' · ');
      case TunnelKindWireGuard(:final meta):
        if (meta.peers.isEmpty) return 'no peer';
        final peer = meta.peers.first;
        return '${peer.host}:${peer.port}';
      case TunnelKindShadowsocks(:final meta):
        return '${meta.server}:${meta.port} · ${meta.method}';
      case TunnelKindTrojan(:final meta):
        final parts = [
          '${meta.server}:${meta.port}',
          _securityDescription(meta.security),
          ..._transportDescription(meta.transport),
        ];
        return parts.join(' · ');
      case TunnelKindVMess(:final meta):
        final parts = [
          '${meta.server}:${meta.port}',
          meta.security,
          ..._transportDescription(meta.transport),
        ];
        return parts.join(' · ');
    }
  }

  static String _securityDescription(TlsSecurity security) =>
      switch (security) {
        TlsSecurity.reality => 'REALITY',
        TlsSecurity.tls => 'TLS',
        TlsSecurity.none => 'no TLS',
      };

  static List<String> _transportDescription(ProxyTransport transport) =>
      switch (transport) {
        ProxyTransportTCP() => const [],
        ProxyTransportWS() => const ['ws'],
        ProxyTransportGRPC() => const ['gRPC'],
      };

  static String typeBadge(TunnelKind kind) => switch (kind) {
    TunnelKindOpenVPN() => 'OpenVPN',
    TunnelKindVLESS() => 'VLESS',
    TunnelKindWireGuard() => 'WireGuard',
    TunnelKindShadowsocks() => 'Shadowsocks',
    TunnelKindTrojan() => 'Trojan',
    TunnelKindVMess() => 'VMess',
  };

  /// `1st try`, `2nd try`, `11th try`, `21st try`.
  static String ordinal(int number) {
    final remainder = number % 100;
    final String suffix;
    if (remainder >= 11 && remainder <= 13) {
      suffix = 'th';
    } else {
      suffix = switch (number % 10) {
        1 => 'st',
        2 => 'nd',
        3 => 'rd',
        _ => 'th',
      };
    }
    return '$number$suffix try';
  }

  /// The match kind in the user's words (docs/design/02-ux.md, "Wording").
  static String matchWord(RuleMatch match) => switch (match) {
    RuleMatch.suffix => 'and subdomains',
    RuleMatch.exact => 'exactly this',
    RuleMatch.wildcard => 'pattern',
    RuleMatch.app => 'the app',
    RuleMatch.ip => 'address range',
  };

  /// General › Logs › Detail item for a log level.
  static String logDetailName(LogLevel level) => switch (level) {
    LogLevel.error => 'Errors only',
    LogLevel.warning => 'Problems',
    LogLevel.info => 'Normal',
    LogLevel.debug => 'Everything',
  };

  /// `1 site`, `3 sites`.
  static String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}
