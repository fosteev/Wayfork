import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/plan/runtime_plan_builder.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/secrets/secret_store.dart';
import 'package:wayfork/core/support/hashing.dart';

import '../fixtures.dart';

const _installDir = r'C:\Program Files\Wayfork';

void main() {
  test('PlanSecrets loads only what enabled tunnels need', () async {
    final secretStore = InMemorySecretStore();
    await secretStore.write(
      'client\nremote vpn.example.org 1194\n',
      SecretKey(SecretKind.ovpn, Fixtures.workID),
    );
    await secretStore.writeCredentials(
      const Credentials(username: 'u', password: 'p'),
      Fixtures.workID,
    );
    await secretStore.write(
      'passphrase',
      SecretKey(SecretKind.keyPassphrase, Fixtures.workID),
    );
    await secretStore.write(
      '00000000-0000-4000-8000-0000000000aa',
      SecretKey(SecretKind.uuid, Fixtures.homeID),
    );

    final store = Fixtures.store();
    final loaded = await PlanSecrets.load(store, secretStore);
    expect(loaded.openVPNConfigs[Fixtures.workID], isNotNull);
    expect(loaded.credentials[Fixtures.workID]?.username, 'u');
    expect(loaded.keyPassphrases[Fixtures.workID], isNull);
    expect(
      loaded.vlessUUIDs[Fixtures.homeID],
      '00000000-0000-4000-8000-0000000000aa',
    );

    final partialStore = store.copyWith(
      tunnels: [store.tunnels[0], store.tunnels[1].copyWith(isEnabled: false)],
    );
    final partial = await PlanSecrets.load(partialStore, secretStore);
    expect(partial.vlessUUIDs, isEmpty);
  });

  test('plan builder skips tunnels without secrets', () {
    final store = _twoTunnelStore();
    final secrets = PlanSecrets(
      openVPNConfigs: {
        Fixtures.workID: 'client\nremote vpn.example.org 1194\n',
      },
      credentials: {
        Fixtures.workID: const Credentials(username: 'u', password: 'p'),
      },
    );
    final result = RuntimePlanBuilder.build(
      store: store,
      secrets: secrets,
      installDir: _installDir,
      platform: WayforkPlatform.windows,
    );
    expect(result.warnings, [PlanWarning.missingSecret(Fixtures.homeID)]);
    expect(result.routedTunnels.map((tunnel) => tunnel.id), [Fixtures.workID]);
    expect(result.plan.openVPN, hasLength(1));
    expect(result.plan.openVPN[0].interface, 'Wayfork-1');
    expect(result.plan.openVPN[0].id, Fixtures.workID);
    expect(result.plan.openVPN[0].credentials?.username, 'u');
    expect(result.plan.singBox.ruleSets, hasLength(4));
    expect(
      result.plan.singBox.configHash,
      Hashing.sha256Hex(result.plan.singBox.config),
    );
    expect(
      result.plan.singBox.config,
      contains(r'C:\\Program Files\\Wayfork\\bin\\openvpn.exe'),
    );

    final again = RuntimePlanBuilder.build(
      store: store,
      secrets: secrets,
      installDir: _installDir,
      platform: WayforkPlatform.windows,
    );
    expect(again.plan.planHash, result.plan.planHash);
    final changed = store.copyWith(
      rules: [
        ...store.rules,
        Rule.tunnel(pattern: 'new.example', tunnelID: Fixtures.workID),
      ],
    );
    final next = RuntimePlanBuilder.build(
      store: changed,
      secrets: secrets,
      installDir: _installDir,
      platform: WayforkPlatform.windows,
    );
    expect(next.plan.planHash, isNot(result.plan.planHash));
    expect(next.plan.singBox.configHash, result.plan.singBox.configHash);
  });

  test('plan carries runtime settings and caller network inputs', () {
    final store = _twoTunnelStore().copyWith(
      settings: _twoTunnelStore().settings.copyWith(
        autoReconnect: false,
        overrideSystemDNS: false,
      ),
    );
    final result = RuntimePlanBuilder.build(
      store: store,
      secrets: PlanSecrets(
        vlessUUIDs: const {
          Fixtures.homeID: '00000000-0000-4000-8000-0000000000aa',
        },
        openVPNConfigs: const {Fixtures.workID: 'client\n'},
      ),
      installDir: _installDir,
      resolvedServerAddresses: const {
        'vpn.example.org': ['203.0.113.10'],
      },
      systemDNSServers: const ['192.168.31.5'],
      networkResolvers: const ['192.168.31.1'],
    );
    expect(result.plan.autoReconnect, isFalse);
    expect(result.plan.overrideSystemDNS, isFalse);
    expect(result.plan.singBox.config, contains('203.0.113.10/32'));
    expect(result.plan.singBox.config, contains('192.168.31.1'));
  });
}

Store _twoTunnelStore() => Fixtures.store(
  rules: [
    Rule.tunnel(pattern: 'example.com', tunnelID: Fixtures.workID),
    Rule.tunnel(
      pattern: 'api.other.com',
      match: RuleMatch.exact,
      tunnelID: Fixtures.workID,
    ),
    Rule.tunnel(
      pattern: '*.cdn.example.com',
      match: RuleMatch.wildcard,
      tunnelID: Fixtures.homeID,
    ),
    Rule.tunnel(
      pattern: 'disabled.example',
      tunnelID: Fixtures.homeID,
      isEnabled: false,
    ),
  ],
);
