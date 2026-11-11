import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:characters/characters.dart';
import 'package:wayfork/core/app/import_export.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/rule_list.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/plan/runtime_plan_builder.dart';
import 'package:wayfork/core/rules/rule_validator.dart';
import 'package:wayfork/core/singbox/sing_box_config_generator.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';

import 'fixtures.dart';
import 'singbox/frozen_f23_generator.dart';

const listA = '00000000-0000-4000-8000-000000000201';
const listB = '00000000-0000-4000-8000-000000000202';
const listC = '00000000-0000-4000-8000-000000000203';
String rowID(int n) =>
    '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';
SingBoxOutput generate(Store store) => SingBoxConfigGenerator.generate(
  SingBoxInput(
    store: store,
    vlessUUIDs: {Fixtures.homeID: 'fixture'},
    openVPNBinaryPath: '/x/openvpn',
    platform: WayforkPlatform.macOS,
  ),
);

bool matches(
  Map<String, Object?> matcher, {
  String host = '',
  String process = '',
  String ip = '',
  String network = 'tcp',
  String query = 'A',
}) {
  bool values(String key, bool Function(String) test) {
    final value = matcher[key];
    final items = value is String
        ? [value]
        : (value as List<Object?>? ?? []).cast<String>();
    return items.any(test);
  }

  if (matcher.containsKey('query_type') &&
      !values('query_type', (value) => value == query)) {
    return false;
  }
  if (matcher.containsKey('network') &&
      !values('network', (value) => value == network)) {
    return false;
  }
  if (matcher.containsKey('domain')) {
    if (!values('domain', (value) => value == host) &&
        !values('domain_suffix', (value) => host.endsWith(value)) &&
        !values('domain_regex', (value) => RegExp(value).hasMatch(host))) {
      return false;
    }
  } else if (matcher.containsKey('domain_suffix') &&
      !values('domain_suffix', host.endsWith)) {
    return false;
  } else if (matcher.containsKey('domain_regex') &&
      !values('domain_regex', (value) => RegExp(value).hasMatch(host))) {
    return false;
  }
  if (matcher.containsKey('process_path_regex') &&
      !values(
        'process_path_regex',
        (value) => RegExp(value).hasMatch(process),
      )) {
    return false;
  }
  if (matcher.containsKey('ip_cidr') &&
      !values('ip_cidr', (value) {
        final range = IPv4Prefix.parse(value);
        final address = IPv4Prefix.parse(ip);
        return range != null && address != null && range.contains(address);
      })) {
    return false;
  }
  return true;
}

String select(
  SingBoxOutput output, {
  bool dns = false,
  String host = '',
  String process = '',
  String ip = '',
  String network = 'tcp',
  String query = 'A',
}) {
  final root = jsonDecode(output.config) as Map<String, Object?>;
  final section = root[dns ? 'dns' : 'route'] as Map<String, Object?>;
  final route = root['route'] as Map<String, Object?>;
  final references = (route['rule_set'] as List<Object?>)
      .cast<Map<String, Object?>>();
  final byTag = {
    for (final ref in references)
      if (output.ruleSets[ref['path']] case final String text)
        ref['tag']:
            (jsonDecode(text) as Map<String, Object?>)['rules']
                as List<Object?>,
  };
  for (final object in section['rules'] as List<Object?>) {
    final rule = object as Map<String, Object?>;
    final target = rule[dns ? 'server' : 'outbound'];
    if (target is! String || !rule.containsKey('rule_set')) continue;
    if (!matches(
      rule,
      host: host,
      process: process,
      ip: ip,
      network: network,
      query: query,
    )) {
      continue;
    }
    final raw = rule['rule_set'];
    final tags = raw is String ? [raw] : raw as List<Object?>;
    if (tags.any(
      (tag) => (byTag[tag] ?? []).any(
        (item) => matches(
          item as Map<String, Object?>,
          host: host,
          process: process,
          ip: ip,
          network: network,
          query: query,
        ),
      ),
    )) {
      return target;
    }
  }
  // Default DNS A/AAAA catch-all is intentionally distinct from dns.final.
  if (dns &&
      (query == 'A' || query == 'AAAA') &&
      (section['rules'] as List<Object?>).cast<Map<String, Object?>>().any(
        (rule) => !rule.containsKey('rule_set') && rule['server'] == 'fakeip',
      )) {
    return 'fakeip';
  }
  return section['final'] as String;
}

void main() {
  test(
    'legacy migration JSON and generated route/DNS outcomes match Swift and frozen F23',
    () {
      final directories = Directory(
        '${Fixtures.root.path}/legacy-f23/singbox',
      ).listSync().whereType<Directory>();
      for (final directory in directories) {
        final name = directory.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        final raw =
            jsonDecode(File('${directory.path}/input.json').readAsStringSync())
                as Map<String, Object?>;
        final source = raw['store'] as Map<String, Object?>;
        final migrated = StoreCodec.decode(jsonEncode(source));
        final expected =
            (jsonDecode(Fixtures.text('singbox/$name/input.json'))
                as Map<String, Object?>)['store'];
        expect(
          migrated.toJson(),
          expected,
          reason:
              '$name migration must match Swift list IDs, names, row order and archive flags',
        );
        expect(StoreCodec.decode(jsonEncode(source)), migrated);
        final oldInput = SingBoxInput.fromJson(
          raw,
          platform: WayforkPlatform.macOS,
        );
        final before = FrozenF23Generator.generate(oldInput);
        expect(
          before.config,
          File('${directory.path}/sing-box.json').readAsStringSync(),
          reason: '$name frozen F23 config drift',
        );
        final frozenFiles = {
          for (final file in directory.listSync().whereType<File>())
            if (file.uri.pathSegments.last.startsWith('rules-'))
              file.uri.pathSegments.last: file.readAsStringSync(),
        };
        expect(
          before.ruleSets,
          frozenFiles,
          reason: '$name frozen F23 rule-set drift',
        );
        final after = SingBoxConfigGenerator.generate(
          SingBoxInput.fromJson({
            ...raw,
            'store': migrated.toJson(),
          }, platform: WayforkPlatform.macOS),
        );
        for (final host in [
          'example.com',
          'api.other.com',
          'a.cdn.example.com',
          'bank.example.org',
          'vpn.example.org',
          'unknown.invalid',
          'localhost',
        ]) {
          expect(
            select(after, host: host),
            select(before, host: host),
            reason: '$name route $host',
          );
          for (final query in ['A', 'AAAA', 'TXT']) {
            expect(
              select(after, dns: true, host: host, query: query),
              select(before, dns: true, host: host, query: query),
              reason: '$name DNS $host $query',
            );
          }
        }
      }
    },
  );

  test(
    'ordered lists, pins, follow-default, pause and unavailable fallback use actual generated rules',
    () {
      var store = Store(
        tunnels: [Fixtures.work, Fixtures.home],
        lists: [
          RuleList(
            id: listA,
            name: 'First',
            target: RuleListExit(RuleTargetTunnel(Fixtures.workID)),
          ),
          RuleList(
            id: listB,
            name: 'Second',
            target: RuleListExit(RuleTargetTunnel(Fixtures.homeID)),
          ),
          RuleList(
            id: listC,
            name: 'Third',
            target: RuleListExit(RuleTargetTunnel(Fixtures.workID)),
          ),
        ],
        rules: [
          Rule(id: rowID(1), pattern: 'example.com', listID: listA),
          Rule(
            id: rowID(2),
            pattern: 'api.example.com',
            match: RuleMatch.exact,
            listID: listB,
          ),
          Rule(
            id: rowID(3),
            pattern: 'deep.api.example.com',
            match: RuleMatch.exact,
            listID: listC,
          ),
          Rule(
            id: rowID(4),
            pattern: '/Applications/Chat.app',
            match: RuleMatch.app,
            listID: listA,
          ),
          Rule(
            id: rowID(5),
            pattern: '/Applications/Chat.app',
            match: RuleMatch.app,
            network: RuleNetwork.udp,
            listID: listB,
          ),
        ],
      );
      expect(
        select(generate(store), host: 'api.example.com'),
        Fixtures.work.outboundTag,
      );
      expect(
        select(generate(store.reorderList(listB, 0)), host: 'api.example.com'),
        Fixtures.home.outboundTag,
      );
      expect(
        select(
          generate(store),
          process: '/Applications/Chat.app/main',
          network: 'udp',
        ),
        Fixtures.work.outboundTag,
      );
      expect(
        select(
          generate(store.pinRule(rowID(5), const RuleTargetDirect())),
          process: '/Applications/Chat.app/main',
          network: 'udp',
        ),
        'direct',
      );
      store = store.updateList(
        listA,
        (list) => list.copyWith(target: const RuleListEverythingElse()),
      );
      expect(select(generate(store), host: 'api.example.com'), 'direct');
      expect(
        select(
          generate(store),
          dns: true,
          host: 'api.example.com',
          query: 'TXT',
        ),
        'dns-direct',
      );
      expect(
        select(
          generate(store.copyWith(defaultTunnelID: Fixtures.workID)),
          host: 'api.example.com',
        ),
        Fixtures.work.outboundTag,
      );
      expect(
        select(
          generate(
            store.updateList(listA, (list) => list.copyWith(isEnabled: false)),
          ),
          host: 'api.example.com',
        ),
        Fixtures.home.outboundTag,
      );
      expect(
        select(
          generate(store.copyWith(tunnels: [Fixtures.home])),
          host: 'api.example.com',
        ),
        'direct',
      );
      final available = RuleValidator.resolvedRules(
        store,
        routedExitIDs: {Fixtures.homeID},
      );
      expect(available.first.target, const RuleTargetDirect());
      final pinnedPaused = store
          .pinRule(rowID(1), const RuleTargetDirect())
          .updateList(listA, (list) => list.copyWith(isEnabled: false));
      expect(
        select(generate(pinnedPaused), host: 'api.example.com'),
        Fixtures.home.outboundTag,
      );
    },
  );

  test(
    'G1 splits transports, archives only duplicates and retains missing-secret fallback',
    () {
      final rows = [
        Rule(
          id: rowID(10),
          pattern: '/Applications/Chat.app',
          match: RuleMatch.app,
          target: RuleTargetTunnel(Fixtures.workID),
        ),
        Rule(
          id: rowID(11),
          pattern: '/Applications/Chat.app',
          match: RuleMatch.app,
          network: RuleNetwork.udp,
          target: RuleTargetTunnel(Fixtures.homeID),
        ),
        Rule(
          id: rowID(12),
          pattern: 'duplicate.example',
          target: RuleTargetTunnel(Fixtures.workID),
          isEnabled: false,
        ),
        Rule(
          id: rowID(13),
          pattern: 'duplicate.example',
          target: RuleTargetTunnel(Fixtures.workID),
          note: 'preserved',
        ),
        Rule(
          id: rowID(14),
          pattern: 'fallback.example',
          target: RuleTargetTunnel(Fixtures.workID),
        ),
        Rule(
          id: rowID(15),
          pattern: 'fallback.example',
          target: RuleTargetTunnel(Fixtures.homeID),
        ),
      ];
      final source = Store(
        tunnels: [Fixtures.work, Fixtures.home],
        rules: rows,
        lists: [],
      );
      final raw = source.toJson()
        ..['schemaVersion'] = 3
        ..remove('lists');
      final migrated = StoreCodec.decode(jsonEncode(raw));
      expect(migrated.lists.map((list) => list.id), [
        rowID(11),
        rowID(10),
        rowID(15),
        rowID(13),
      ]);
      expect(migrated.lists.map((list) => list.name), [
        'Home — TCP/UDP',
        'Work',
        'Home',
        'Work — Previously inactive',
      ]);
      expect(
        migrated.rules.singleWhere((row) => row.id == rowID(13)).isEnabled,
        isTrue,
      );
      expect(migrated.lists.last.isEnabled, isFalse);
      expect(migrated.lists.last.showInMenu, isFalse);
      expect(
        select(
          generate(migrated),
          process: '/Applications/Chat.app/main',
          network: 'udp',
        ),
        Fixtures.home.outboundTag,
      );
      expect(
        select(
          generate(migrated),
          process: '/Applications/Chat.app/main',
          network: 'tcp',
        ),
        Fixtures.work.outboundTag,
      );
      expect(select(generate(migrated), host: 'duplicate.example'), 'direct');
      expect(
        select(
          generate(
            migrated.updateList(
              migrated.lists.last.id,
              (list) => list.copyWith(isEnabled: true),
            ),
          ),
          host: 'duplicate.example',
        ),
        Fixtures.work.outboundTag,
      );
      final built = RuntimePlanBuilder.build(
        store: migrated,
        secrets: PlanSecrets(vlessUUIDs: {Fixtures.homeID: 'fixture'}),
        installDir: '/x',
        platform: WayforkPlatform.macOS,
      );
      final output = SingBoxOutput(
        config: built.plan.singBox.config,
        ruleSets: built.plan.singBox.ruleSets,
        routedTunnels: built.routedTunnels,
        defaultTunnel: null,
      );
      expect(
        select(output, host: 'fallback.example'),
        Fixtures.home.outboundTag,
      );
      for (final version in [1, 2, 3]) {
        final doc = ExportDocument.decode(
          jsonEncode({
            'format': 'wayfork-export',
            'version': version,
            'exportedAt': '2026-08-25T12:00:00Z',
            'includesSecrets': false,
            'tunnels': source.tunnels
                .map((tunnel) => ExportedTunnel.fromTunnel(tunnel).toJson())
                .toList(),
            'rules': rows.map((row) => row.toJson()).toList(),
            'settings': {},
          }),
        );
        expect(doc.lists, migrated.lists);
        expect(doc.rules, migrated.rules);
      }
    },
  );

  test(
    'opposite migration counterexample keeps a narrowed Work row ahead of broad Home',
    () {
      final migrated = Store(
        tunnels: [Fixtures.work, Fixtures.home],
        rules: [
          Rule(
            id: rowID(20),
            pattern: '/Applications/Other.app',
            match: RuleMatch.app,
            target: RuleTargetTunnel(Fixtures.homeID),
          ),
          Rule(
            id: rowID(21),
            pattern: '/Applications/Other.app',
            match: RuleMatch.app,
            target: RuleTargetTunnel(Fixtures.workID),
            network: RuleNetwork.tcp,
          ),
        ],
      );
      expect(migrated.lists.map((list) => list.id), [rowID(21), rowID(20)]);
      final output = generate(migrated);
      expect(
        select(output, process: '/Applications/Other.app/main', network: 'tcp'),
        Fixtures.work.outboundTag,
      );
      expect(
        select(output, process: '/Applications/Other.app/main', network: 'udp'),
        Fixtures.home.outboundTag,
      );
    },
  );

  test(
    'projection filters inactive rows before duplicate and full-network shadowing',
    () {
      final store = Store(
        tunnels: [Fixtures.work, Fixtures.home],
        lists: [
          RuleList(
            id: listA,
            name: 'Work',
            target: RuleListExit(RuleTargetTunnel(Fixtures.workID)),
          ),
          RuleList(
            id: listB,
            name: 'Home',
            target: RuleListExit(RuleTargetTunnel(Fixtures.homeID)),
          ),
        ],
        rules: [
          Rule(
            id: rowID(30),
            pattern: '/Applications/Chat.app',
            match: RuleMatch.app,
            listID: listA,
            isEnabled: false,
          ),
          Rule(
            id: rowID(31),
            pattern: '/Applications/Chat.app',
            match: RuleMatch.app,
            listID: listA,
            network: RuleNetwork.tcp,
          ),
          Rule(
            id: rowID(32),
            pattern: '/Applications/Chat.app',
            match: RuleMatch.app,
            listID: listB,
          ),
          Rule(
            id: rowID(33),
            pattern: '/Applications/Chat.app',
            match: RuleMatch.app,
            listID: listB,
          ),
        ],
      );
      final issues = RuleValidator.validate(store);
      expect(issues[rowID(31)], isNull);
      expect(
        issues[rowID(32)],
        isNull,
        reason: 'partial TCP overlap must retain the broad UDP fallback',
      );
      expect(issues[rowID(33)], [RuleIssue.duplicate(rowID(32))]);
      expect(
        select(
          generate(store),
          process: '/Applications/Chat.app/main',
          network: 'tcp',
        ),
        Fixtures.work.outboundTag,
      );
      expect(
        select(
          generate(store),
          process: '/Applications/Chat.app/main',
          network: 'udp',
        ),
        Fixtures.home.outboundTag,
      );
      final unavailable = store.copyWith(tunnels: [Fixtures.home]);
      expect(
        RuleValidator.resolvedRules(unavailable).single.rule.id,
        rowID(32),
      );
      final explicitPin = unavailable.pinRule(
        rowID(31),
        const RuleTargetDirect(),
      );
      expect(
        select(
          generate(explicitPin),
          process: '/Applications/Chat.app/main',
          network: 'tcp',
        ),
        'direct',
      );
      expect(
        select(
          generate(
            explicitPin.updateList(
              listA,
              (list) => list.copyWith(isEnabled: false),
            ),
          ),
          process: '/Applications/Chat.app/main',
        ),
        Fixtures.home.outboundTag,
      );
    },
  );

  test(
    'schema4 bindings and membership reject malformed or ambiguous inputs',
    () {
      final source = Store(
        lists: [
          RuleList(
            id: listA,
            name: 'Sites',
            target: const RuleListEverythingElse(),
          ),
        ],
        rules: [Rule(id: rowID(40), pattern: 'example.com', listID: listA)],
      );
      final json = source.toJson();
      final row =
          (json['rules'] as List<Object?>).single as Map<String, Object?>;
      row['target'] = 'direct';
      row['tunnelID'] = Fixtures.workID;
      expect(
        () => StoreCodec.decode(jsonEncode(json)),
        throwsA(isA<StoreCodecException>()),
      );
      row.remove('tunnelID');
      row['target'] = 'everythingElse';
      expect(
        () => StoreCodec.decode(jsonEncode(json)),
        throwsA(isA<StoreCodecException>()),
      );
      final future = {'version': 5};
      expect(
        () => ExportDocument.fromJson(future),
        throwsA(const ExportDocumentException.newerVersion(5)),
      );
      expect(
        () => source.createList(
          source.lists.single.copyWith(id: listB, name: 'sites'),
        ),
        throwsFormatException,
      );
      expect(
        () => source
            .copyWith(rules: [source.rules.single, source.rules.single])
            .validateMembership(),
        throwsFormatException,
      );
    },
  );

  test(
    'list transactions validate membership and preserve pins, order and unicode names',
    () {
      final unicode = List.filled(41, '👨‍👩‍👧‍👦é').join();
      var store = Store(
        lists: [
          RuleList(
            id: listA,
            name: 'First',
            target: const RuleListEverythingElse(),
          ),
          RuleList(
            id: listB,
            name: 'Second',
            target: const RuleListExit(RuleTargetDirect()),
          ),
        ],
        rules: [
          Rule(
            id: rowID(1),
            pattern: 'x.example',
            listID: listA,
            target: RuleTargetTunnel(Fixtures.workID),
          ),
        ],
      );
      expect(store.availableListName(unicode).characters.length, 40);
      expect(
        () => store.createList(
          RuleList(name: unicode, target: const RuleListEverythingElse()),
        ),
        throwsFormatException,
      );
      store = store.moveRule(rowID(1), listB);
      expect(store.rules.single.target, RuleTargetTunnel(Fixtures.workID));
      expect(
        store
            .pinRule(rowID(1), null)
            .targetFor(store.rules.single.copyWith(target: null)),
        const RuleTargetDirect(),
      );
      expect(
        () => StoreCodec.encode(store.copyWith(lists: [])),
        throwsFormatException,
      );
      final deleted = store.removeRulesBoundTo(
        RuleTargetTunnel(Fixtures.workID),
      );
      expect(deleted.rules, isEmpty);
      expect(deleted.lists, hasLength(2));
    },
  );

  test(
    'same-name lists remain distinct and repeated merge reuses the imported identity',
    () {
      final local = Store(
        lists: [
          RuleList(
            id: listA,
            name: 'Sites',
            target: const RuleListEverythingElse(),
          ),
        ],
      );
      final source = RuleList(
        id: listB,
        name: 'Sites',
        target: const RuleListExit(RuleTargetDirect()),
      );
      final doc = ExportDocument(
        exportedAt: Fixtures.date,
        includesSecrets: false,
        tunnels: [],
        rules: [],
        lists: [source],
        settings: local.settings,
      );
      final first = StoreImporter.apply(
        doc,
        to: local,
        mode: ImportMode.merge,
      ).store;
      expect(first.lists.map((list) => list.name), ['Sites', 'Sites (2)']);
      expect(
        StoreImporter.apply(doc, to: first, mode: ImportMode.merge).store,
        first,
      );
      final renamed = first.updateList(
        listB,
        (list) => list.copyWith(name: 'User name'),
      );
      final again = StoreImporter.apply(
        doc,
        to: renamed,
        mode: ImportMode.merge,
      ).store;
      expect(again.lists, hasLength(3));
      expect(again.lists[1].name, 'User name');
      expect(again.lists.last.id, isNot(listB));
    },
  );

  test(
    'export4 merge remaps conflicting identities once and preserves pins and list order',
    () {
      final local = Store(
        lists: [
          RuleList(
            id: listA,
            name: 'Sites',
            target: const RuleListExit(RuleTargetDirect()),
          ),
        ],
        rules: [Rule(id: rowID(1), pattern: 'local.example', listID: listA)],
      );
      final source = Store(
        lists: [
          RuleList(
            id: listA,
            name: 'Sites',
            target: const RuleListEverythingElse(),
          ),
        ],
        rules: [
          Rule(
            id: rowID(1),
            pattern: 'remote.example',
            listID: listA,
            target: const RuleTargetDirect(),
          ),
        ],
      );
      final doc = ExportDocument(
        exportedAt: Fixtures.date,
        includesSecrets: false,
        tunnels: [],
        rules: source.rules,
        lists: source.lists,
        settings: source.settings,
      );
      expect(ExportDocument.decode(doc.encode()), doc);
      final merged = StoreImporter.apply(
        doc,
        to: local,
        mode: ImportMode.merge,
      ).store;
      expect(merged.lists.map((list) => list.name), ['Sites', 'Sites (2)']);
      expect(merged.lists.last.id, isNot(listA));
      expect(merged.rules.last.id, isNot(rowID(1)));
      expect(
        StoreImporter.apply(doc, to: merged, mode: ImportMode.merge).store,
        merged,
      );
      expect(
        StoreImporter.apply(
          doc,
          to: local,
          mode: ImportMode.replace,
        ).store.lists,
        source.lists,
      );
    },
  );
}
