import 'package:collection/collection.dart';
import 'package:wayfork/core/ipc/runtime_plan.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/secrets/secret_store.dart';
import 'package:wayfork/core/singbox/sing_box_config_generator.dart';

/// Secrets needed to turn a store into a runtime plan, keyed by lowercase
/// tunnel id.
final class PlanSecrets {
  PlanSecrets({
    Map<String, String> vlessUUIDs = const {},
    Map<String, String> openVPNConfigs = const {},
    Map<String, Credentials> credentials = const {},
    Map<String, String> keyPassphrases = const {},
  }) : vlessUUIDs = _lowercaseMap(vlessUUIDs),
       openVPNConfigs = _lowercaseMap(openVPNConfigs),
       credentials = Map.unmodifiable(
         credentials.map((key, value) => MapEntry(key.toLowerCase(), value)),
       ),
       keyPassphrases = _lowercaseMap(keyPassphrases);

  final Map<String, String> vlessUUIDs;
  final Map<String, String> openVPNConfigs;
  final Map<String, Credentials> credentials;
  final Map<String, String> keyPassphrases;

  /// Loads only the secrets required by enabled tunnels.
  static Future<PlanSecrets> load(Store store, SecretStore secretStore) async {
    final vlessUUIDs = <String, String>{};
    final openVPNConfigs = <String, String>{};
    final credentials = <String, Credentials>{};
    final keyPassphrases = <String, String>{};
    for (final tunnel in store.tunnels.where((tunnel) => tunnel.isEnabled)) {
      switch (tunnel.kind) {
        case TunnelKindOpenVPN(:final meta):
          final body = await secretStore.read(
            SecretKey(SecretKind.ovpn, tunnel.id),
          );
          if (body != null) openVPNConfigs[tunnel.id] = body;
          if (meta.needsCredentials) {
            final encoded = await secretStore.read(
              SecretKey(SecretKind.credentials, tunnel.id),
            );
            if (encoded != null) {
              try {
                final decoded = JsonCoding.decode(encoded);
                if (decoded is Map<String, Object?>) {
                  credentials[tunnel.id] = Credentials.fromJson(decoded);
                }
              } on FormatException {
                // A malformed optional credential is treated as absent, as in
                // the Swift `try?` path. Storage read failures still propagate.
              }
            }
          }
          if (meta.needsKeyPassphrase) {
            final passphrase = await secretStore.read(
              SecretKey(SecretKind.keyPassphrase, tunnel.id),
            );
            if (passphrase != null) keyPassphrases[tunnel.id] = passphrase;
          }
        case TunnelKindVLESS():
          final uuid = await secretStore.read(
            SecretKey(SecretKind.uuid, tunnel.id),
          );
          if (uuid != null) vlessUUIDs[tunnel.id] = uuid;
      }
    }
    return PlanSecrets(
      vlessUUIDs: vlessUUIDs,
      openVPNConfigs: openVPNConfigs,
      credentials: credentials,
      keyPassphrases: keyPassphrases,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlanSecrets &&
      const MapEquality<String, String>().equals(
        vlessUUIDs,
        other.vlessUUIDs,
      ) &&
      const MapEquality<String, String>().equals(
        openVPNConfigs,
        other.openVPNConfigs,
      ) &&
      const MapEquality<String, Credentials>().equals(
        credentials,
        other.credentials,
      ) &&
      const MapEquality<String, String>().equals(
        keyPassphrases,
        other.keyPassphrases,
      );

  @override
  int get hashCode => Object.hash(
    const MapEquality<String, String>().hash(vlessUUIDs),
    const MapEquality<String, String>().hash(openVPNConfigs),
    const MapEquality<String, Credentials>().hash(credentials),
    const MapEquality<String, String>().hash(keyPassphrases),
  );
}

/// Why an enabled tunnel was left out of the plan.
sealed class PlanWarning {
  const PlanWarning();

  /// The OpenVPN body or VLESS UUID is missing and must be re-attached.
  const factory PlanWarning.missingSecret(String tunnelID) =
      PlanWarningMissingSecret;
}

final class PlanWarningMissingSecret extends PlanWarning {
  const PlanWarningMissingSecret(this.tunnelID);

  final String tunnelID;

  @override
  bool operator ==(Object other) =>
      other is PlanWarningMissingSecret && tunnelID == other.tunnelID;

  @override
  int get hashCode => Object.hash(runtimeType, tunnelID);
}

final class RuntimePlanBuildResult {
  RuntimePlanBuildResult({
    required this.plan,
    required List<PlanWarning> warnings,
    required List<Tunnel> routedTunnels,
  }) : warnings = List.unmodifiable(warnings),
       routedTunnels = List.unmodifiable(routedTunnels);

  final RuntimePlan plan;
  final List<PlanWarning> warnings;
  final List<Tunnel> routedTunnels;

  @override
  bool operator ==(Object other) =>
      other is RuntimePlanBuildResult &&
      plan == other.plan &&
      const ListEquality<PlanWarning>().equals(warnings, other.warnings) &&
      const ListEquality<Tunnel>().equals(routedTunnels, other.routedTunnels);

  @override
  int get hashCode => Object.hash(
    plan,
    const ListEquality<PlanWarning>().hash(warnings),
    const ListEquality<Tunnel>().hash(routedTunnels),
  );
}

/// Store plus secrets becomes the desired runtime state.
abstract final class RuntimePlanBuilder {
  /// Resolved addresses are supplied by HostResolver. System DNS entries are
  /// routable snapshot entries; network resolvers name `dns-direct`.
  static RuntimePlanBuildResult build({
    required Store store,
    required PlanSecrets secrets,
    required String installDir,
    Map<String, List<String>> resolvedServerAddresses = const {},
    List<String> systemDNSServers = const [],
    List<String> networkResolvers = const [],
    WayforkPlatform platform = WayforkPlatform.windows,
  }) {
    final warnings = <PlanWarning>[];
    final openVPN = <OpenVPNRuntime>[];
    final effectiveTunnels = [...store.tunnels];

    // A tunnel without its primary secret cannot run. Disable it in the
    // generator input so sing-box never references an interface that is absent.
    for (var index = 0; index < effectiveTunnels.length; index++) {
      final tunnel = effectiveTunnels[index];
      if (!tunnel.isEnabled) continue;
      switch (tunnel.kind) {
        case TunnelKindOpenVPN():
          final config = secrets.openVPNConfigs[tunnel.id];
          if (config == null) {
            warnings.add(PlanWarning.missingSecret(tunnel.id));
            effectiveTunnels[index] = tunnel.copyWith(isEnabled: false);
            continue;
          }
          openVPN.add(
            OpenVPNRuntime(
              id: tunnel.id,
              interface: platform.openVPNInterface(tunnel.slot),
              config: config,
              credentials: secrets.credentials[tunnel.id],
              keyPassphrase: secrets.keyPassphrases[tunnel.id],
            ),
          );
        case TunnelKindVLESS():
          if (!secrets.vlessUUIDs.containsKey(tunnel.id)) {
            warnings.add(PlanWarning.missingSecret(tunnel.id));
            effectiveTunnels[index] = tunnel.copyWith(isEnabled: false);
          }
      }
    }

    final effectiveStore = store.copyWith(tunnels: effectiveTunnels);
    final generated = SingBoxConfigGenerator.generate(
      SingBoxInput(
        store: effectiveStore,
        vlessUUIDs: secrets.vlessUUIDs,
        openVPNBinaryPath: platform.openVPNBinaryPath(installDir),
        resolvedServerAddresses: resolvedServerAddresses,
        systemDNSServers: systemDNSServers,
        networkResolvers: networkResolvers,
        platform: platform,
      ),
    );
    final plan = RuntimePlan(
      singBox: SingBoxPlan(
        config: generated.config,
        ruleSets: generated.ruleSets,
      ),
      openVPN: openVPN,
      autoReconnect: store.settings.autoReconnect,
      logLevel: store.settings.logLevel,
      overrideSystemDNS: store.settings.overrideSystemDNS,
    );
    return RuntimePlanBuildResult(
      plan: plan,
      warnings: warnings,
      routedTunnels: generated.routedTunnels,
    );
  }
}

Map<String, String> _lowercaseMap(Map<String, String> values) =>
    Map.unmodifiable(
      values.map((key, value) => MapEntry(key.toLowerCase(), value)),
    );
