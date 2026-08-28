import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/app/import_export.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/secrets/secret_store.dart';
import 'package:wayfork/core/support/uuid.dart';

import '../fixtures.dart';

final importDate = DateTime.utc(2026, 8, 25, 12);
const importedOpenVPNID = '10000000-0000-4000-8000-000000000001';
const importedVLESSID = '10000000-0000-4000-8000-000000000002';

Tunnel openVPNTunnel({
  String id = importedOpenVPNID,
  String name = 'Work',
  int slot = 17,
}) => Tunnel(
  id: id,
  name: name,
  slot: slot,
  kind: TunnelKindOpenVPN(
    OpenVPNMeta(
      remotes: const [
        Remote(host: 'vpn.example.com', port: 1194, proto: 'udp'),
      ],
      needsCredentials: true,
      needsKeyPassphrase: true,
      configHash: 'example-hash',
    ),
  ),
  createdAt: importDate,
);

Tunnel vlessTunnel({
  String id = importedVLESSID,
  String name = 'Home',
  int slot = 23,
}) => Tunnel(
  id: id,
  name: name,
  slot: slot,
  kind: TunnelKindVLESS(
    VLESSMeta(
      server: 'proxy.example.com',
      port: 443,
      security: VLESSSecurity.tls,
    ),
  ),
  createdAt: importDate,
);

ExportDocument document({
  required List<ExportedTunnel> tunnels,
  List<Rule> rules = const [],
  Settings settings = const Settings(),
  bool includesSecrets = false,
  String? defaultTunnelID,
}) => ExportDocument(
  exportedAt: importDate,
  includesSecrets: includesSecrets,
  tunnels: tunnels,
  rules: rules,
  settings: settings,
  defaultTunnelID: defaultTunnelID,
);

void main() {
  test('preview counts contents and secrets', () {
    final export = document(
      tunnels: [
        ExportedTunnel.fromTunnel(
          openVPNTunnel(),
          secrets: const TunnelSecrets(ovpn: 'client\n'),
        ),
        ExportedTunnel.fromTunnel(vlessTunnel()),
      ],
      rules: [Rule.tunnel(pattern: 'example.com', tunnelID: importedOpenVPNID)],
      includesSecrets: true,
    );
    expect(
      StoreImporter.preview(export),
      const ImportPreview(
        tunnels: 2,
        rules: 1,
        includesSecrets: true,
        tunnelsWithSecrets: 1,
      ),
    );
  });

  test('replace reassigns slots, settings, rules and secrets', () {
    const unknownID = '10000000-0000-4000-8000-000000000099';
    const credentials = Credentials(
      username: 'example-user',
      password: 'example-password',
    );
    const settings = Settings(connectOnLaunch: true, logLevel: LogLevel.debug);
    final export = document(
      tunnels: [
        ExportedTunnel.fromTunnel(
          openVPNTunnel(),
          secrets: const TunnelSecrets(
            ovpn: 'client\nremote vpn.example.com 1194\n',
            credentials: credentials,
            keyPassphrase: 'example-passphrase',
          ),
        ),
        ExportedTunnel.fromTunnel(
          vlessTunnel(),
          secrets: const TunnelSecrets(uuid: 'example-uuid'),
        ),
      ],
      rules: [
        Rule.tunnel(pattern: 'valid.example.com', tunnelID: importedOpenVPNID),
        Rule.tunnel(pattern: 'missing.example.com', tunnelID: unknownID),
      ],
      settings: settings,
      includesSecrets: true,
    );
    final original = Store(schemaVersion: 7, tunnels: [Fixtures.work]);

    final outcome = StoreImporter.apply(
      export,
      to: original,
      mode: ImportMode.replace,
    );

    expect(outcome.store.schemaVersion, 7);
    expect(outcome.store.tunnels.map((t) => t.slot), [0, 1]);
    expect(outcome.store.settings, settings);
    expect(outcome.store.rules.map((r) => r.pattern), ['valid.example.com']);
    expect(outcome.tunnelsAdded, 2);
    expect(outcome.rulesAdded, 1);
    expect(outcome.rulesSkipped, 1);
    expect(outcome.warnings, hasLength(1));
    expect(outcome.warnings[0], contains('missing.example.com'));
    expect(outcome.secrets, hasLength(4));
    expect(
      outcome.secrets[SecretKey(SecretKind.ovpn, importedOpenVPNID)],
      startsWith('client'),
    );
    expect(
      outcome.secrets[SecretKey(SecretKind.keyPassphrase, importedOpenVPNID)],
      'example-passphrase',
    );
    expect(
      outcome.secrets[SecretKey(SecretKind.uuid, importedVLESSID)],
      'example-uuid',
    );
    final credentialsJSON =
        outcome.secrets[SecretKey(SecretKind.credentials, importedOpenVPNID)]!;
    expect(
      Credentials.fromJson(
        JsonCoding.decode(credentialsJSON)! as Map<String, Object?>,
      ),
      credentials,
    );
  });

  test('merge updates and appends without replacing settings', () {
    const existingRuleID = '20000000-0000-4000-8000-000000000001';
    const newRuleID = '20000000-0000-4000-8000-000000000002';
    final existing = openVPNTunnel(name: 'Office', slot: 5);
    final collision = vlessTunnel(
      id: '10000000-0000-4000-8000-000000000003',
      name: 'Work',
      slot: 0,
    );
    final oldRule = Rule.tunnel(
      id: existingRuleID,
      pattern: 'old.example.com',
      tunnelID: existing.id,
    );
    const originalSettings = Settings(
      launchAtLogin: true,
      logRetentionDays: 30,
    );
    final original = Store(
      tunnels: [existing, collision],
      rules: [oldRule],
      settings: originalSettings,
    );
    final updated = existing.copyWith(
      name: 'Work',
      isEnabled: false,
      kind: vlessTunnel().kind,
    );
    final added = vlessTunnel(name: 'Personal');
    final export = document(
      tunnels: [
        ExportedTunnel.fromTunnel(updated),
        ExportedTunnel.fromTunnel(added),
      ],
      rules: [
        Rule.tunnel(
          id: existingRuleID,
          pattern: 'updated.example.com',
          match: RuleMatch.exact,
          tunnelID: existing.id,
          isEnabled: false,
          note: 'updated',
        ),
        Rule.tunnel(
          id: newRuleID,
          pattern: 'new.example.com',
          tunnelID: added.id,
        ),
      ],
      settings: const Settings(connectOnLaunch: true),
    );

    final outcome = StoreImporter.apply(
      export,
      to: original,
      mode: ImportMode.merge,
    );

    expect(outcome.store.tunnels.map((t) => t.id), [
      existing.id,
      collision.id,
      added.id,
    ]);
    expect(outcome.store.tunnels[0].slot, 5);
    expect(outcome.store.tunnels[0].name, 'Work (2)');
    expect(outcome.store.tunnels[0].isEnabled, isFalse);
    expect(outcome.store.tunnels[0].kind, updated.kind);
    expect(outcome.store.tunnels[2].slot, 1);
    expect(outcome.store.rules.map((r) => r.id), [existingRuleID, newRuleID]);
    expect(outcome.store.rules[0].pattern, 'updated.example.com');
    expect(outcome.store.settings, originalSettings);
    expect(outcome.tunnelsAdded, 1);
    expect(outcome.tunnelsUpdated, 1);
    expect(outcome.rulesAdded, 1);
    expect(outcome.rulesUpdated, 1);
    expect(outcome.warnings, ['Tunnel Work renamed to Work (2)']);
  });

  test('merge skips a new tunnel when all slots are taken', () {
    final tunnels = [
      for (var slot = 0; slot < Tunnel.maxSlots; slot++)
        vlessTunnel(id: Uuid.generate(), name: 'Tunnel $slot', slot: slot),
    ];
    final export = document(
      tunnels: [ExportedTunnel.fromTunnel(openVPNTunnel())],
    );

    final outcome = StoreImporter.apply(
      export,
      to: Store(tunnels: tunnels),
      mode: ImportMode.merge,
    );

    expect(outcome.store.tunnels, hasLength(Tunnel.maxSlots));
    expect(outcome.tunnelsAdded, 0);
    expect(outcome.warnings, ['Tunnel Work skipped: no free slots']);
  });

  test('exporter round-trips with and without secrets', () async {
    final rules = [
      Rule.tunnel(pattern: 'work.example.com', tunnelID: importedOpenVPNID),
      Rule.tunnel(pattern: 'home.example.com', tunnelID: importedVLESSID),
    ];
    final store = Store(
      tunnels: [openVPNTunnel(), vlessTunnel()],
      rules: rules,
    );
    const credentials = Credentials(
      username: 'example-user',
      password: 'example-password',
    );
    final secretStore = InMemorySecretStore({
      SecretKey(SecretKind.ovpn, importedOpenVPNID):
          'client\nremote vpn.example.com 1194\n',
      SecretKey(SecretKind.keyPassphrase, importedOpenVPNID):
          'example-passphrase',
      SecretKey(SecretKind.uuid, importedVLESSID): 'example-uuid',
    });
    await secretStore.writeCredentials(credentials, importedOpenVPNID);

    final exported = await StoreExporter.document(
      store: store,
      secretStore: secretStore,
      includeSecrets: true,
      exportedAt: importDate,
    );
    final decoded = ExportDocument.decode(exported.encode());
    final imported = StoreImporter.apply(
      decoded,
      to: Store.empty,
      mode: ImportMode.replace,
    );

    expect(
      imported.store.tunnels.map(ExportedTunnel.fromTunnel),
      store.tunnels.map(ExportedTunnel.fromTunnel),
    );
    expect(imported.store.rules, store.rules);
    expect(imported.secrets, hasLength(4));
    for (final key in [
      SecretKey(SecretKind.ovpn, importedOpenVPNID),
      SecretKey(SecretKind.credentials, importedOpenVPNID),
      SecretKey(SecretKind.keyPassphrase, importedOpenVPNID),
      SecretKey(SecretKind.uuid, importedVLESSID),
    ]) {
      expect(imported.secrets[key], await secretStore.read(key));
    }

    final sanitized = await StoreExporter.document(
      store: store,
      secretStore: secretStore,
      includeSecrets: false,
      exportedAt: importDate,
    );
    expect(sanitized.includesSecrets, isFalse);
    expect(sanitized.tunnels.map((t) => t.secrets.isEmpty), [true, true]);
  });

  test('import carries exceptions and the default tunnel (F8)', () async {
    const unknownID = '10000000-0000-4000-8000-000000000099';
    final export = document(
      tunnels: [
        ExportedTunnel.fromTunnel(openVPNTunnel()),
        ExportedTunnel.fromTunnel(vlessTunnel()),
      ],
      rules: [
        Rule.tunnel(pattern: 'work.example.com', tunnelID: importedOpenVPNID),
        Rule(pattern: 'bank.example.org', target: const RuleTargetDirect()),
      ],
      defaultTunnelID: importedVLESSID,
    );
    final decoded = ExportDocument.decode(export.encode());
    expect(decoded.defaultTunnelID, importedVLESSID);

    final replaced = StoreImporter.apply(
      decoded,
      to: Store.empty,
      mode: ImportMode.replace,
    );
    expect(replaced.store.defaultTunnelID, importedVLESSID);
    expect(replaced.store.rules.map((r) => r.target), [
      RuleTargetTunnel(importedOpenVPNID),
      const RuleTargetDirect(),
    ]);
    expect(replaced.rulesSkipped, 0);

    // Merge keeps the current default when the file has none…
    final current = replaced.store.copyWith(defaultTunnelID: importedOpenVPNID);
    final noDefault = document(
      tunnels: [ExportedTunnel.fromTunnel(vlessTunnel())],
    );
    expect(
      StoreImporter.apply(
        noDefault,
        to: current,
        mode: ImportMode.merge,
      ).store.defaultTunnelID,
      importedOpenVPNID,
    );
    // …replaces it when the file names a tunnel that is present…
    expect(
      StoreImporter.apply(
        decoded,
        to: current,
        mode: ImportMode.merge,
      ).store.defaultTunnelID,
      importedVLESSID,
    );
    // …and drops a default pointing at a skipped tunnel with a warning.
    final dangling = document(
      tunnels: decoded.tunnels,
      rules: decoded.rules,
      defaultTunnelID: unknownID,
    );
    final outcome = StoreImporter.apply(
      dangling,
      to: current,
      mode: ImportMode.merge,
    );
    expect(outcome.store.defaultTunnelID, importedOpenVPNID);
    expect(
      outcome.warnings.any((w) => w.startsWith('Default tunnel 1000…')),
      isTrue,
    );
    expect(
      StoreImporter.apply(
        dangling,
        to: Store.empty,
        mode: ImportMode.replace,
      ).store.defaultTunnelID,
      isNull,
    );

    // The exporter writes the store's default.
    final exported = await StoreExporter.document(
      store: replaced.store.copyWith(defaultTunnelID: importedOpenVPNID),
      secretStore: InMemorySecretStore({}),
      includeSecrets: false,
      exportedAt: importDate,
    );
    expect(exported.defaultTunnelID, importedOpenVPNID);
    expect(exported.rules.any((r) => r.isException), isTrue);
  });
}
