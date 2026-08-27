import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/secrets/dpapi_secret_store.dart';
import 'package:wayfork/core/secrets/secret_store.dart';
import 'package:wayfork/core/store/store_repository.dart';
import 'package:wayfork/core/support/uuid.dart';

import 'fixtures.dart';

void main() {
  group('StoreRepository', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('wayfork-tests-');
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    test('loads an empty store when the file is missing', () async {
      final repository = StoreRepository(Directory('${directory.path}/nested'));
      final result = await repository.load();
      expect(result.store, Store.empty);
      expect(result.corruptBackup, isNull);
    });

    test('writes atomically and reloads', () async {
      final repository = StoreRepository(
        directory,
        debounce: const Duration(milliseconds: 20),
      );
      final store = Fixtures.store(
        rules: [Rule.tunnel(pattern: 'example.com', tunnelID: Fixtures.workID)],
      );
      repository.save(store);
      expect(repository.hasPendingChanges, isTrue);
      await repository.flush();
      expect(repository.hasPendingChanges, isFalse);
      expect((await StoreRepository(directory).load()).store, store);
      expect(File('${repository.file.path}.tmp').existsSync(), isFalse);
    });

    test('debounces saves', () async {
      final repository = StoreRepository(
        directory,
        debounce: const Duration(milliseconds: 30),
      );
      for (var days = 0; days < 5; days++) {
        repository.save(
          Store(
            settings: Store.empty.settings.copyWith(logRetentionDays: days),
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect((await repository.load()).store.settings.logRetentionDays, 4);
    });

    test('moves a corrupt file aside', () async {
      final file = File('${directory.path}/store.json')
        ..writeAsStringSync('{not json');
      final result = await StoreRepository(directory).load();
      expect(result.store, Store.empty);
      expect(result.corruptBackup?.path, contains('store.json.corrupt-'));
      expect(result.corruptBackup!.existsSync(), isTrue);
      expect(file.existsSync(), isFalse);
    });

    test('refuses a newer schema without touching it', () async {
      final file = File('${directory.path}/store.json')
        ..writeAsStringSync(
          '{"schemaVersion":7,"tunnels":[],"rules":[],"settings":{}}',
        );
      await expectLater(
        StoreRepository(directory).load(),
        throwsA(isA<StoreRepositoryException>()),
      );
      expect(file.existsSync(), isTrue);
    });
  });

  test('secret keys map to accounts', () {
    final expected = {
      SecretKind.ovpn: 'ovpn',
      SecretKind.credentials: 'credentials',
      SecretKind.keyPassphrase: 'keyPassphrase',
      SecretKind.uuid: 'uuid',
    };
    for (final entry in expected.entries) {
      final key = SecretKey(entry.key, Fixtures.workID);
      expect(key.account, 'tunnel/${Fixtures.workID}/${entry.value}');
      expect(SecretKey.parse(key.account), key);
    }
    expect(SecretKey.parse('other/thing'), isNull);
    expect(SecretKey.parse('tunnel/not-a-uuid/ovpn'), isNull);
  });

  test('in-memory helpers and orphan cleanup', () async {
    await _runHelperScenario(InMemorySecretStore());
  });

  test(
    'DPAPI store persists, enumerates, deletes and detects corruption',
    () async {
      final directory = Directory.systemTemp.createTempSync('wayfork-tests-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/nested/secrets.dat');
      const protector = _FakeProtector();
      await _runHelperScenario(DpapiSecretStore(file, protector));

      final first = DpapiSecretStore(file, protector);
      final key = SecretKey(SecretKind.ovpn, Fixtures.workID);
      await first.write('client', key);
      final second = DpapiSecretStore(file, protector);
      expect(await second.read(key), 'client');
      expect(await second.allKeys(), contains(key));
      await second.delete(key);
      expect(await DpapiSecretStore(file, protector).read(key), isNull);

      await second.write('client', key);
      final document =
          JsonCoding.decode(file.readAsStringSync())! as Map<String, Object?>;
      final items = Map<String, Object?>.from(
        document['items']! as Map<String, Object?>,
      );
      final blob = base64Decode(items[key.account]! as String)..[0] ^= 0xff;
      items[key.account] = base64Encode(blob);
      file.writeAsStringSync(
        JsonCoding.encodeCompact({...document, 'items': items}),
      );
      await expectLater(
        DpapiSecretStore(file, protector).read(key),
        throwsA(
          const SecretStoreException(
            kind: SecretStoreError.unprotectFailed,
            account: 'tunnel/00000000-0000-4000-8000-000000000001/ovpn',
          ),
        ),
      );
    },
  );
}

Future<void> _runHelperScenario(SecretStore store) async {
  const credentials = Credentials(username: 'u', password: 'p');
  await store.writeCredentials(credentials, Fixtures.workID);
  expect(await store.readCredentials(Fixtures.workID), credentials);
  expect(await store.readCredentials(Fixtures.homeID), isNull);

  final orphan = Uuid.generate();
  await store.write('body', SecretKey(SecretKind.ovpn, orphan));
  await store.write('uuid', SecretKey(SecretKind.uuid, Fixtures.homeID));
  final removed = await store.removeOrphans(Fixtures.store());
  expect(removed, [SecretKey(SecretKind.ovpn, orphan)]);
  expect(await store.read(SecretKey(SecretKind.uuid, Fixtures.homeID)), 'uuid');

  await store.deleteAll(Fixtures.workID);
  expect(
    await store.read(SecretKey(SecretKind.credentials, Fixtures.workID)),
    isNull,
  );
}

final class _FakeProtector implements DataProtector {
  const _FakeProtector();

  static const _magic = [0x57, 0x46, 0x4b, 0x31];
  static const _key = 0xa5;

  @override
  Uint8List protect(Uint8List plain) =>
      Uint8List.fromList([..._magic, ...plain.map((byte) => byte ^ _key)]);

  @override
  Uint8List unprotect(Uint8List blob) {
    if (blob.length < _magic.length ||
        !_magic.asMap().entries.every(
          (entry) => blob[entry.key] == entry.value,
        )) {
      throw const FormatException('Invalid protected blob');
    }
    return Uint8List.fromList(
      blob.skip(_magic.length).map((byte) => byte ^ _key).toList(),
    );
  }
}
