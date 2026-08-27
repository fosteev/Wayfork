import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';

import 'fixtures.dart';

void main() {
  test('store round-trips through JSON', () {
    final rules = [
      Rule.tunnel(pattern: 'example.com', tunnelID: Fixtures.workID),
      Rule.tunnel(
        pattern: '*.cdn.example.net',
        match: RuleMatch.wildcard,
        tunnelID: Fixtures.homeID,
        note: 'cdn',
      ),
    ];
    final store = Fixtures.store(rules: rules);
    final text = StoreCodec.encode(store);
    expect(StoreCodec.decode(text), store);
    expect(text, contains('"openVPN" : {'));
    expect(text, contains('"vless" : {'));
    expect(text, isNot(contains('"_0"')));
    expect(text, contains('"createdAt" : "2026-08-25T12:00:00Z"'));
    expect(text.endsWith('\n'), isFalse);
  });

  test('store refuses a newer schema', () {
    expect(
      () => StoreCodec.decode('{"schemaVersion":99,"tunnels":[],"rules":[]}'),
      throwsA(const StoreCodecException.newerSchema(found: 99, supported: 2)),
    );
  });

  test('settings decode missing keys', () {
    final store = StoreCodec.decode(
      '{"schemaVersion":1,"tunnels":[],"rules":[],"settings":{"logLevel":"debug"}}',
    );
    expect(store.settings.logLevel, LogLevel.debug);
    expect(store.settings.autoReconnect, isTrue);
    expect(store.settings.directDNS, const DirectDNSSystem());
  });

  test('slots, Windows interface names and outbound tags', () {
    final store = Fixtures.store();
    expect(store.nextFreeSlot(), 2);
    expect(Fixtures.work.interfaceName, 'Wayfork-1');
    expect(Fixtures.home.interfaceName, isNull);
    expect(Fixtures.work.outboundTag, 't-00000000-0000-4000-8000-000000000001');
    expect(
      Fixtures.work.ruleSetFileName,
      'rules-t-00000000-0000-4000-8000-000000000001.json',
    );
    expect(Tunnel.tunnelID(Fixtures.work.outboundTag), Fixtures.workID);
    final full = Store(
      tunnels: [
        for (var slot = 0; slot < Tunnel.maxSlots; slot++)
          Tunnel(
            name: 't$slot',
            slot: slot,
            kind: TunnelKindVLESS(
              VLESSMeta(
                server: 'example.com',
                port: 1,
                security: VLESSSecurity.none,
              ),
            ),
          ),
      ],
    );
    expect(full.nextFreeSlot(), isNull);
  });

  test('effective rules follow tunnel order and put exceptions first', () {
    final exception = Rule(pattern: 'x.com', target: const RuleTargetDirect());
    final home = Rule.tunnel(pattern: 'a.com', tunnelID: Fixtures.homeID);
    final work = Rule.tunnel(pattern: 'b.com', tunnelID: Fixtures.workID);
    final orphan = Rule.tunnel(
      pattern: 'c.com',
      tunnelID: '00000000-0000-4000-8000-000000000099',
    );
    final store = Fixtures.store(rules: [orphan, home, work, exception]);
    expect(store.effectiveRules.map((rule) => rule.pattern), [
      'x.com',
      'b.com',
      'a.com',
      'c.com',
    ]);
    expect(store.exceptions, [exception]);
  });

  test('export document round-trips and validates format', () {
    final store = Fixtures.store(
      rules: [Rule.tunnel(pattern: 'example.com', tunnelID: Fixtures.workID)],
    );
    final document = ExportDocument(
      exportedAt: Fixtures.date,
      includesSecrets: false,
      tunnels: store.tunnels.map(ExportedTunnel.fromTunnel).toList(),
      rules: store.rules,
      settings: store.settings,
    );
    final text = document.encode();
    expect(text, contains('"format" : "wayfork-export"'));
    expect(text, isNot(contains('"slot"')));
    expect(ExportDocument.decode(text), document);
    expect(
      () => ExportDocument.decode(
        '{"format":"other","version":1,"exportedAt":"2026-08-25T12:00:00Z","includesSecrets":false,"tunnels":[],"rules":[],"settings":{}}',
      ),
      throwsA(const ExportDocumentException.unknownFormat('other')),
    );
  });

  test('example export file decodes', () {
    final document = ExportDocument.decode(
      File('../../examples/export.example.json').readAsStringSync(),
    );
    expect(document.tunnels, hasLength(2));
    expect(document.tunnels[0].kind.isOpenVPN, isTrue);
    expect(document.tunnels[1].kind.vless?.security, VLESSSecurity.reality);
    expect(document.rules, hasLength(3));
    expect(document.rules[2].isException, isTrue);
    expect(document.defaultTunnelID, document.tunnels[1].id);
  });

  test('log level ordering and mappings', () {
    expect(LogLevel.error < LogLevel.debug, isTrue);
    expect(LogLevel.warning < LogLevel.info, isTrue);
    expect(LogLevel.info.openVPNVerbosity, 3);
    expect(LogLevel.debug.openVPNVerbosity, 4);
    expect(LogLevel.error.openVPNVerbosity, 1);
    expect(LogLevel.warning.singBoxLevel, 'warn');
  });

  test('rule JSON remains backward compatible', () {
    final legacy =
        JsonCoding.decode(
              '{"id":"00000000-0000-4000-8000-000000000101","pattern":"example.com","match":"suffix","tunnelID":"${Fixtures.workID}","isEnabled":true,"note":null}',
            )!
            as Map<String, Object?>;
    final rule = Rule.fromJson(legacy);
    expect(rule.target, RuleTargetTunnel(Fixtures.workID));
    expect(rule.isException, isFalse);

    final exception = Rule(
      pattern: 'bank.example.org',
      target: const RuleTargetDirect(),
      note: 'keep local',
    );
    final exceptionJson = JsonCoding.encodePretty(exception.toJson());
    expect(exceptionJson, contains('"target" : "direct"'));
    expect(exceptionJson, isNot(contains('tunnelID')));
    expect(
      Rule.fromJson(JsonCoding.decode(exceptionJson)! as Map<String, Object?>),
      exception,
    );
    final tunnelJson = JsonCoding.encodePretty(
      Rule.tunnel(pattern: 'a.com', tunnelID: Fixtures.workID).toJson(),
    );
    expect(tunnelJson, isNot(contains('"target"')));
    expect(
      () => Rule.fromJson({
        'id': '00000000-0000-4000-8000-000000000101',
        'pattern': 'a.com',
        'match': 'suffix',
        'isEnabled': true,
      }),
      throwsFormatException,
    );
    expect(
      () => Rule.fromJson({
        'id': '00000000-0000-4000-8000-000000000101',
        'pattern': 'a.com',
        'match': 'suffix',
        'target': 'reject',
        'isEnabled': true,
      }),
      throwsFormatException,
    );
  });

  test('default tunnel round-trips and defaults to null', () {
    final base = Fixtures.store(
      rules: [
        Rule(pattern: 'bank.example.org', target: const RuleTargetDirect()),
      ],
    );
    expect(StoreCodec.decode(StoreCodec.encode(base)).defaultTunnelID, isNull);
    final legacy = StoreCodec.decode(
      '{"schemaVersion":1,"tunnels":[],"rules":[],"settings":{}}',
    );
    expect(legacy.defaultTunnelID, isNull);
    final store = base.copyWith(defaultTunnelID: Fixtures.workID);
    final decoded = StoreCodec.decode(StoreCodec.encode(store));
    expect(decoded, store);
    expect(decoded.effectiveDefaultTunnel?.id, Fixtures.workID);
    expect(
      store
          .copyWith(
            tunnels: [Fixtures.work.copyWith(isEnabled: false), Fixtures.home],
          )
          .effectiveDefaultTunnel,
      isNull,
    );
  });

  test('schema one migrates to two and app rules survive', () {
    final migrated = StoreCodec.decode(
      '{"schemaVersion":1,"tunnels":[],"rules":[],"settings":{}}',
    );
    expect(migrated.schemaVersion, 2);
    final store = Fixtures.store(
      rules: [
        Rule.tunnel(
          pattern: r'C:\Program Files\Telegram\Telegram.exe',
          match: RuleMatch.app,
          tunnelID: Fixtures.workID,
        ),
      ],
    );
    final text = StoreCodec.encode(store);
    expect(text, contains('"schemaVersion" : 2'));
    expect(text, contains('"match" : "app"'));
    expect(StoreCodec.decode(text), store);
  });

  test('two-tunnels input model re-encodes byte for byte', () {
    final source = Fixtures.text('singbox/two-tunnels/input.json');
    final document = JsonCoding.decode(source)! as Map<String, Object?>;
    final store = Store.fromJson(document['store']! as Map<String, Object?>);
    final rendered =
        '${JsonText.render({...document, 'store': store.toJson()})}\n';
    expect(rendered, source);
  });
}
