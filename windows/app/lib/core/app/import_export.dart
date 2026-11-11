import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:wayfork/core/support/uuid.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/model/local_proxy.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/model/tunnel_group.dart';
import 'package:wayfork/core/rules/rule_pattern_error.dart';
import 'package:wayfork/core/secrets/secret_store.dart';

enum ImportMode { replace, merge }

final class ImportPreview {
  const ImportPreview({
    required this.tunnels,
    required this.rules,
    required this.includesSecrets,
    required this.tunnelsWithSecrets,
    this.foreignAppRules = 0,
  });

  final int tunnels;
  final int rules;
  final bool includesSecrets;
  final int tunnelsWithSecrets;

  /// App rules whose path belongs to another platform — a macOS export names
  /// `/Applications/Foo.app`, which no process on Windows will ever match.
  /// They are imported all the same (a round trip must not lose them) but the
  /// import sheet says how many there are.
  final int foreignAppRules;

  @override
  bool operator ==(Object other) =>
      other is ImportPreview &&
      tunnels == other.tunnels &&
      rules == other.rules &&
      includesSecrets == other.includesSecrets &&
      tunnelsWithSecrets == other.tunnelsWithSecrets &&
      foreignAppRules == other.foreignAppRules;

  @override
  int get hashCode => Object.hash(
    tunnels,
    rules,
    includesSecrets,
    tunnelsWithSecrets,
    foreignAppRules,
  );
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
  static ImportPreview preview(
    ExportDocument document, {
    WayforkPlatform platform = WayforkPlatform.windows,
  }) => ImportPreview(
    tunnels: document.tunnels.length,
    rules: document.rules.length,
    includesSecrets: document.includesSecrets,
    tunnelsWithSecrets: document.tunnels
        .where((tunnel) => !tunnel.secrets.isEmpty)
        .length,
    foreignAppRules: document.rules
        .where((rule) => rule.match.isApp && !_belongsHere(rule, platform))
        .length,
  );

  static bool _belongsHere(Rule rule, WayforkPlatform platform) {
    try {
      platform.normalizeAppPath(rule.pattern);
      return true;
    } on RulePatternException {
      return false;
    }
  }

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
          localProxy: _importedProxy(
            exported.localProxy,
            name: exported.name,
            id: exported.id,
            store: result,
            warnings: warnings,
          ),
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
          localProxy: _importedProxy(
            exported.localProxy,
            name: exported.name,
            id: exported.id,
            store: result,
            warnings: warnings,
          ),
        ),
      );
      result = result.copyWith(tunnels: tunnels);
      tunnelsAdded += 1;
      _collect(exported.secrets, id: exported.id, into: secrets);
    }

    // F16: a group comes in when at least two of its members did; a colliding
    // name is suffixed like a tunnel's. On Merge an existing group is replaced
    // by id.
    final tunnelIDs = result.tunnels.map((tunnel) => tunnel.id).toSet();
    final groups = mode == ImportMode.replace
        ? <TunnelGroup>[]
        : [...result.groups];
    result = result.copyWith(groups: groups);
    for (final group in document.groups) {
      final members = group.members.where(tunnelIDs.contains).toList();
      if (members.length < TunnelGroup.minimumMembers) {
        warnings.add(
          'Group ${group.name} skipped: fewer than two of its tunnels made it '
          'in',
        );
        continue;
      }
      var imported = group.copyWith(
        members: members,
        localProxy: _importedProxy(
          group.localProxy,
          name: group.name,
          id: group.id,
          store: result,
          warnings: warnings,
        ),
      );
      final index = groups.indexWhere((existing) => existing.id == group.id);
      if (index >= 0) {
        groups[index] = imported;
      } else {
        imported = imported.copyWith(
          name: _availableName(
            group.name,
            id: group.id,
            store: result,
            warnings: warnings,
          ),
        );
        groups.add(imported);
      }
      result = result.copyWith(groups: groups);
    }
    final exitIDs = {...tunnelIDs, ...result.groups.map((group) => group.id)};

    var rulesAdded = 0;
    const rulesUpdated = 0;
    const rulesSkipped = 0;
    final rules = mode == ImportMode.replace ? <Rule>[] : [...result.rules];
    var lists = mode == ImportMode.replace
        ? [...document.lists]
        : [...result.lists];
    final listIDs = <String, String>{};
    ImportOutcome invalid(String reason) => ImportOutcome(
      store: to,
      secrets: const {},
      warnings: [reason],
      tunnelsAdded: 0,
      tunnelsUpdated: 0,
      rulesAdded: 0,
      rulesUpdated: 0,
      rulesSkipped: document.rules.length,
    );
    if (mode == ImportMode.merge) {
      if (document.lists.isNotEmpty && result.lists.isNotEmpty) {
        warnings.add(
          'Existing earlier lists can take precedence over imported rules',
        );
      }
      for (final source in document.lists) {
        if (lists.contains(source)) {
          listIDs[source.id] = source.id;
          continue;
        }
        var imported = source;
        final sameID = lists.where((list) => list.id == source.id).firstOrNull;
        // A previous import may have disambiguated only its display name. Recognize
        // that deterministic name without treating an arbitrary edit as identical.
        if (sameID != null &&
            source.copyWith(name: sameID.name) == sameID &&
            sameID.name ==
                result
                    .copyWith(
                      lists: lists
                          .where((list) => list.id != source.id)
                          .toList(),
                    )
                    .availableListName(source.name)) {
          listIDs[source.id] = source.id;
          continue;
        }
        if (sameID != null) {
          imported = imported.copyWith(
            id: _remappedID(source.id, source.toJson()),
          );
          final existing = lists
              .where((list) => list.id == imported.id)
              .firstOrNull;
          if (existing != null) {
            if (imported.copyWith(name: existing.name) == existing) {
              listIDs[source.id] = existing.id;
              continue;
            }
            return invalid('List identity collision: import left unchanged');
          }
          warnings.add('List ${source.name} imported with a new ID');
        }
        imported = imported.copyWith(
          name: result.copyWith(lists: lists).availableListName(source.name),
        );
        if (imported.name != source.name) {
          warnings.add('List ${source.name} renamed to ${imported.name}');
        }
        listIDs[source.id] = imported.id;
        lists = [...lists, imported];
      }
    }
    for (final source in document.rules) {
      var rule = source.copyWith(
        listID: listIDs[source.listID] ?? source.listID,
      );
      if (rules.contains(rule)) continue;
      if (mode == ImportMode.merge &&
          rules.any((existing) => existing.id == rule.id)) {
        rule = rule.copyWith(id: _remappedID(source.id, rule.toJson()));
        if (rules.contains(rule)) continue;
        if (rules.any((existing) => existing.id == rule.id)) {
          return invalid('Rule identity collision: import left unchanged');
        }
      }
      if (mode == ImportMode.merge &&
          rules.any((existing) => existing.copyWith(id: rule.id) == rule)) {
        continue;
      }
      rules.add(rule);
      rulesAdded++;
    }
    result = result.copyWith(rules: rules, lists: lists);
    try {
      result.validateMembership();
    } on Object catch (error) {
      return invalid('Invalid list membership: $error');
    }

    // F8: the file's default replaces the current one only when it names a
    // tunnel that made it in; on Replace the fresh store has none to begin with.
    final wanted = document.defaultTunnelID;
    if (wanted != null) {
      if (exitIDs.contains(wanted)) {
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

  static String _remappedID(String id, Map<String, Object?> content) {
    final hash = sha256
        .convert(
          utf8.encode(Uuid.encode(id) + JsonCoding.encodeCompact(content)),
        )
        .toString()
        .substring(0, 32);
    return '${hash.substring(0, 8)}-${hash.substring(8, 12)}-${hash.substring(12, 16)}-${hash.substring(16, 20)}-${hash.substring(20)}';
  }

  static String _short(String id) => id.substring(0, 4);

  /// F17: a port that another tunnel or group already holds is dropped with a
  /// warning (the address is machine-local anyway); an invalid one too.
  static LocalProxy? _importedProxy(
    LocalProxy? proxy, {
    required String name,
    required String id,
    required Store store,
    required List<String> warnings,
  }) {
    if (proxy == null) return null;
    if (!LocalProxy.isValidPort(proxy.port)) {
      warnings.add(
        'Local proxy port ${proxy.port} of $name dropped: outside 1024–65535',
      );
      return null;
    }
    final owner = store.localProxyPortOwner(proxy.port, excluding: id);
    if (owner != null) {
      warnings.add(
        'Local proxy port ${proxy.port} of $name dropped: already used by '
        '$owner',
      );
      return null;
    }
    return proxy;
  }

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
    final password = tunnelSecrets.password;
    if (password != null) into[SecretKey(SecretKind.password, id)] = password;
    final privateKey = tunnelSecrets.privateKey;
    if (privateKey != null) {
      into[SecretKey(SecretKind.privateKey, id)] = privateKey;
    }
    final presharedKey = tunnelSecrets.presharedKey;
    if (presharedKey != null) {
      into[SecretKey(SecretKind.presharedKey, id)] = presharedKey;
    }
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
        case TunnelKindVMess():
          secrets = TunnelSecrets(
            uuid: await secretStore.read(SecretKey(SecretKind.uuid, tunnel.id)),
          );
        case TunnelKindWireGuard():
          secrets = TunnelSecrets(
            privateKey: await secretStore.read(
              SecretKey(SecretKind.privateKey, tunnel.id),
            ),
            presharedKey: await secretStore.read(
              SecretKey(SecretKind.presharedKey, tunnel.id),
            ),
          );
        case TunnelKindShadowsocks():
        case TunnelKindTrojan():
          secrets = TunnelSecrets(
            password: await secretStore.read(
              SecretKey(SecretKind.password, tunnel.id),
            ),
          );
      }
      tunnels.add(ExportedTunnel.fromTunnel(tunnel, secrets: secrets));
    }
    return ExportDocument(
      exportedAt: exportedAt,
      includesSecrets: includeSecrets,
      tunnels: tunnels,
      rules: store.rules,
      lists: store.lists,
      settings: store.settings,
      defaultTunnelID: store.defaultTunnelID,
      groups: store.groups,
    );
  }
}
