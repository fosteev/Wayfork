import 'package:wayfork/core/app/global_state.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
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

  /// Short text; tunnel codes read as the tail of "failed: …".
  String get message => switch (this) {
    ovpnAuthFailed => 'server rejected username/password',
    ovpnNeedsCredentials => 'username and password required',
    ovpnKeyPassphrase => 'wrong key passphrase',
    ovpnNeedsKeyPassphrase => 'key passphrase required',
    ovpnConfigError => 'OpenVPN rejected the config',
    ovpnUnsupportedPrompt =>
      'OpenVPN asked for something Wayfork cannot provide',
    ovpnExited => 'OpenVPN exited (automatic reconnect is off)',
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

/// Everything a Dashboard tunnel card needs to render.
final class TunnelPresentation {
  const TunnelPresentation({
    required this.glyph,
    required this.detail,
    this.isError = false,
    this.isDimmed = false,
    this.action,
  });

  final StatusGlyph glyph;

  /// Line 2 of the card, e.g. `connected · 10.8.0.6 on Wayfork-1 · 3 rules`.
  final String detail;
  final bool isError;
  final bool isDimmed;
  final TunnelCardAction? action;

  @override
  bool operator ==(Object other) =>
      other is TunnelPresentation &&
      glyph == other.glyph &&
      detail == other.detail &&
      isError == other.isError &&
      isDimmed == other.isDimmed &&
      action == other.action;

  @override
  int get hashCode => Object.hash(glyph, detail, isError, isDimmed, action);
}

/// One-line summary for a Tunnels row.
typedef TunnelRowSummary = ({String text, StatusGlyph glyph, bool isError});

/// User-facing strings derived from store + runtime status
/// (docs/design/02-ux.md).
abstract final class StatusText {
  // Failures

  /// `failed: <message>` for tunnel codes; the catalogue message for
  /// engine/service codes; `failed: <code>` for anything unknown.
  static String failureMessage(String code) {
    final known = FailureCode.fromCode(code);
    if (known == null) return 'failed: $code';
    return known.isTunnelCode ? 'failed: ${known.message}' : known.message;
  }

  static FailureAction failureAction(String code) =>
      FailureCode.fromCode(code)?.action ?? FailureAction.showLog;

  // Dashboard header

  /// `missingSecrets`: tunnels the plan left out (a default without its secret
  /// is no default).
  static String summary({
    required GlobalState state,
    required Store store,
    Set<String> missingSecrets = const {},
  }) {
    final defaultTunnel = effectiveDefaultTunnel(
      store,
      missingSecrets: missingSecrets,
    );
    switch (state) {
      case GlobalStateOff():
        return 'Off — all traffic goes direct';
      case GlobalStateStarting():
        return 'Starting…';
      case GlobalStateStopping():
        return 'Stopping…';
      case GlobalStateError():
        return 'Routing engine failed — see Logs';
      case GlobalStateOn():
        final tunnels = store.tunnels.where((t) => t.isEnabled).length;
        if (tunnels == 0) return 'On — no tunnels';
        if (defaultTunnel != null) {
          return 'On — everything via ${defaultTunnel.name} · '
              '${count(activeRuleCount(store), 'rule')}, '
              '${count(activeExceptionCount(store), 'exception')}';
        }
        return 'On — routing ${count(activeRuleCount(store), 'domain')} '
            'through ${count(tunnels, 'tunnel')}';
      case GlobalStateDegraded(failingTunnelIDs: final failing):
        if (defaultTunnel != null && failing.contains(defaultTunnel.id)) {
          return 'Degraded — ${defaultTunnel.name} (default) is down · '
              'unmatched traffic is blocked';
        }
        final names = failing
            .map((id) => store.tunnel(id)?.name)
            .whereType<String>()
            .toList();
        final verb = names.length == 1 ? 'is' : 'are';
        final subject = names.isEmpty ? 'a tunnel' : names.join(', ');
        final enabled = store.tunnels.where((t) => t.isEnabled).length;
        final up = enabled - failing.length < 0 ? 0 : enabled - failing.length;
        return 'Degraded — $subject $verb failing · '
            '${count(activeRuleCount(store), 'domain')}, '
            '${count(up, 'tunnel')} up';
    }
  }

  /// Tunnel rules that currently route something: enabled, not shadowed,
  /// tunnel enabled.
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

  /// Card / row suffix for the default tunnel.
  static const defaultSuffix = ' · everything else';

  // Tunnel cards and rows

  /// Dashboard card for one tunnel.
  static TunnelPresentation card({
    required Tunnel tunnel,
    required TunnelState? state,
    required GlobalState global,
    required int ruleCount,
    bool missingSecret = false,
    bool isDefault = false,
  }) {
    final rules = count(ruleCount, 'rule') + (isDefault ? defaultSuffix : '');
    if (!tunnel.isEnabled) {
      return TunnelPresentation(
        glyph: StatusGlyph.idle,
        detail: 'disabled · $rules',
        isDimmed: true,
        action: const TunnelCardAction.enable(),
      );
    }
    if (missingSecret) {
      final what = tunnel.kind.isOpenVPN ? 'config' : 'UUID';
      return TunnelPresentation(
        glyph: StatusGlyph.failed,
        detail: '$what missing · $rules',
        isError: true,
        action: const TunnelCardAction.edit(FailureAction.replaceConfig),
      );
    }
    switch (global) {
      case GlobalStateOff() || GlobalStateStopping():
        return TunnelPresentation(
          glyph: StatusGlyph.idle,
          detail: 'not running · $rules',
          isDimmed: true,
        );
      case GlobalStateError():
        return TunnelPresentation(
          glyph: StatusGlyph.idle,
          detail: 'not routed · $rules',
          isDimmed: true,
        );
      case GlobalStateStarting() || GlobalStateOn() || GlobalStateDegraded():
        break;
    }
    if (!tunnel.kind.isOpenVPN) {
      final host = tunnel.kind.vless?.server ?? '';
      return TunnelPresentation(
        glyph: StatusGlyph.up,
        detail: 'ready · $host · $rules',
      );
    }
    switch (state) {
      case null || TunnelStateDisabled():
        return const TunnelPresentation(
          glyph: StatusGlyph.transitioning,
          detail: 'connecting…',
        );
      case TunnelStateConnecting(:final attempt):
        return TunnelPresentation(
          glyph: StatusGlyph.transitioning,
          detail: 'connecting… attempt $attempt',
          action: const TunnelCardAction.reconnect(),
        );
      case TunnelStateReconnecting(:final attempt, :final reason):
        var detail = 'reconnecting… attempt $attempt';
        if (reason != null && reason.isNotEmpty) detail += ' · $reason';
        return TunnelPresentation(
          glyph: StatusGlyph.transitioning,
          detail: detail,
          action: const TunnelCardAction.reconnect(),
        );
      case TunnelStateConnected(:final ip, :final interface):
        var detail = 'connected · ';
        if (ip != null && ip.isNotEmpty) detail += '$ip on ';
        detail += '$interface · $rules';
        return TunnelPresentation(
          glyph: StatusGlyph.up,
          detail: detail,
          action: const TunnelCardAction.reconnect(),
        );
      case TunnelStateFailed(:final reason):
        return TunnelPresentation(
          glyph: StatusGlyph.failed,
          detail: failureMessage(reason),
          isError: true,
          action: TunnelCardAction.edit(failureAction(reason)),
        );
    }
  }

  /// One-line summary for a Tunnels row, e.g.
  /// `connected · vpn.example.com:1194 udp · 10.8.0.6 on Wayfork-1`.
  static TunnelRowSummary rowSummary({
    required Tunnel tunnel,
    required TunnelState? state,
    required GlobalState global,
    bool missingSecret = false,
    bool isDefault = false,
  }) {
    final endpoint =
        endpointDescription(tunnel.kind) + (isDefault ? defaultSuffix : '');
    if (!tunnel.isEnabled) {
      return (
        text: 'disabled · $endpoint',
        glyph: StatusGlyph.idle,
        isError: false,
      );
    }
    if (missingSecret) {
      final what = tunnel.kind.isOpenVPN ? 'config missing' : 'UUID missing';
      return (
        text: '$what · $endpoint',
        glyph: StatusGlyph.failed,
        isError: true,
      );
    }
    if (!global.isRunning && global is! GlobalStateStarting) {
      return (
        text: 'not running · $endpoint',
        glyph: StatusGlyph.idle,
        isError: false,
      );
    }
    if (!tunnel.kind.isOpenVPN) {
      return (text: 'ready · $endpoint', glyph: StatusGlyph.up, isError: false);
    }
    switch (state) {
      case null || TunnelStateDisabled() || TunnelStateConnecting():
        return (
          text: 'connecting… · $endpoint',
          glyph: StatusGlyph.transitioning,
          isError: false,
        );
      case TunnelStateReconnecting(:final attempt, :final reason):
        var text = 'reconnecting… attempt $attempt';
        if (reason != null && reason.isNotEmpty) text += ' · $reason';
        return (text: text, glyph: StatusGlyph.transitioning, isError: false);
      case TunnelStateConnected(:final ip, :final interface):
        var text = 'connected · $endpoint';
        if (ip != null && ip.isNotEmpty) {
          text += ' · $ip on $interface';
        } else {
          text += ' · $interface';
        }
        return (text: text, glyph: StatusGlyph.up, isError: false);
      case TunnelStateFailed(:final reason):
        return (
          text: failureMessage(reason),
          glyph: StatusGlyph.failed,
          isError: true,
        );
    }
  }

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
          case VLESSSecurity.reality:
            parts.add('REALITY');
          case VLESSSecurity.tls:
            parts.add('TLS');
          case VLESSSecurity.none:
            parts.add('no TLS');
        }
        switch (meta.transport) {
          case VLESSTransportTCP():
            break;
          case VLESSTransportWS():
            parts.add('ws');
          case VLESSTransportGRPC():
            parts.add('gRPC');
        }
        if (meta.flow == 'xtls-rprx-vision') parts.add('vision');
        return parts.join(' · ');
    }
  }

  static String typeBadge(TunnelKind kind) =>
      kind.isOpenVPN ? 'OpenVPN' : 'VLESS';

  /// `1 rule`, `3 rules`.
  static String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}
