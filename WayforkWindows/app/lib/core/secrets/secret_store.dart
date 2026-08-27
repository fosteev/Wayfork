import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/support/uuid.dart';

enum SecretKind {
  ovpn('ovpn'),
  credentials('credentials'),
  keyPassphrase('keyPassphrase'),
  uuid('uuid');

  const SecretKind(this.jsonValue);
  final String jsonValue;
}

final class SecretKey {
  SecretKey(this.kind, String tunnelID)
    : tunnelID = _uuid(tunnelID, 'tunnelID');

  final SecretKind kind;
  final String tunnelID;

  String get account => 'tunnel/$tunnelID/${kind.jsonValue}';

  static SecretKey? parse(String account) {
    final parts = account.split('/');
    if (parts.length != 3 || parts[0] != 'tunnel') return null;
    final id = Uuid.normalize(parts[1]);
    if (id == null) return null;
    for (final kind in SecretKind.values) {
      if (parts[2] == kind.jsonValue) return SecretKey(kind, id);
    }
    return null;
  }

  static List<SecretKey> allFor(String tunnelID) =>
      SecretKind.values.map((kind) => SecretKey(kind, tunnelID)).toList();

  @override
  bool operator ==(Object other) =>
      other is SecretKey && kind == other.kind && tunnelID == other.tunnelID;

  @override
  int get hashCode => Object.hash(kind, tunnelID);

  @override
  String toString() => account;
}

enum SecretStoreError { dpapi, unprotectFailed }

final class SecretStoreException implements Exception {
  const SecretStoreException({required this.kind, this.account, this.status});

  final SecretStoreError kind;
  final String? account;
  final int? status;

  @override
  bool operator ==(Object other) =>
      other is SecretStoreException &&
      kind == other.kind &&
      account == other.account &&
      status == other.status;

  @override
  int get hashCode => Object.hash(kind, account, status);

  @override
  String toString() =>
      'SecretStoreException($kind, account: $account, status: $status)';
}

abstract interface class SecretStore {
  Future<String?> read(SecretKey key);
  Future<void> write(String value, SecretKey key);
  Future<void> delete(SecretKey key);
  Future<List<SecretKey>> allKeys();
}

extension SecretStoreHelpers on SecretStore {
  Future<void> writeCredentials(Credentials credentials, String tunnelID) =>
      write(
        JsonCoding.encodeCompact(credentials.toJson()),
        SecretKey(SecretKind.credentials, tunnelID),
      );

  Future<Credentials?> readCredentials(String tunnelID) async {
    final json = await read(SecretKey(SecretKind.credentials, tunnelID));
    if (json == null) return null;
    final value = JsonCoding.decode(json);
    if (value is! Map<String, Object?>) {
      throw const FormatException('Credentials must be an object');
    }
    return Credentials.fromJson(value);
  }

  Future<void> deleteAll(String tunnelID) async {
    for (final key in SecretKey.allFor(tunnelID)) {
      await delete(key);
    }
  }

  Future<List<SecretKey>> removeOrphans(Store store) async {
    final known = store.tunnels.map((tunnel) => tunnel.id).toSet();
    final removed = <SecretKey>[];
    for (final key in await allKeys()) {
      if (!known.contains(key.tunnelID)) {
        await delete(key);
        removed.add(key);
      }
    }
    return removed;
  }
}

final class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<SecretKey, String> items = const {}])
    : _items = Map.of(items);

  final Map<SecretKey, String> _items;

  @override
  Future<String?> read(SecretKey key) async => _items[key];

  @override
  Future<void> write(String value, SecretKey key) async {
    _items[key] = value;
  }

  @override
  Future<void> delete(SecretKey key) async {
    _items.remove(key);
  }

  @override
  Future<List<SecretKey>> allKeys() async => _items.keys.toList();
}

String _uuid(String value, String name) {
  final normalized = Uuid.normalize(value);
  if (normalized == null) throw FormatException('$name must be a UUID');
  return normalized;
}
