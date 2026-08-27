import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/support/hashing.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/support/uuid.dart';

void main() {
  test('UUIDs normalize, encode and generate as v4', () {
    const upper = '00000000-0000-4000-8000-0000000000AA';
    expect(Uuid.normalize(upper), upper.toLowerCase());
    expect(Uuid.encode(upper), upper);
    expect(Uuid.normalize('not-a-uuid'), isNull);
    final generated = Uuid.generate();
    expect(generated, hasLength(36));
    expect(generated[14], '4');
    expect(Uuid.isValid(generated), isTrue);
  });

  test('SHA-256 is lowercase hexadecimal', () {
    expect(
      Hashing.sha256Hex('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(Hashing.sha256HexBytes([97, 98, 99]), Hashing.sha256Hex('abc'));
  });

  test('IPv4 prefixes parse and subtract', () {
    final host = IPv4Prefix.parse('203.0.113.7')!;
    expect(host.bits, 32);
    expect(host.isHost, isTrue);
    expect(host.canonical, '203.0.113.7');
    expect(host.toString(), '203.0.113.7/32');
    final network = IPv4Prefix.parse('10.8.0.5/24')!;
    expect(network.canonical, '10.8.0.0/24');
    for (final bad in [
      '10.8.0.0/33',
      '10.8.0.0/-1',
      '10.8.0.0/+1',
      '10.8/16',
      '::1',
      '10.8.0.0/',
      '01.2.3.4',
      ' 1.2.3.4',
      'x',
      '',
    ]) {
      expect(IPv4Prefix.parse(bad), isNull, reason: bad);
    }
    final ten = IPv4Prefix.parse('10.0.0.0/8')!;
    expect(ten.overlaps(network), isTrue);
    expect(network.overlaps(host), isFalse);
    expect(ten.subtractingAll([network]), hasLength(16));
    final two = ten
        .subtractingAll([network, IPv4Prefix.parse('10.9.0.0/16')!])
        .map((value) => value.toString())
        .toList();
    expect(two, contains('10.8.1.0/24'));
    expect(two, isNot(contains('10.9.0.0/16')));
    expect(two, hasLength(15));
    expect(ten.subtractingAll([ten]), isEmpty);
    expect(network.subtractingAll([host]), [network]);
  });

  test('platform names and binary paths', () {
    expect(WayforkPlatform.windows.openVPNInterface(0), 'Wayfork-1');
    expect(WayforkPlatform.windows.openVPNInterface(31), 'Wayfork-32');
    expect(WayforkPlatform.macOS.openVPNInterface(0), 'utun101');
    expect(
      WayforkPlatform.windows.openVPNBinaryPath(r'C:\Program Files\Wayfork'),
      r'C:\Program Files\Wayfork\bin\openvpn.exe',
    );
  });
}
