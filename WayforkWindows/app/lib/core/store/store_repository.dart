import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wayfork/core/model/store.dart';

final class StoreLoadResult {
  const StoreLoadResult({required this.store, this.corruptBackup});

  final Store store;
  final File? corruptBackup;

  @override
  bool operator ==(Object other) =>
      other is StoreLoadResult &&
      store == other.store &&
      corruptBackup?.path == other.corruptBackup?.path;

  @override
  int get hashCode => Object.hash(store, corruptBackup?.path);
}

enum StoreRepositoryError { newerSchema }

final class StoreRepositoryException implements Exception {
  const StoreRepositoryException.newerSchema({
    required this.found,
    required this.supported,
  }) : kind = StoreRepositoryError.newerSchema;

  final StoreRepositoryError kind;
  final int found;
  final int supported;

  @override
  bool operator ==(Object other) =>
      other is StoreRepositoryException &&
      kind == other.kind &&
      found == other.found &&
      supported == other.supported;

  @override
  int get hashCode => Object.hash(kind, found, supported);

  @override
  String toString() =>
      'Store schema $found is newer than supported schema $supported';
}

/// Loads and saves `store.json` with debounced, atomic writes.
final class StoreRepository {
  StoreRepository(
    this.directory, {
    this.debounce = const Duration(milliseconds: 300),
  });

  static const fileName = 'store.json';

  final Directory directory;
  final Duration debounce;
  Store? _pending;
  Timer? _timer;

  File get file => File(_join(directory.path, fileName));

  bool get hasPendingChanges => _pending != null;

  static Directory defaultDirectory() {
    final environment = Platform.environment;
    if (Platform.isWindows) {
      final localAppData = environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.isEmpty) {
        throw StateError('LOCALAPPDATA is not set');
      }
      return Directory('$localAppData\\Wayfork');
    }
    final home = environment['HOME'];
    if (home == null || home.isEmpty) throw StateError('HOME is not set');
    return Platform.isMacOS
        ? Directory('$home/Library/Application Support/Wayfork')
        : Directory('$home/.local/share/wayfork');
  }

  Future<StoreLoadResult> load() async {
    if (!await file.exists()) return StoreLoadResult(store: Store.empty);
    final bytes = await file.readAsBytes();
    try {
      return StoreLoadResult(store: StoreCodec.decode(utf8.decode(bytes)));
    } on StoreCodecException catch (error) {
      if (error.kind == StoreCodecError.newerSchema) {
        throw StoreRepositoryException.newerSchema(
          found: error.found!,
          supported: error.supported!,
        );
      }
      return _moveCorruptAside();
    } on Object {
      return _moveCorruptAside();
    }
  }

  void save(Store store) {
    _pending = store;
    _timer?.cancel();
    _timer = Timer(debounce, () {
      unawaited(flush().catchError((Object _) {}));
    });
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final store = _pending;
    if (store == null) return;
    await write(store);
  }

  Future<void> write(Store store) async {
    await directory.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsString(StoreCodec.encode(store), flush: true);
    await temporary.rename(file.path);
    if (_pending == store) _pending = null;
  }

  Future<StoreLoadResult> _moveCorruptAside() async {
    final backup = File('${file.path}.corrupt-${_timestamp(DateTime.now())}');
    if (await backup.exists()) await backup.delete();
    await file.rename(backup.path);
    return StoreLoadResult(store: Store.empty, corruptBackup: backup);
  }

  static String _timestamp(DateTime date) {
    final utc = date.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    String four(int value) => value.toString().padLeft(4, '0');
    return '${four(utc.year)}${two(utc.month)}${two(utc.day)}-'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}';
  }
}

String _join(String directory, String name) {
  final separator = Platform.isWindows ? '\\' : '/';
  return directory.endsWith(separator)
      ? '$directory$name'
      : '$directory$separator$name';
}
