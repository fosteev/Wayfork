import 'package:collection/collection.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/store.dart';

/// Global state shown in the tray, derived in the app from the service status
/// (docs/design/00-architecture.md, "State machines").
sealed class GlobalState {
  const GlobalState();

  const factory GlobalState.off() = GlobalStateOff;
  const factory GlobalState.starting() = GlobalStateStarting;
  const factory GlobalState.on() = GlobalStateOn;
  const factory GlobalState.degraded({required List<String> failingTunnelIDs}) =
      GlobalStateDegraded;
  const factory GlobalState.stopping() = GlobalStateStopping;
  const factory GlobalState.error({required String reason}) = GlobalStateError;

  bool get isTransitioning =>
      this is GlobalStateStarting || this is GlobalStateStopping;

  /// The routing engine is up (traffic is being routed).
  bool get isRunning => this is GlobalStateOn || this is GlobalStateDegraded;

  bool get isOff => this is GlobalStateOff;
}

final class GlobalStateOff extends GlobalState {
  const GlobalStateOff();

  @override
  bool operator ==(Object other) => other is GlobalStateOff;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'off';
}

final class GlobalStateStarting extends GlobalState {
  const GlobalStateStarting();

  @override
  bool operator ==(Object other) => other is GlobalStateStarting;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'starting';
}

final class GlobalStateOn extends GlobalState {
  const GlobalStateOn();

  @override
  bool operator ==(Object other) => other is GlobalStateOn;

  @override
  int get hashCode => 2;

  @override
  String toString() => 'on';
}

/// sing-box runs but at least one enabled OpenVPN tunnel is not connected.
final class GlobalStateDegraded extends GlobalState {
  const GlobalStateDegraded({required this.failingTunnelIDs});

  final List<String> failingTunnelIDs;

  @override
  bool operator ==(Object other) =>
      other is GlobalStateDegraded &&
      const ListEquality<String>().equals(
        failingTunnelIDs,
        other.failingTunnelIDs,
      );

  @override
  int get hashCode => const ListEquality<String>().hash(failingTunnelIDs);

  @override
  String toString() => 'degraded($failingTunnelIDs)';
}

final class GlobalStateStopping extends GlobalState {
  const GlobalStateStopping();

  @override
  bool operator ==(Object other) => other is GlobalStateStopping;

  @override
  int get hashCode => 3;

  @override
  String toString() => 'stopping';
}

/// sing-box failed to start or crashed repeatedly; `reason` is a catalogue code.
final class GlobalStateError extends GlobalState {
  const GlobalStateError({required this.reason});

  final String reason;

  @override
  bool operator ==(Object other) =>
      other is GlobalStateError && reason == other.reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'error($reason)';
}

/// What the app is currently doing on the user's behalf; overrides the service
/// status while an operation is in flight.
sealed class AppTransition {
  const AppTransition();

  const factory AppTransition.starting({required DateTime since}) =
      AppTransitionStarting;
  const factory AppTransition.stopping() = AppTransitionStopping;
}

final class AppTransitionStarting extends AppTransition {
  const AppTransitionStarting({required this.since});

  final DateTime since;

  @override
  bool operator ==(Object other) =>
      other is AppTransitionStarting && since == other.since;

  @override
  int get hashCode => since.hashCode;
}

final class AppTransitionStopping extends AppTransition {
  const AppTransitionStopping();

  @override
  bool operator ==(Object other) => other is AppTransitionStopping;

  @override
  int get hashCode => 0;
}

abstract final class GlobalStateDerivation {
  /// `starting` gives up waiting for every tunnel after this long and shows
  /// `degraded`.
  static const startingTimeout = Duration(seconds: 30);

  static GlobalState derive({
    required Store store,
    required RuntimeStatus? status,
    required AppTransition? transition,
    DateTime? now,
  }) {
    if (transition is AppTransitionStopping) {
      return const GlobalState.stopping();
    }
    if (status == null) {
      return transition == null
          ? const GlobalState.off()
          : const GlobalState.starting();
    }
    switch (status.engine) {
      case EngineStateFailed(:final reason):
        return GlobalState.error(reason: reason);
      case EngineStateStopped():
        return transition == null
            ? const GlobalState.off()
            : const GlobalState.starting();
      case EngineStateStarting():
        return const GlobalState.starting();
      case EngineStateRunning():
        final (:failing, :waiting) = _classify(store, status);
        if (failing.isEmpty && waiting.isEmpty) return const GlobalState.on();
        if (transition is AppTransitionStarting &&
            failing.isEmpty &&
            (now ?? DateTime.now()).difference(transition.since) <
                startingTimeout) {
          return const GlobalState.starting();
        }
        return GlobalState.degraded(failingTunnelIDs: [...failing, ...waiting]);
    }
  }

  /// Enabled OpenVPN tunnels that are failing (failed / reconnecting) and those
  /// still on their first connection attempt, both in store order.
  static ({List<String> failing, List<String> waiting}) _classify(
    Store store,
    RuntimeStatus status,
  ) {
    final failing = <String>[];
    final waiting = <String>[];
    for (final tunnel in store.tunnels) {
      if (!tunnel.isEnabled || !tunnel.kind.isOpenVPN) continue;
      final state = status.tunnels[tunnel.id];
      switch (state) {
        case null || TunnelStateConnected() || TunnelStateDisabled():
          continue;
        case TunnelStateConnecting():
          waiting.add(tunnel.id);
        case TunnelStateReconnecting() || TunnelStateFailed():
          failing.add(tunnel.id);
      }
    }
    return (failing: failing, waiting: waiting);
  }
}
