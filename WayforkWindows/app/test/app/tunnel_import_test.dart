import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/ui/tunnel_import.dart';
import 'package:wayfork/core/model/tunnel.dart';

import 'fakes.dart';
import 'lifecycle_fakes.dart';

void main() {
  late Harness h;
  late Directory dir;
  late FakeFilePicker picker;
  late List<List<String>> asked;
  late bool answer;

  TunnelImporter importer() => TunnelImporter(
    model: h.model,
    picker: picker,
    confirmFolder: (missing) async {
      asked.add(missing);
      return answer;
    },
  );

  File write(String name, String contents, {Directory? into}) {
    final file = File('${(into ?? dir).path}${Platform.pathSeparator}$name');
    file.writeAsStringSync(contents);
    return file;
  }

  setUp(() async {
    h = Harness();
    picker = FakeFilePicker();
    asked = [];
    answer = true;
    dir = Directory.systemTemp.createTempSync('wayfork-import');
    await h.start();
  });

  tearDown(() async {
    await h.dispose();
    dir.deleteSync(recursive: true);
  });

  test('the picker path becomes a tunnel named after the file', () async {
    picker.file = write(
      'Office VPN.ovpn',
      'client\nremote vpn.example.com 1194 udp\n',
    ).path;

    await importer().importFromPicker();

    final tunnel = h.model.store.tunnels.last;
    expect(tunnel.name, 'Office VPN');
    expect(tunnel.kind.openVPN?.remotes.single.host, 'vpn.example.com');
    expect(h.model.expandedTunnelID, tunnel.id);
    expect(picker.openCalls, 1);
  });

  test('a cancelled picker changes nothing', () async {
    await importer().importFromPicker();

    expect(h.model.store.tunnels, hasLength(3));
    expect(h.model.alerts, isEmpty);
  });

  test(
    'referenced files are looked for in the folder the user picks',
    () async {
      final elsewhere = Directory('${dir.path}${Platform.pathSeparator}certs')
        ..createSync();
      write('ca.crt', '-----BEGIN CERTIFICATE-----\n', into: elsewhere);
      picker.file = write(
        'branch.ovpn',
        'client\nremote vpn.example.com 1194 udp\nca ca.crt\n',
      ).path;
      picker.directory = elsewhere.path;

      await importer().importFromPicker();

      expect(asked, [
        ['ca.crt'],
      ]);
      expect(picker.directoryCalls, 1);
      final tunnel = h.model.store.tunnels.last;
      expect(tunnel.name, 'branch');
      expect(h.model.alerts, isEmpty);
    },
  );

  test('declining the folder prompt cancels the import', () async {
    answer = false;
    picker.file = write(
      'lab.ovpn',
      'client\nremote vpn.example.com 1194 udp\nca ca.crt\n',
    ).path;

    await importer().importFromPicker();

    expect(h.model.store.tunnels, hasLength(3));
    expect(picker.directoryCalls, 0);
    expect(h.model.alerts, isEmpty);
  });

  test('a profile without a remote is refused with an alert', () async {
    picker.file = write('broken.ovpn', 'client\nnobind\n').path;

    await importer().importFromPicker();

    expect(h.model.store.tunnels, hasLength(3));
    expect(h.model.alerts.single.title, 'Invalid config');
    expect(
      h.model.alerts.single.message,
      'The profile has no `remote` directive.',
    );
  });

  test('an unreadable file is reported, not thrown', () async {
    picker.file = '${dir.path}${Platform.pathSeparator}missing.ovpn';

    await importer().importFromPicker();

    expect(h.model.alerts.single.title, 'Cannot read file');
  });

  test('a drop imports every .ovpn and ignores everything else', () async {
    final first = write('one.ovpn', 'remote a.example.com 1194 udp\n');
    final second = write('two.OVPN', 'remote b.example.com 1194 udp\n');
    final other = write('notes.txt', 'hello');

    await importer().importDropped([first.path, other.path, second.path]);

    expect(h.model.store.tunnels.map((tunnel) => tunnel.name).toList(), [
      'Work',
      'Home',
      'Lab',
      'one',
      'two',
    ]);
  });

  test('Replace… swaps the config and keeps the tunnel', () async {
    final work = h.sample.work;
    await h.model.setDNS(work.id, TunnelDNSCustom(const ['10.8.0.1']));
    picker.file = write(
      'new.ovpn',
      'client\nremote new.example.com 443 tcp\n',
    ).path;

    await importer().replaceConfig(work.id);

    final updated = h.model.store.tunnel(work.id)!;
    expect(updated.name, 'Work');
    expect(updated.kind.openVPN?.remotes.single.host, 'new.example.com');
    expect(updated.kind.openVPN?.dns, TunnelDNSCustom(const ['10.8.0.1']));
  });
}
