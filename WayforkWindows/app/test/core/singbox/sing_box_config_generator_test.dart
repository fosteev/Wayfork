import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/plan/host_resolver.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/singbox/sing_box_config_generator.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';

import '../fixtures.dart';

const _bundlePath = '/Applications/Wayfork.app';
const _windowsInstallDir = r'C:\Program Files\Wayfork';
const _homeUUID = '00000000-0000-4000-8000-0000000000aa';
const _deep = DeepCollectionEquality();

void main() {
  test('direct resolver names the network resolver instead of asking DHCP', () {
    final explicit = _json(
      _generate(_twoTunnelStore(), network: ['192.168.31.1', '1.1.1.1']).config,
    );
    final servers = _objects((_object(explicit, 'dns'))['servers']);
    final direct = servers.singleWhere(
      (server) => server['tag'] == 'dns-direct',
    );
    expect(direct['type'], 'udp');
    expect(direct['server'], '192.168.31.1');
    expect(direct.containsKey('detour'), isFalse);

    final fallback = _json(_generate(_twoTunnelStore()).config);
    final fallbackServers = _objects(_object(fallback, 'dns')['servers']);
    expect(
      fallbackServers.singleWhere(
        (server) => server['tag'] == 'dns-direct',
      )['type'],
      'local',
    );

    final custom = _twoTunnelStore().copyWith(
      settings: _twoTunnelStore().settings.copyWith(
        directDNS: DirectDNSCustom(['9.9.9.9']),
      ),
    );
    final customConfig = _json(
      _generate(custom, network: ['192.168.31.1']).config,
    );
    final customServers = _objects(_object(customConfig, 'dns')['servers']);
    expect(
      customServers.singleWhere(
        (server) => server['tag'] == 'dns-direct',
      )['server'],
      '9.9.9.9',
    );
  });

  test('system resolvers inside the LAN enter the TUN', () {
    final excluded = _excludedRanges(
      _generate(
        _twoTunnelStore(),
        systemDNS: ['192.168.31.1', '8.8.8.8', 'fe80::1%en0', '192.168.31.1'],
      ),
    );
    final resolver = IPv4Prefix.parse('192.168.31.1')!;
    expect(excluded.any((range) => range.contains(resolver)), isFalse);
    for (final neighbour in [
      '192.168.31.0',
      '192.168.31.2',
      '192.168.30.1',
      '10.0.0.1',
      '172.16.0.1',
    ]) {
      final address = IPv4Prefix.parse(neighbour)!;
      expect(
        excluded.any((range) => range.contains(address)),
        isTrue,
        reason: '$neighbour must stay excluded',
      );
    }
    expect(
      _excludedRanges(_generate(_twoTunnelStore(), systemDNS: ['8.8.8.8'])),
      _excludedRanges(_generate(_twoTunnelStore())),
    );
  });

  test('system resolvers cannot upgrade to encrypted DNS', () {
    final config = _json(
      _generate(
        _twoTunnelStore(),
        systemDNS: ['192.168.31.1', '8.8.8.8'],
      ).config,
    );
    final rules = _objects(_object(config, 'route')['rules']);
    expect(rules[1]['action'], 'hijack-dns');
    expect(rules[2]['ip_cidr'], ['192.168.31.1/32', '8.8.8.8/32']);
    expect(rules[2]['port'], [443, 853]);
    expect(rules[2]['action'], 'reject');
    expect(rules[3].containsKey('process_path'), isTrue);

    final bare = _json(_generate(_twoTunnelStore()).config);
    final bareRules = _objects(_object(bare, 'route')['rules']);
    expect(bareRules.any((rule) => rule.containsKey('port')), isFalse);
  });

  test('generated config follows routing design', () {
    final output = _generate(_twoTunnelStore());
    final config = _json(output.config);
    final work = Fixtures.work;
    final home = Fixtures.home;
    final dns = _object(config, 'dns');
    final servers = _objects(dns['servers']);
    expect(servers.map((server) => server['tag']).toList(), [
      'dns-direct',
      'dns-${work.outboundTag}',
      'fakeip',
    ]);
    expect(servers[0]['type'], 'local');
    expect(servers[1]['server'], '10.8.0.1');
    expect(servers[1]['detour'], work.outboundTag);
    final dnsRules = _objects(dns['rules']);
    expect(dnsRules, hasLength(5));
    expect(dnsRules[0]['domain'], ['probe.wayfork.internal']);
    expect(dnsRules[0]['action'], 'predefined');
    expect(dnsRules[0]['answer'], [
      'probe.wayfork.internal. 0 IN A 172.19.0.2',
    ]);
    expect(dnsRules[1]['domain'], ['_dns.resolver.arpa']);
    expect(dnsRules[1]['action'], 'reject');
    expect(dnsRules[2]['rule_set'], 'rules-direct');
    expect(dnsRules[2]['server'], 'dns-direct');
    expect(dnsRules[3]['domain'], ['vpn.example.org']);
    expect(dnsRules[3]['server'], 'dns-direct');
    expect(dnsRules[4]['rule_set'], [work.ruleSetTag, home.ruleSetTag]);
    expect(dnsRules[4]['server'], 'fakeip');
    expect(dns['final'], 'dns-direct');
    expect(dns['strategy'], 'ipv4_only');

    final inbounds = _objects(config['inbounds']);
    expect(inbounds[0]['interface_name'], 'utun100');
    expect(inbounds[0]['auto_route'], isTrue);

    final outbounds = _objects(config['outbounds']);
    expect(outbounds.map((outbound) => outbound['tag']).toList(), [
      'direct',
      work.outboundTag,
      home.outboundTag,
    ]);
    expect(outbounds[1]['bind_interface'], 'utun101');
    expect(_object(outbounds[1], 'domain_resolver')['strategy'], 'ipv4_only');
    expect(outbounds[2]['type'], 'vless');
    expect(outbounds[2]['uuid'], _homeUUID);
    expect(outbounds[2]['flow'], 'xtls-rprx-vision');
    final tls = _object(outbounds[2], 'tls');
    expect(tls['server_name'], 'www.apple.com');
    expect(
      _object(tls, 'reality')['public_key'],
      Fixtures.home.kind.vless!.realityPublicKey,
    );
    expect(_object(tls, 'utls')['fingerprint'], 'chrome');
    expect(outbounds[2].containsKey('transport'), isFalse);

    final route = _object(config, 'route');
    final rules = _objects(route['rules']);
    expect(rules[0]['action'], 'sniff');
    expect(rules[1]['action'], 'hijack-dns');
    expect(rules[2]['process_path'], [
      '/Applications/Wayfork.app/Contents/Resources/bin/openvpn',
    ]);
    expect(rules[3]['domain'], ['vpn.example.org']);
    expect(rules[3]['outbound'], 'direct');
    expect(rules[4]['rule_set'], ['rules-direct', 'rules-direct-ip']);
    expect(rules[4]['outbound'], 'direct');
    expect(rules[5]['rule_set'], [work.ruleSetTag, work.ipRuleSetTag]);
    expect(rules[6]['rule_set'], [home.ruleSetTag, home.ipRuleSetTag]);
    expect(rules[7]['ip_is_private'], isTrue);
    expect(route['final'], 'direct');
    expect(route['default_domain_resolver'], 'dns-direct');
    expect(_objects(route['rule_set']).map((rule) => rule['path']).toList(), [
      'rules-direct.json',
      'rules-direct-ip.json',
      work.ruleSetFileName,
      work.ipRuleSetFileName,
      home.ruleSetFileName,
      home.ipRuleSetFileName,
    ]);
    expect(output.defaultTunnel, isNull);

    expect(
      output.ruleSets.keys.toList()..sort(),
      [
        'rules-direct.json',
        'rules-direct-ip.json',
        home.ruleSetFileName,
        home.ipRuleSetFileName,
        work.ruleSetFileName,
        work.ipRuleSetFileName,
      ]..sort(),
    );
    final directRule = _objects(
      _json(output.ruleSets['rules-direct.json']!)['rules'],
    ).first;
    expect(directRule['domain'], ['localhost']);
    expect(directRule['domain_suffix'], [
      '.local',
      '.lan',
      '.internal',
      '.home.arpa',
      '.localhost',
    ]);
    final workRule = _objects(
      _json(output.ruleSets[work.ruleSetFileName]!)['rules'],
    ).first;
    expect(workRule['domain'], ['example.com', 'api.other.com']);
    expect(workRule['domain_suffix'], ['.example.com']);
    final homeRule = _objects(
      _json(output.ruleSets[home.ruleSetFileName]!)['rules'],
    ).first;
    expect(homeRule['domain_regex'], [r'^.+\.cdn\.example\.com$']);
    expect(homeRule.containsKey('domain'), isFalse);
  });

  test('generator honors DNS settings and skips unusable tunnels', () {
    final original = _twoTunnelStore();
    final workMeta = original.tunnels[0].kind.openVPN!;
    final customWork = original.tunnels[0].copyWith(
      kind: TunnelKindOpenVPN(
        OpenVPNMeta(
          remotes: workMeta.remotes,
          needsCredentials: workMeta.needsCredentials,
          needsKeyPassphrase: workMeta.needsKeyPassphrase,
          dns: TunnelDNSCustom(['10.1.1.1']),
          discoveredDNS: workMeta.discoveredDNS,
          configHash: workMeta.configHash,
        ),
      ),
    );
    final store = original.copyWith(
      tunnels: [customWork, original.tunnels[1]],
      settings: original.settings.copyWith(
        directDNS: DirectDNSCustom(['9.9.9.9', '1.1.1.1']),
        logLevel: LogLevel.debug,
      ),
    );
    final output = _generate(store, uuids: const {});
    final config = _json(output.config);
    final servers = _objects(_object(config, 'dns')['servers']);
    expect(servers[0]['type'], 'udp');
    expect(servers[0]['server'], '9.9.9.9');
    expect(servers[0].containsKey('detour'), isFalse);
    expect(servers[1]['server'], '10.1.1.1');
    expect(_object(config, 'log')['level'], 'debug');
    expect(output.routedTunnels.map((tunnel) => tunnel.id), [Fixtures.workID]);
    expect(output.ruleSets, hasLength(4));

    final bare = _generate(store.copyWith(tunnels: []), uuids: const {});
    final bareConfig = _json(bare.config);
    expect(_objects(_object(bareConfig, 'dns')['rules']), hasLength(3));
    expect(_objects(_object(bareConfig, 'route')['rule_set']), hasLength(2));
    expect(bare.ruleSets.keys.toList()..sort(), [
      'rules-direct-ip.json',
      'rules-direct.json',
    ]);
  });

  test('OpenVPN default tunnel routes everything else', () {
    final output = _generate(_defaultTunnelStore(Fixtures.workID));
    final config = _json(output.config);
    final work = Fixtures.work;
    expect(output.defaultTunnel?.id, work.id);
    expect(_object(config, 'route')['final'], work.outboundTag);
    final dns = _object(config, 'dns');
    expect(dns['final'], 'dns-${work.outboundTag}');
    final dnsRules = _objects(dns['rules']);
    expect(dnsRules, hasLength(6));
    expect(dnsRules[5]['query_type'], ['A', 'AAAA']);
    expect(dnsRules[5]['server'], 'fakeip');
    expect(dnsRules[5].containsKey('rule_set'), isFalse);
    expect(_objects(dns['servers']).map((server) => server['tag']).toList(), [
      'dns-direct',
      'dns-${work.outboundTag}',
      'fakeip',
    ]);
    final directRule = _objects(
      _json(output.ruleSets['rules-direct.json']!)['rules'],
    ).first;
    expect(directRule['domain'], [
      'localhost',
      'bank.example.org',
      'example.com',
    ]);
    expect(directRule['domain_regex'], [r'^.+\.intranet\.example$']);
    final workRule = _objects(
      _json(output.ruleSets[work.ruleSetFileName]!)['rules'],
    ).first;
    expect(workRule['domain'], ['api.other.com']);
  });

  test('VLESS default tunnel gets a DoT resolver', () {
    final output = _generate(_defaultTunnelStore(Fixtures.homeID));
    final config = _json(output.config);
    final home = Fixtures.home;
    expect(_object(config, 'route')['final'], home.outboundTag);
    final dns = _object(config, 'dns');
    expect(dns['final'], 'dns-${home.outboundTag}');
    final dot = _objects(
      dns['servers'],
    ).singleWhere((server) => server['tag'] == 'dns-${home.outboundTag}');
    expect(dot['type'], 'tls');
    expect(dot['server'], '1.1.1.1');
    expect(dot['detour'], home.outboundTag);
  });

  test('unusable default tunnel falls back to Direct', () {
    final disabledStore = _defaultTunnelStore(Fixtures.workID);
    final disabled = disabledStore.copyWith(
      tunnels: [
        disabledStore.tunnels[0].copyWith(isEnabled: false),
        disabledStore.tunnels[1],
      ],
    );
    final output = _generate(disabled);
    expect(output.defaultTunnel, isNull);
    final config = _json(output.config);
    expect(_object(config, 'route')['final'], 'direct');
    expect(_object(config, 'dns')['final'], 'dns-direct');
    expect(_objects(_object(config, 'dns')['rules']), hasLength(4));

    final noSecret = _generate(
      _defaultTunnelStore(Fixtures.homeID),
      uuids: const {},
    );
    expect(noSecret.defaultTunnel, isNull);
    expect(_object(_json(noSecret.config), 'route')['final'], 'direct');

    final unknown = _twoTunnelStore().copyWith(
      defaultTunnelID: '00000000-0000-4000-8000-000000000099',
    );
    expect(_generate(unknown).defaultTunnel, isNull);

    final exceptionsOnly = _twoTunnelStore().copyWith(
      rules: [
        ..._twoTunnelStore().rules,
        Rule(pattern: 'bank.example.org', target: const RuleTargetDirect()),
      ],
    );
    final directRule = _objects(
      _json(_generate(exceptionsOnly).ruleSets['rules-direct.json']!)['rules'],
    ).first;
    expect(directRule['domain'], ['localhost', 'bank.example.org']);
  });

  test('empty rule set is still emitted', () {
    final output = _generate(Fixtures.store());
    final document = _json(output.ruleSets[Fixtures.work.ruleSetFileName]!);
    expect(document['version'], 3);
    expect(document['rules'], isEmpty);
  });

  test('VLESS outbound variants', () {
    final ws = VLESSMeta(
      server: 's',
      port: 443,
      security: VLESSSecurity.tls,
      sni: 'sni',
      alpn: const ['h2', 'http/1.1'],
      transport: const VLESSTransportWS(path: '/x', host: 'h'),
      allowInsecure: true,
    );
    final out = SingBoxConfigGenerator.vlessOutbound(ws, tag: 't', uuid: 'u');
    expect(_object(out, 'transport')['type'], 'ws');
    expect(_object(_object(out, 'transport'), 'headers'), {'Host': 'h'});
    expect(_object(out, 'tls')['alpn'], ['h2', 'http/1.1']);
    expect(_object(out, 'tls')['insecure'], isTrue);
    expect(_object(out, 'tls').containsKey('utls'), isFalse);
    expect(out.containsKey('flow'), isFalse);

    final plain = SingBoxConfigGenerator.vlessOutbound(
      VLESSMeta(
        server: 's',
        port: 80,
        security: VLESSSecurity.none,
        transport: const VLESSTransportGRPC(serviceName: 'svc'),
      ),
      tag: 't',
      uuid: 'u',
    );
    expect(plain.containsKey('tls'), isFalse);
    expect(_object(plain, 'transport')['service_name'], 'svc');
  });

  test('generated config matches golden files byte for byte', () {
    final goldenRoot = Directory('${Fixtures.root.path}/singbox');
    final directories = goldenRoot.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final directory in directories) {
      final name = directory.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      final inputText = File('${directory.path}/input.json').readAsStringSync();
      final input = SingBoxInput.fromJson(
        _json(inputText),
        platform: WayforkPlatform.macOS,
      );
      final output = SingBoxConfigGenerator.generate(input);
      final files = <String, String>{
        'input.json': '${JsonText.render(input.toJson())}\n',
        'sing-box.json': output.config,
        ...output.ruleSets,
      };
      final expectedNames =
          directory
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last)
              .toList()
            ..sort();
      final actualNames = files.keys.toList()..sort();
      expect(actualNames, expectedNames, reason: 'file list for $name');
      for (final entry in files.entries) {
        final expected = File(
          '${directory.path}/${entry.key}',
        ).readAsStringSync();
        expect(
          entry.value,
          expected,
          reason: _firstDifference('$name/${entry.key}', expected, entry.value),
        );
      }
    }
  });

  test('constructed config variants match recorded inputs', () {
    final variants = _configVariants(
      platform: WayforkPlatform.macOS,
      installDir: _bundlePath,
    );
    for (final entry in variants.entries) {
      final expected = _json(Fixtures.text('singbox/${entry.key}/input.json'));
      expect(
        _deep.equals(_goldenInputJson(entry.value), expected),
        isTrue,
        reason: '${entry.key}/input.json differs from constructed input',
      );
    }
  });

  test('sing-box accepts generated Windows configs', () async {
    final binary = Platform.isWindows
        ? File('../../bin/amd64/sing-box.exe').absolute
        : File('../../Wayfork/Resources/bin/sing-box').absolute;
    if (!binary.existsSync()) return;

    final variants = _configVariants(
      platform: WayforkPlatform.windows,
      installDir: _windowsInstallDir,
    );
    for (final entry in variants.entries) {
      final output = SingBoxConfigGenerator.generate(entry.value);
      final directory = await Directory.systemTemp.createTemp(
        'wayfork-singbox-',
      );
      try {
        await File(
          '${directory.path}/sing-box.json',
        ).writeAsString(output.config);
        for (final ruleSet in output.ruleSets.entries) {
          await File(
            '${directory.path}/${ruleSet.key}',
          ).writeAsString(ruleSet.value);
        }
        final process = await Process.run(binary.path, [
          'check',
          '-D',
          directory.path,
          '-c',
          'sing-box.json',
        ]);
        expect(
          process.exitCode,
          0,
          reason:
              'sing-box check failed for ${entry.key}:\n'
              '${process.stdout}${process.stderr}',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    }
  });

  test('IP rules carve their ranges out of TUN exclusions', () {
    final store = Fixtures.store(
      rules: [
        Rule.tunnel(
          pattern: '10.8.0.0/24',
          match: RuleMatch.ip,
          tunnelID: Fixtures.workID,
        ),
        Rule.tunnel(
          pattern: '203.0.113.7',
          match: RuleMatch.ip,
          tunnelID: Fixtures.homeID,
        ),
        Rule(
          pattern: '192.168.50.0/24',
          match: RuleMatch.ip,
          target: const RuleTargetDirect(),
        ),
      ],
    );
    final output = _generate(store);
    final config = _json(output.config);
    final inbound = _objects(config['inbounds']).first;
    final excludes = (inbound['route_exclude_address']! as List<Object?>)
        .cast<String>()
        .map(IPv4Prefix.parse)
        .whereType<IPv4Prefix>()
        .toList();
    final carved = IPv4Prefix.parse('10.8.0.0/24')!;
    expect(excludes.any((range) => range.overlaps(carved)), isFalse);
    expect(
      excludes.any((range) => range.contains(IPv4Prefix.parse('10.9.0.0/16')!)),
      isTrue,
    );
    expect(
      excludes.any(
        (range) => range.contains(IPv4Prefix.parse('192.168.50.0/24')!),
      ),
      isTrue,
    );
    final routeRules = _objects(_object(config, 'route')['rules']);
    expect(routeRules[4]['rule_set'], ['rules-direct', 'rules-direct-ip']);
    expect(routeRules[5]['rule_set'], [
      Fixtures.work.ruleSetTag,
      Fixtures.work.ipRuleSetTag,
    ]);
    final dnsRules = _objects(_object(config, 'dns')['rules']);
    expect(dnsRules[4]['rule_set'], [
      Fixtures.work.ruleSetTag,
      Fixtures.home.ruleSetTag,
    ]);
  });

  test('route exclusion carves out the TUN subnet', () {
    final tun = IPv4Prefix.parse(SingBoxConfigGenerator.tunAddress)!;
    final excludes = SingBoxConfigGenerator.routeExcludeAddresses()
        .map(IPv4Prefix.parse)
        .whereType<IPv4Prefix>()
        .toList();
    expect(excludes.any((range) => range.contains(tun)), isFalse);
    expect(excludes, hasLength(23));
    for (final text in [
      '172.16.0.1/32',
      '172.18.255.255/32',
      '172.19.0.4/32',
      '172.19.1.0/32',
      '172.31.255.255/32',
    ]) {
      final host = IPv4Prefix.parse(text)!;
      expect(
        excludes.any((range) => range.contains(host)),
        isTrue,
        reason: '$text must stay excluded',
      );
    }
  });

  test('IPv4 prefix subtraction', () {
    final outer = IPv4Prefix.parse('10.0.0.0/8')!;
    final inner = IPv4Prefix.parse('10.1.2.3/24')!;
    final parts = outer.subtracting(inner);
    expect(parts, hasLength(16));
    expect(parts.any((part) => part.contains(inner)), isFalse);
    expect(parts.first.toString(), '10.0.0.0/16');
    expect(parts.last.toString(), '10.128.0.0/9');
    expect(outer.subtracting(outer), isEmpty);
    expect(outer.subtracting(IPv4Prefix.parse('11.0.0.0/8')!), [outer]);
    expect(IPv4Prefix.parse('300.0.0.0/8'), isNull);
    expect(IPv4Prefix.parse('10.0.0.0/33'), isNull);
  });

  test('OpenVPN servers always go Direct by name and address', () async {
    final original = Fixtures.store();
    final byIP = Tunnel(
      id: '00000000-0000-4000-8000-000000000003',
      name: 'ByIP',
      slot: 3,
      kind: TunnelKindOpenVPN(
        OpenVPNMeta(
          remotes: const [
            Remote(host: '203.0.113.9', port: 1194, proto: 'udp'),
            Remote(host: 'VPN.Example.ORG', port: 443, proto: 'tcp'),
          ],
          needsCredentials: false,
          needsKeyPassphrase: false,
          discoveredDNS: const [],
          configHash: 'x',
        ),
      ),
      createdAt: Fixtures.date,
    );
    final store = original.copyWith(tunnels: [...original.tunnels, byIP]);
    final output = _generate(store);
    final config = _json(output.config);
    final rules = _objects(_object(config, 'route')['rules']);
    final processIndex = rules.indexWhere(
      (rule) => rule.containsKey('process_path'),
    );
    final server = rules[processIndex + 1];
    expect(server['outbound'], 'direct');
    expect(server['ip_cidr'], ['203.0.113.9/32']);
    expect(server['domain'], ['vpn.example.org']);
    expect(rules[processIndex + 2].containsKey('rule_set'), isTrue);
    final dnsRules = _objects(_object(config, 'dns')['rules']);
    expect(dnsRules[3]['domain'], ['vpn.example.org']);
    expect(dnsRules[3]['server'], 'dns-direct');

    final resolved = _json(
      _generate(
        store,
        resolved: {
          'vpn.example.org': [
            '198.51.100.7',
            '198.51.100.2',
            '203.0.113.9',
            'bogus',
          ],
          '203.0.113.9': ['1.2.3.4'],
          'other.example': ['5.6.7.8'],
        },
      ).config,
    );
    final resolvedRules = _objects(_object(resolved, 'route')['rules']);
    final resolvedServer = resolvedRules[processIndex + 1];
    expect(resolvedServer['ip_cidr'], [
      '198.51.100.2/32',
      '198.51.100.7/32',
      '203.0.113.9/32',
    ]);
    expect(resolvedServer['domain'], ['vpn.example.org']);
    expect(HostResolver.openVPNHosts(store), ['vpn.example.org']);
    expect(await HostResolver.resolveIPv4(['localhost']), {
      'localhost': ['127.0.0.1'],
    });
    expect(await HostResolver.resolveIPv4(['nonexistent.invalid']), isEmpty);

    final vlessOnly = store.copyWith(
      tunnels: store.tunnels.where((tunnel) => !tunnel.kind.isOpenVPN).toList(),
    );
    final plain = _json(_generate(vlessOnly).config);
    final plainRules = _objects(_object(plain, 'route')['rules']);
    expect(
      plainRules.any(
        (rule) => rule.containsKey('ip_cidr') && !rule.containsKey('rule_set'),
      ),
      isFalse,
    );
    final plainDNS = _objects(_object(plain, 'dns')['rules']);
    expect(
      plainDNS.any(
        (rule) => rule.containsKey('domain') && rule.containsKey('server'),
      ),
      isFalse,
    );
  });

  test('Windows names and paths are emitted and escaped correctly', () {
    final input = _input(
      _twoTunnelStore(),
      platform: WayforkPlatform.windows,
      installDir: _windowsInstallDir,
    );
    final output = SingBoxConfigGenerator.generate(input);
    final config = _json(output.config);
    expect(_objects(config['inbounds']).first['interface_name'], 'Wayfork');
    final outbounds = _objects(config['outbounds']);
    expect(outbounds[1]['bind_interface'], 'Wayfork-1');
    final processRule = _objects(
      _object(config, 'route')['rules'],
    ).firstWhere((rule) => rule.containsKey('process_path'));
    expect(processRule['process_path'], [
      r'C:\Program Files\Wayfork\bin\openvpn.exe',
    ]);
    expect(
      output.config,
      contains(r'"C:\\Program Files\\Wayfork\\bin\\openvpn.exe"'),
    );
  });

  test(
    'OpenVPN outbounds resolve through their own tunnel DNS',
    _openVPNOutboundsResolveThroughTheirOwnTunnelDNS,
  );
}

/// Fake-IP destinations are resolved again by an outbound at dial time. A
/// VPN-only public name, such as one with a pushed host route, must therefore
/// use that tunnel's resolver and never `dns-direct`.
void _openVPNOutboundsResolveThroughTheirOwnTunnelDNS() {
  final input = SingBoxInput.fromJson(
    _json(Fixtures.text('singbox/two-tunnels/input.json')),
    platform: WayforkPlatform.macOS,
  );
  final config = _json(SingBoxConfigGenerator.generate(input).config);
  final outbounds = _objects(config['outbounds']);
  final dns = _object(config, 'dns');
  final dnsServers = _objects(dns['servers']);
  for (final tunnel in input.store.tunnels.where(
    (tunnel) => tunnel.kind.isOpenVPN,
  )) {
    final outbound = outbounds.singleWhere(
      (candidate) => candidate['tag'] == tunnel.outboundTag,
    );
    final resolver = _object(outbound, 'domain_resolver');
    final dnsTag = 'dns-${tunnel.outboundTag}';
    expect(resolver['server'], dnsTag);
    expect(resolver['strategy'], 'ipv4_only');
    final server = dnsServers.singleWhere(
      (candidate) => candidate['tag'] == dnsTag,
    );
    expect(server['detour'], tunnel.outboundTag);
    expect(server['server'], tunnel.kind.openVPN!.discoveredDNS.first);
  }
  expect(_object(config, 'route')['default_domain_resolver'], 'dns-direct');
  final vless = outbounds.singleWhere(
    (outbound) => outbound['tag'] == Fixtures.home.outboundTag,
  );
  expect(vless.containsKey('domain_resolver'), isFalse);
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

Store _defaultTunnelStore(String defaultID) {
  final store = _twoTunnelStore();
  return store.copyWith(
    defaultTunnelID: defaultID,
    rules: [
      ...store.rules,
      Rule(pattern: 'bank.example.org', target: const RuleTargetDirect()),
      Rule(
        pattern: '*.intranet.example',
        match: RuleMatch.wildcard,
        target: const RuleTargetDirect(),
      ),
      Rule(pattern: 'example.com', target: const RuleTargetDirect()),
    ],
  );
}

SingBoxInput _input(
  Store store, {
  Map<String, String> uuids = const {Fixtures.homeID: _homeUUID},
  Map<String, List<String>> resolved = const {},
  List<String> systemDNS = const [],
  List<String> network = const [],
  WayforkPlatform platform = WayforkPlatform.macOS,
  String installDir = _bundlePath,
}) => SingBoxInput(
  store: store,
  vlessUUIDs: uuids,
  openVPNBinaryPath: platform.openVPNBinaryPath(installDir),
  resolvedServerAddresses: resolved,
  systemDNSServers: systemDNS,
  networkResolvers: network,
  platform: platform,
);

SingBoxOutput _generate(
  Store store, {
  Map<String, String> uuids = const {Fixtures.homeID: _homeUUID},
  Map<String, List<String>> resolved = const {},
  List<String> systemDNS = const [],
  List<String> network = const [],
}) => SingBoxConfigGenerator.generate(
  _input(
    store,
    uuids: uuids,
    resolved: resolved,
    systemDNS: systemDNS,
    network: network,
  ),
);

Map<String, SingBoxInput> _configVariants({
  required WayforkPlatform platform,
  required String installDir,
}) {
  final variants = <String, SingBoxInput>{
    'two-tunnels': _input(
      _twoTunnelStore(),
      platform: platform,
      installDir: installDir,
    ),
  };
  final base = _twoTunnelStore();
  variants['custom-dns'] = _input(
    base.copyWith(
      settings: base.settings.copyWith(
        directDNS: DirectDNSCustom(['9.9.9.9']),
        logLevel: LogLevel.debug,
      ),
    ),
    platform: platform,
    installDir: installDir,
  );
  variants['no-tunnels'] = _input(
    base.copyWith(tunnels: []),
    platform: platform,
    installDir: installDir,
  );
  final wsHome = base.tunnels[1].copyWith(
    kind: TunnelKindVLESS(
      VLESSMeta(
        server: 's.example',
        port: 443,
        security: VLESSSecurity.tls,
        fingerprint: 'safari',
        alpn: const ['h2'],
        transport: const VLESSTransportWS(path: '/x', host: 'h.example'),
      ),
    ),
  );
  variants['vless-ws'] = _input(
    base.copyWith(tunnels: [base.tunnels[0], wsHome]),
    platform: platform,
    installDir: installDir,
  );
  variants['default-openvpn'] = _input(
    _defaultTunnelStore(Fixtures.workID),
    platform: platform,
    installDir: installDir,
  );
  variants['default-vless'] = _input(
    _defaultTunnelStore(Fixtures.homeID),
    platform: platform,
    installDir: installDir,
  );
  variants['app-rules'] = _input(
    base.copyWith(
      rules: [
        ...base.rules,
        Rule.tunnel(
          pattern: '/Applications/Telegram.app',
          match: RuleMatch.app,
          tunnelID: Fixtures.workID,
        ),
        Rule(
          pattern: '/Applications/Bank (Beta).app',
          match: RuleMatch.app,
          target: const RuleTargetDirect(),
        ),
      ],
    ),
    platform: platform,
    installDir: installDir,
  );
  variants['ip-rules'] = _input(
    base.copyWith(
      rules: [
        ...base.rules,
        Rule.tunnel(
          pattern: '10.8.0.0/24',
          match: RuleMatch.ip,
          tunnelID: Fixtures.workID,
        ),
        Rule.tunnel(
          pattern: '203.0.113.7',
          match: RuleMatch.ip,
          tunnelID: Fixtures.homeID,
        ),
        Rule(
          pattern: '192.168.50.0/24',
          match: RuleMatch.ip,
          target: const RuleTargetDirect(),
        ),
      ],
    ),
    platform: platform,
    installDir: installDir,
  );
  variants['system-dns'] = _input(
    base,
    systemDNS: const ['192.168.31.5', '8.8.8.8'],
    platform: platform,
    installDir: installDir,
  );
  return variants;
}

Map<String, Object?> _goldenInputJson(SingBoxInput input) {
  final rules = <Rule>[];
  for (var index = 0; index < input.store.rules.length; index++) {
    rules.add(
      input.store.rules[index].copyWith(
        id:
            '00000000-0000-4000-8000-0000000001'
            '${index.toRadixString(16).padLeft(2, '0')}',
      ),
    );
  }
  return SingBoxInput(
    store: input.store.copyWith(rules: rules),
    vlessUUIDs: input.vlessUUIDs,
    openVPNBinaryPath: input.openVPNBinaryPath,
    resolvedServerAddresses: input.resolvedServerAddresses,
    systemDNSServers: input.systemDNSServers,
    networkResolvers: input.networkResolvers,
    platform: input.platform,
  ).toJson();
}

List<IPv4Prefix> _excludedRanges(SingBoxOutput output) {
  final inbound = _objects(_json(output.config)['inbounds']).first;
  return (inbound['route_exclude_address']! as List<Object?>)
      .cast<String>()
      .map(IPv4Prefix.parse)
      .whereType<IPv4Prefix>()
      .toList();
}

Map<String, Object?> _json(String text) =>
    jsonDecode(text)! as Map<String, Object?>;

Map<String, Object?> _object(Map<String, Object?> parent, String key) =>
    parent[key]! as Map<String, Object?>;

List<Map<String, Object?>> _objects(Object? value) =>
    (value! as List<Object?>).cast<Map<String, Object?>>();

String _firstDifference(String file, String expected, String actual) {
  final expectedLines = const LineSplitter().convert(expected);
  final actualLines = const LineSplitter().convert(actual);
  final length = expectedLines.length > actualLines.length
      ? expectedLines.length
      : actualLines.length;
  for (var index = 0; index < length; index++) {
    final left = index < expectedLines.length ? expectedLines[index] : '<EOF>';
    final right = index < actualLines.length ? actualLines[index] : '<EOF>';
    if (left != right) {
      return '$file differs at line ${index + 1}:\n- $left\n+ $right';
    }
  }
  return '$file differs in trailing newline or byte representation';
}
