import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One file of the archive. [name] uses forward slashes and is relative to the
/// archive root.
final class ZipEntry {
  const ZipEntry(this.name, this.bytes);

  ZipEntry.text(String name, String text) : this(name, utf8.encode(text));

  final String name;
  final List<int> bytes;
}

/// The zip half of "Export Diagnostics" (docs/design/06-logging.md). macOS
/// shells out to `ditto -c -k`; Windows has no equivalent that is both always
/// present and scriptable without PowerShell, so the container is written here
/// — deflate itself is dart:io's zlib, not a Dart implementation.
///
/// Deliberately minimal: no zip64, no directory entries, no encryption. The
/// diagnostics bundle is a handful of small files, and every reader (Explorer
/// included) handles this shape.
abstract final class ZipWriter {
  static const _localHeaderSignature = 0x04034b50;
  static const _centralHeaderSignature = 0x02014b50;
  static const _endOfDirectorySignature = 0x06054b50;

  /// Version 2.0: the deflate method, which is all this writer emits.
  static const _version = 20;
  static const _methodStore = 0;
  static const _methodDeflate = 8;
  static const _utf8Flag = 0x0800;
  static const _maxEntryBytes = 0xFFFFFFFF;

  static final _deflate = ZLibCodec(raw: true, level: 6);

  /// [modified] is stamped on every entry, in local time as the format wants.
  static Uint8List build(List<ZipEntry> entries, {required DateTime modified}) {
    final time = _dosTime(modified);
    final date = _dosDate(modified);
    final files = _Bytes();
    final directory = _Bytes();
    final seen = <String>{};
    for (final entry in entries) {
      if (entry.name.isEmpty || entry.name.endsWith('/')) {
        throw ArgumentError.value(entry.name, 'name', 'not a file name');
      }
      if (!seen.add(entry.name)) {
        throw ArgumentError.value(entry.name, 'name', 'duplicate entry');
      }
      if (entry.bytes.length > _maxEntryBytes) {
        throw ArgumentError.value(
          entry.name,
          'name',
          'entry too large for zip',
        );
      }
      final name = utf8.encode(entry.name);
      final flags = name.any((byte) => byte >= 0x80) ? _utf8Flag : 0;
      final deflated = _deflate.encode(entry.bytes);
      final stored = deflated.length >= entry.bytes.length;
      final data = stored ? entry.bytes : deflated;
      final method = stored ? _methodStore : _methodDeflate;
      final offset = files.length;

      files.u32(_localHeaderSignature);
      files.u16(_version);
      files.u16(flags);
      files.u16(method);
      files.u16(time);
      files.u16(date);
      files.u32(_crc32(entry.bytes));
      files.u32(data.length);
      files.u32(entry.bytes.length);
      files.u16(name.length);
      files.u16(0);
      files.raw(name);
      files.raw(data);

      directory.u32(_centralHeaderSignature);
      // "Made by" MS-DOS, so no external attributes are expected.
      directory.u16(_version);
      directory.u16(_version);
      directory.u16(flags);
      directory.u16(method);
      directory.u16(time);
      directory.u16(date);
      directory.u32(_crc32(entry.bytes));
      directory.u32(data.length);
      directory.u32(entry.bytes.length);
      directory.u16(name.length);
      directory.u16(0);
      directory.u16(0);
      directory.u16(0);
      directory.u16(0);
      directory.u32(0);
      directory.u32(offset);
      directory.raw(name);
    }
    final directoryOffset = files.length;
    final directoryBytes = directory.take();
    files.raw(directoryBytes);
    files.u32(_endOfDirectorySignature);
    files.u16(0);
    files.u16(0);
    files.u16(entries.length);
    files.u16(entries.length);
    files.u32(directoryBytes.length);
    files.u32(directoryOffset);
    files.u16(0);
    return files.take();
  }

  /// Seconds have a two-second resolution in the MS-DOS stamp.
  static int _dosTime(DateTime at) =>
      (at.hour << 11) | (at.minute << 5) | (at.second ~/ 2);

  static int _dosDate(DateTime at) {
    final year = at.year < 1980 ? 1980 : at.year;
    return ((year - 1980) << 9) | (at.month << 5) | at.day;
  }

  static final Uint32List _crcTable = () {
    final table = Uint32List(256);
    for (var index = 0; index < table.length; index++) {
      var value = index;
      for (var bit = 0; bit < 8; bit++) {
        value = (value & 1) == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
      }
      table[index] = value;
    }
    return table;
  }();

  static int _crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }
}

/// Little-endian output buffer.
final class _Bytes {
  final _builder = BytesBuilder();

  int get length => _builder.length;

  void u16(int value) {
    _builder.addByte(value & 0xFF);
    _builder.addByte((value >> 8) & 0xFF);
  }

  void u32(int value) {
    u16(value & 0xFFFF);
    u16((value >> 16) & 0xFFFF);
  }

  void raw(List<int> value) => _builder.add(value);

  Uint8List take() => _builder.takeBytes();
}
