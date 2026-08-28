import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/diagnostics/zip_writer.dart';

import 'zip_reader.dart';

void main() {
  final stamp = DateTime(2026, 8, 28, 15, 30, 45);

  test('every entry survives the round trip', () {
    final bytes = ZipWriter.build([
      ZipEntry.text('wayfork-diagnostics/system.txt', 'Wayfork 0.1.0\n'),
      ZipEntry.text(
        'wayfork-diagnostics/store.json',
        // Long enough that deflate wins.
        '{"tunnels": [${'{"name": "office"},' * 40}]}',
      ),
      ZipEntry('wayfork-diagnostics/daemon/routes.txt', const [0, 1, 2, 255]),
    ], modified: stamp);

    final files = unzip(bytes);
    expect(files.keys, [
      'wayfork-diagnostics/system.txt',
      'wayfork-diagnostics/store.json',
      'wayfork-diagnostics/daemon/routes.txt',
    ]);
    expect(
      utf8.decode(files['wayfork-diagnostics/system.txt']!),
      'Wayfork 0.1.0\n',
    );
    expect(
      utf8.decode(files['wayfork-diagnostics/store.json']!),
      contains('"office"'),
    );
    expect(files['wayfork-diagnostics/daemon/routes.txt'], [0, 1, 2, 255]);
  });

  test('compressible content is deflated, incompressible is stored', () {
    final bytes = ZipWriter.build([
      ZipEntry.text('long.txt', 'wayfork' * 500),
      ZipEntry.text('short.txt', 'x'),
    ], modified: stamp);
    final view = ByteData.sublistView(bytes);

    // The first local header sits at offset 0; the method is at +8.
    expect(view.getUint16(8, Endian.little), 8, reason: 'deflate');
    expect(
      view.getUint32(18, Endian.little),
      lessThan(view.getUint32(22, Endian.little)),
    );
    final files = unzip(bytes);
    expect(utf8.decode(files['long.txt']!), 'wayfork' * 500);
    expect(utf8.decode(files['short.txt']!), 'x');
  });

  test('the MS-DOS stamp keeps the local time to two seconds', () {
    final bytes = ZipWriter.build([
      ZipEntry.text('a.txt', 'a'),
    ], modified: DateTime(2026, 8, 28, 15, 30, 45));
    final view = ByteData.sublistView(bytes);
    expect(
      view.getUint16(10, Endian.little),
      (15 << 11) | (30 << 5) | (45 ~/ 2),
    );
    expect(
      view.getUint16(12, Endian.little),
      ((2026 - 1980) << 9) | (8 << 5) | 28,
    );
  });

  test('a non-ASCII name is flagged as UTF-8', () {
    final bytes = ZipWriter.build([
      ZipEntry.text('логи.txt', 'ok'),
    ], modified: stamp);
    expect(ByteData.sublistView(bytes).getUint16(6, Endian.little), 0x0800);
    expect(utf8.decode(unzip(bytes)['логи.txt']!), 'ok');
  });

  test('an empty archive is still a valid one', () {
    final bytes = ZipWriter.build(const [], modified: stamp);
    expect(bytes.length, 22);
    expect(unzip(bytes), isEmpty);
  });

  test('names that are not files are refused', () {
    expect(
      () => ZipWriter.build([ZipEntry.text('', 'x')], modified: stamp),
      throwsArgumentError,
    );
    expect(
      () => ZipWriter.build([ZipEntry.text('dir/', 'x')], modified: stamp),
      throwsArgumentError,
    );
    expect(
      () => ZipWriter.build([
        ZipEntry.text('a.txt', 'x'),
        ZipEntry.text('a.txt', 'y'),
      ], modified: stamp),
      throwsArgumentError,
    );
  });
}
