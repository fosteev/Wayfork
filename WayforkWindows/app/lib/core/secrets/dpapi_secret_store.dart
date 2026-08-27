import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/secrets/secret_store.dart';

abstract interface class DataProtector {
  Uint8List protect(Uint8List plain);
  Uint8List unprotect(Uint8List blob);
}

/// DPAPI-backed secret storage. Each item is protected independently.
final class DpapiSecretStore implements SecretStore {
  const DpapiSecretStore(this.file, this.protector);

  final File file;
  final DataProtector protector;

  @override
  Future<String?> read(SecretKey key) async {
    final items = await _readItems();
    final encoded = items[key.account];
    if (encoded == null) return null;
    try {
      final blob = Uint8List.fromList(base64Decode(encoded));
      return utf8.decode(protector.unprotect(blob));
    } on Object {
      throw SecretStoreException(
        kind: SecretStoreError.unprotectFailed,
        account: key.account,
      );
    }
  }

  @override
  Future<void> write(String value, SecretKey key) async {
    final items = await _readItems();
    items[key.account] = base64Encode(
      protector.protect(Uint8List.fromList(utf8.encode(value))),
    );
    await _writeItems(items);
  }

  @override
  Future<void> delete(SecretKey key) async {
    final items = await _readItems();
    if (items.remove(key.account) == null) return;
    await _writeItems(items);
  }

  @override
  Future<List<SecretKey>> allKeys() async => [
    for (final account in (await _readItems()).keys) ?SecretKey.parse(account),
  ];

  Future<Map<String, String>> _readItems() async {
    if (!await file.exists()) return {};
    final decoded = JsonCoding.decode(await file.readAsString());
    if (decoded is! Map<String, Object?> || decoded['version'] != 1) {
      throw const FormatException('Invalid secrets file');
    }
    final rawItems = decoded['items'];
    if (rawItems is! Map<String, Object?>) {
      throw const FormatException('Secrets items must be an object');
    }
    return rawItems.map((account, value) {
      if (value is! String) {
        throw FormatException('Secret $account must be base64 text');
      }
      return MapEntry(account, value);
    });
  }

  Future<void> _writeItems(Map<String, String> items) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    final document = <String, Object?>{'version': 1, 'items': items};
    await temporary.writeAsString(
      JsonCoding.encodeCompact(document),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
