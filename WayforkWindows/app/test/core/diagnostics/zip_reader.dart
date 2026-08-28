import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Reads an archive back the way any unzip does: from the end-of-directory
/// record, through the central directory, into the local headers.
Map<String, List<int>> unzip(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  var end = bytes.length - 22;
  while (end >= 0 && view.getUint32(end, Endian.little) != 0x06054b50) {
    end -= 1;
  }
  expect(end, greaterThanOrEqualTo(0), reason: 'no end-of-directory record');
  final count = view.getUint16(end + 10, Endian.little);
  expect(view.getUint16(end + 8, Endian.little), count);
  var offset = view.getUint32(end + 16, Endian.little);
  final files = <String, List<int>>{};
  for (var index = 0; index < count; index++) {
    expect(view.getUint32(offset, Endian.little), 0x02014b50);
    final method = view.getUint16(offset + 10, Endian.little);
    final crc = view.getUint32(offset + 16, Endian.little);
    final compressed = view.getUint32(offset + 20, Endian.little);
    final uncompressed = view.getUint32(offset + 24, Endian.little);
    final nameLength = view.getUint16(offset + 28, Endian.little);
    final extraLength = view.getUint16(offset + 30, Endian.little);
    final commentLength = view.getUint16(offset + 32, Endian.little);
    final local = view.getUint32(offset + 42, Endian.little);
    final name = utf8.decode(
      bytes.sublist(offset + 46, offset + 46 + nameLength),
    );

    expect(view.getUint32(local, Endian.little), 0x04034b50);
    expect(view.getUint16(local + 8, Endian.little), method);
    expect(view.getUint32(local + 14, Endian.little), crc);
    expect(view.getUint32(local + 18, Endian.little), compressed);
    expect(view.getUint32(local + 22, Endian.little), uncompressed);
    final localName = view.getUint16(local + 26, Endian.little);
    final localExtra = view.getUint16(local + 28, Endian.little);
    expect(
      utf8.decode(bytes.sublist(local + 30, local + 30 + localName)),
      name,
    );
    final start = local + 30 + localName + localExtra;
    final data = bytes.sublist(start, start + compressed);
    files[name] = method == 0 ? data : ZLibCodec(raw: true).decode(data);
    expect(files[name]!.length, uncompressed);
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return files;
}
