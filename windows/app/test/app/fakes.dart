import 'dart:async';
import 'dart:io';

import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/launch_at_login.dart';
import 'package:wayfork/app/services/log_center.dart';
import 'package:wayfork/app/services/notifier.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/service_client.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/plan/system_dns.dart';
import 'package:wayfork/core/secrets/secret_store.dart';
import 'package:wayfork/core/store/store_repository.dart';

import '../core/app/sample_store.dart';
import '../core/ipc/fake_service.dart';

/// In-memory `store.json`.
final class FakeStoreStorage implements StoreStorage {
  FakeStoreStorage({Store? store, this.corruptBackup, this.loadError})
    : stored = store;

  Store? stored;
  File? corruptBackup;

  /// Thrown by [load] when set.
  Object? loadError;
  final saved = <Store>[];
  int flushes = 0;

  @override
  Future<StoreLoadResult> load() async {
    final error = loadError;
    if (error != null) throw error;
    return StoreLoadResult(
      store: stored ?? Store.empty,
      corruptBackup: corruptBackup,
    );
  }

  @override
  void save(Store store) {
    stored = store;
    saved.add(store);
  }

  @override
  Future<void> flush() async {
    flushes += 1;
  }
}

typedef Notification = ({String id, String title, String body});

final class RecordingNotifier implements Notifier {
  final posts = <Notification>[];

  @override
  Future<void> post({
    required String id,
    required String title,
    required String body,
  }) async {
    posts.add((id: id, title: title, body: body));
  }
}

/// A secret store whose reads or writes can be made to fail.
final class FlakySecretStore implements SecretStore {
  FlakySecretStore(this.inner);

  final SecretStore inner;
  Object? writeError;
  Object? readError;

  @override
  Future<String?> read(SecretKey key) async {
    final error = readError;
    if (error != null) throw error;
    return inner.read(key);
  }

  @override
  Future<void> write(String value, SecretKey key) async {
    final error = writeError;
    if (error != null) throw error;
    return inner.write(value, key);
  }

  @override
  Future<void> delete(SecretKey key) => inner.delete(key);

  @override
  Future<List<SecretKey>> allKeys() => inner.allKeys();
}

const sampleOpenVPNConfig = 'client\nremote vpn.example.com 1194 udp\n';
const sampleVLESSUUID = '00000000-0000-4000-8000-0000000000aa';

/// An [AppModel] over the fakes with short timings. `sample` is the
/// three-tunnel store; Work and Home get their secrets, Lab stays without.
final class Harness {
  Harness({
    Store? store,
    Settings? settings,
    this._seedSecrets = true,
    Duration trafficStaleAfter = const Duration(milliseconds: 60),

    /// Zero by default so a test that makes the service unavailable sees the
    /// steady "not running" state; the grace period has its own tests.
    Duration serviceStartupGrace = Duration.zero,

    /// Where the log centre writes its files; null keeps it in memory.
    Directory? logDirectory,

    /// H2: the waits between automatic re-applies after the engine failed.
    this.recoveryDelays,
  }) : sample = SampleStore(),
       logs = LogCenter(directory: logDirectory, echoToConsole: false) {
    final base = store ?? sample.store;
    storage = FakeStoreStorage(
      store: settings == null ? base : base.copyWith(settings: settings),
    );
    client = ServiceClient(
      connect: service.connect,
      backoff: const ServiceBackoff(
        initial: Duration(milliseconds: 10),
        max: Duration(milliseconds: 40),
      ),
      helloTimeout: const Duration(milliseconds: 500),
    );
    model = AppModel(
      repository: storage,
      secrets: secrets,
      client: client,
      logs: logs,
      notifier: notifier,
      launchAtLogin: launchAtLogin,
      resolveHosts: (hosts) async => {
        for (final host in hosts)
          if (resolvable.contains(host)) host: ['203.0.113.10'],
      },
      systemDns: () => dns,
      localNetworks: () => const [],
      networkChanges: networkChanges.stream,
      installDir: r'C:\Fallback\Wayfork',
      applyDebounce: const Duration(milliseconds: 20),
      startingTimeout: const Duration(milliseconds: 300),
      trafficStaleAfter: trafficStaleAfter,
      pulseInterval: const Duration(hours: 1),
      connectTimeout: const Duration(seconds: 2),
      serviceStartupGrace: serviceStartupGrace,
      recoveryDelays: recoveryDelays,
    );
  }

  final List<Duration>? recoveryDelays;
  final SampleStore sample;
  final bool _seedSecrets;
  final service = FakeService();
  final secrets = FlakySecretStore(InMemorySecretStore());
  final notifier = RecordingNotifier();
  final launchAtLogin = InMemoryLaunchAtLogin();
  final LogCenter logs;
  final networkChanges = StreamController<void>.broadcast();
  final resolvable = <String>{'vpn.example.com'};
  SystemDnsSnapshot dns = SystemDnsSnapshot(
    const ['192.168.1.1', '1.1.1.1'],
    '192.168.1.1',
    networkServers: const ['192.168.1.1', '1.1.1.1'],
  );
  late final FakeStoreStorage storage;
  late final ServiceClient client;
  late final AppModel model;

  /// Seeds the secrets and runs `bootstrap`.
  Future<void> start() async {
    if (_seedSecrets) {
      await secrets.write(
        sampleOpenVPNConfig,
        SecretKey(SecretKind.ovpn, sample.work.id),
      );
      await secrets.writeCredentials(
        const Credentials(username: 'alice', password: 'pw'),
        sample.work.id,
      );
      await secrets.write(
        sampleVLESSUUID,
        SecretKey(SecretKind.uuid, sample.home.id),
      );
    }
    await model.bootstrap();
  }

  /// Bootstraps against an idle service and turns routing on.
  Future<void> startOn() async {
    service.status = RuntimeStatus.stopped;
    await start();
    await model.turnOn();
  }

  /// The app's own log messages so far.
  List<String> get appLog => logs.lines
      .where((line) => line.source == LogCenter.appSource)
      .map((line) => line.message)
      .toList();

  /// Lets the debounce and the fake pipe settle.
  Future<void> settle([Duration delay = const Duration(milliseconds: 100)]) =>
      Future<void>.delayed(delay);

  Future<void> dispose() async {
    await client.stop();
    model.dispose();
    logs.dispose();
    await networkChanges.close();
  }
}

/// Polls until [condition] holds. Real timers, so only for plain `test()`
/// bodies and `WidgetTester.runAsync` — but unlike a fixed delay it does not
/// turn into a flake on a machine that is having a slow minute.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 5),
  String what = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('$what did not hold within $timeout');
    }
    await Future<void>.delayed(step);
  }
}

RuntimeStatus running({String? planHash, Map<String, TunnelState>? tunnels}) =>
    RuntimeStatus(
      engine: EngineState.running(since: fakeSince),
      planHash: planHash,
      tunnels: tunnels ?? const {},
    );
