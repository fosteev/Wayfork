import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/secrets/secret_store.dart';

enum ImportMode { replace, merge }

final class ImportPreview {
  const ImportPreview({
    required this.tunnels,
    required this.rules,
    required this.includesSecrets,
    required this.tunnelsWithSecrets,
  });

  final int tunnels;
  final int rules;
  final bool includesSecrets;
  final int tunnelsWithSecrets;

  @override
  bool operator ==(Object other) =>
      other is ImportPreview &&
      tunnels == other.tunnels &&
      rules == other.rules &&
      includesSecrets == other.includesSecrets &&
      tunnelsWithSecrets == other.tunnelsWithSecrets;

  @override
  int get hashCode =>
      Object.hash(tunnels, rules, includesSecrets, tunnelsWithSecrets);
}

final class ImportOutcome {
  const ImportOutcome({
    required this.store,
    required this.secrets,
    required this.warnings,
    required this.tunnelsAdded,
    required this.tunnelsUpdated,
    required this.rulesAdded,
    required this.rulesUpdated,
    required this.rulesSkipped,
  });

  final Store store;

  /// Secrets carried by the file, ready for `SecretStore.write`.
  final Map<SecretKey, String> secrets;
  final List<String> warnings;
  final int tunnelsAdded;
  final int tunnelsUpdated;
  final int rulesAdded;
  final int rulesUpdated;
  final int rulesSkipped;
}

/// Applies a `wayfork-export.json` to the store (docs/design/02-ux.md, F7).
abstract final class StoreImporter {
  static ImportPreview preview(ExportDocument document) => ImportPreview(
    tunnels: document.tunnels.length,
    rules: document.rules.length,
    includesSecrets: document.includesSecrets,
    tunnelsWithSecrets: document.tunnels
        .where((tunnel) => !tunnel.secrets.isEmpty)
        .length,
  );

  static ImportOutcome apply(
    ExportDocument document, {
    required Store to,
    required ImportMode mode,
  }) {
    var result = mode == ImportMode.replace
        ? Store(schemaVersion: to.schemaVersion, settings: document.settings)
        : to;
    final secrets = <SecretKey, String>{};
    final warnings = <String>[];
    var tunnelsAdded = 0;
    var tunnelsUpdated = 0;

    for (final exported in document.tunnels) {
      final tunnels = [...result.tunnels];
      final index = mode == ImportMode.merge
          ? tunnels.indexWhere((tunnel) => tunnel.id == exported.id)
          : -1;
      if (index >= 0) {
        final name = _availableName(
          exported.name,
          id: exported.id,
          store: result,
          warnings: warnings,
        );
        tunnels[index] = tunnels[index].copyWith(
          name: name,
          isEnabled: exported.isEnabled,
          kind: exported.kind,
          createdAt: exported.createdAt,
        );
        result = result.copyWith(tunnels: tunnels);
        tunnelsUpdated += 1;
        _collect(exported.secrets, id: exported.id, into: secrets);
        continue;
      }

      final slot = result.nextFreeSlot();
      if (slot == null) {
        warnings.add('Tunnel ${exported.name} skipped: no free slots');
        continue;
      }
      final name = _availableName(
        exported.name,
        id: exported.id,
        store: result,
        warnings: warnings,
      );
      tunnels.add(
        Tunnel(
          id: exported.id,
          name: name,
          isEnabled: exported.isEnabled,
          slot: slot,
          kind: exported.kind,
          createdAt: exported.createdAt,
        ),
      );
      result = result.copyWith(tunnels: tunnels);
      tunnelsAdded += 1;
      _collect(exported.secrets, id: exported.id, into: secrets);
    }

    var rulesAdded = 0;
    var rulesUpdated = 0;
    var rulesSkipped = 0;
    final rules = mode == ImportMode.replace ? <Rule>[] : [...result.rules];
    final tunnelIDs = result.tunnels.map((tunnel) => tunnel.id).toSet();
    for (final rule in document.rules) {
      final tunnelID = rule.tunnelID;
      if (tunnelID != null && !tunnelIDs.contains(tunnelID)) {
        warnings.add(
          'Rule ${rule.pattern} skipped: tunnel ${_short(tunnelID)}… not found',
        );
        rulesSkipped += 1;
        continue;
      }
      final index = mode == ImportMode.merge
          ? rules.indexWhere((existing) => existing.id == rule.id)
          : -1;
      if (index >= 0) {
        rules[index] = rule;
        rulesUpdated += 1;
      } else {
        rules.add(rule);
        rulesAdded += 1;
      }
    }
    result = result.copyWith(rules: rules);

    // F8: the file's default replaces the current one only when it names a
    // tunnel that made it in; on Replace the fresh store has none to begin with.
    final wanted = document.defaultTunnelID;
    if (wanted != null) {
      if (tunnelIDs.contains(wanted)) {
        result = result.copyWith(defaultTunnelID: wanted);
      } else {
        warnings.add(
          'Default tunnel ${_short(wanted)}… not found: everything else stays '
          'direct',
        );
      }
    }

    return ImportOutcome(
      store: result,
      secrets: secrets,
      warnings: warnings,
      tunnelsAdded: tunnelsAdded,
      tunnelsUpdated: tunnelsUpdated,
      rulesAdded: rulesAdded,
      rulesUpdated: rulesUpdated,
      rulesSkipped: rulesSkipped,
    );
  }

  static String _short(String id) => id.substring(0, 4);

  static String _availableName(
    String requested, {
    required String id,
    required Store store,
    required List<String> warnings,
  }) {
    if (store.isNameAvailable(requested, excluding: id)) return requested;
    var number = 2;
    while (true) {
      final suffix = ' ($number)';
      final keep = Tunnel.nameMaxLength - suffix.length;
      final base = requested.length > keep
          ? requested.substring(0, keep)
          : requested;
      final candidate = base + suffix;
      if (store.isNameAvailable(candidate, excluding: id)) {
        warnings.add('Tunnel $requested renamed to $candidate');
        return candidate;
      }
      number += 1;
    }
  }

  static void _collect(
    TunnelSecrets tunnelSecrets, {
    required String id,
    required Map<SecretKey, String> into,
  }) {
    final ovpn = tunnelSecrets.ovpn;
    if (ovpn != null) into[SecretKey(SecretKind.ovpn, id)] = ovpn;
    final credentials = tunnelSecrets.credentials;
    if (credentials != null) {
      into[SecretKey(SecretKind.credentials, id)] = JsonCoding.encodeCompact(
        credentials.toJson(),
      );
    }
    final passphrase = tunnelSecrets.keyPassphrase;
    if (passphrase != null) {
      into[SecretKey(SecretKind.keyPassphrase, id)] = passphrase;
    }
    final uuid = tunnelSecrets.uuid;
    if (uuid != null) into[SecretKey(SecretKind.uuid, id)] = uuid;
  }
}

abstract final class StoreExporter {
  static Future<ExportDocument> document({
    required Store store,
    required SecretStore secretStore,
    required bool includeSecrets,
    DateTime? exportedAt,
  }) async {
    final tunnels = <ExportedTunnel>[];
    for (final tunnel in store.tunnels) {
      if (!includeSecrets) {
        tunnels.add(ExportedTunnel.fromTunnel(tunnel));
        continue;
      }
      final TunnelSecrets secrets;
      switch (tunnel.kind) {
        case TunnelKindOpenVPN():
          secrets = TunnelSecrets(
            ovpn: await secretStore.read(SecretKey(SecretKind.ovpn, tunnel.id)),
            credentials: await secretStore.readCredentials(tunnel.id),
            keyPassphrase: await secretStore.read(
              SecretKey(SecretKind.keyPassphrase, tunnel.id),
            ),
          );
        case TunnelKindVLESS():
          secrets = TunnelSecrets(
            uuid: await secretStore.read(SecretKey(SecretKind.uuid, tunnel.id)),
          );
      }
      tunnels.add(ExportedTunnel.fromTunnel(tunnel, secrets: secrets));
    }
    return ExportDocument(
      exportedAt: exportedAt,
      includesSecrets: includeSecrets,
      tunnels: tunnels,
      rules: store.rules,
      settings: store.settings,
      defaultTunnelID: store.defaultTunnelID,
    );
  }
}
