import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/core/app/global_state.dart';
import 'package:wayfork/core/app/import_export.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/service_client.dart';
import 'package:wayfork/core/ipc/service_connection.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/openvpn/openvpn_config_parser.dart';
import 'package:wayfork/core/plan/system_dns.dart';
import 'package:wayfork/core/rules/rule_validator.dart';
import 'package:wayfork/core/secrets/secret_store.dart';
import 'package:wayfork/core/store/store_repository.dart';
import 'package:wayfork/core/vless/vless_uri_parser.dart';

import '../core/app/sample_store.dart';
import '../core/ipc/fake_service.dart';
import 'fakes.dart';

void main() {
  late Harness h;

  tearDown(() => h.dispose());

  group('bootstrap', () {
    test(
      'loads the store, connects and stays off on an idle service',
      () async {
        h = Harness();
        h.service.status = RuntimeStatus.stopped;
        await h.start();
        expect(h.model.store, h.sample.store);
        expect(h.model.serviceState.phase, ServiceClientPhase.connected);
        expect(h.model.serviceInfo, h.service.info);
        expect(h.model.installDir, h.service.info.installPath);
        expect(h.model.desiredOn, isFalse);
        expect(h.model.globalState, const GlobalState.off());
        expect(h.model.serviceIssue, isNull);
        expect(h.model.missingSecrets, {h.sample.lab.id});
        expect(h.service.applied, isEmpty);
        expect(
          h.service.calls,
          containsAll([
            ServiceMethod.subscribe,
            ServiceMethod.getInfo,
            ServiceMethod.getStatus,
          ]),
        );
        expect(h.appLog, contains(startsWith('service 0.1.0 connected')));
        expect(
          h.model.summary,
          StatusText.summary(
            state: const GlobalState.off(),
            store: h.sample.store,
            missingSecrets: {h.sample.lab.id},
          ),
        );
      },
    );

    test('reattaches to a service that is still routing', () async {
      h = Harness();
      h.service.status = running(planHash: 'previous');
      await h.start();
      expect(h.model.desiredOn, isTrue);
      expect(h.model.globalState, const GlobalState.on());
      expect(h.appLog, contains('reattached to a running service'));
      // No plan was built yet, so nothing is re-applied blindly.
      expect(h.service.applied, isEmpty);
    });

    test('connect on launch applies a plan', () async {
      h = Harness(settings: const Settings(connectOnLaunch: true));
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      expect(h.model.desiredOn, isTrue);
      expect(h.service.applied, hasLength(1));
      final plan = h.service.applied.single;
      expect(h.model.lastPlan, plan);
      // Work carries its config and credentials; Lab has no config and is
      // skipped with a warning; Home is VLESS (no OpenVPN runtime).
      expect(plan.openVPN.map((t) => t.id), [h.sample.work.id]);
      expect(plan.openVPN.single.config, sampleOpenVPNConfig);
      expect(plan.openVPN.single.credentials?.username, 'alice');
      expect(plan.openVPN.single.interface, 'Wayfork-1');
      expect(plan.singBox.config, contains(sampleVLESSUUID));
      expect(
        plan.singBox.config,
        contains(r'C:\\Program Files\\Wayfork\\bin\\openvpn.exe'),
      );
      expect(plan.singBox.config, contains('203.0.113.10'));
      expect(h.appLog, contains('Lab skipped: secret missing'));
      expect(h.appLog, contains(startsWith('apply: plan ')));
      // The service reported `stopped` on subscribe: starting until it runs.
      expect(h.model.globalState, const GlobalState.starting());
      h.service.current.pushStatus(running(planHash: plan.planHash));
      await pumpEventQueue();
      expect(h.model.globalState, const GlobalState.on());
      expect(h.model.transition, isNull);
    });

    test('a newer store schema disables persistence', () async {
      h = Harness();
      h.storage.loadError = const StoreRepositoryException.newerSchema(
        found: 3,
        supported: 2,
      );
      await h.start();
      expect(h.model.persistenceDisabled, isTrue);
      expect(h.model.alerts.single.severity, AlertSeverity.critical);
      expect(h.model.alerts.single.title, 'Settings from a newer Wayfork');
      await h.model.setEnabled(h.sample.work.id, false);
      expect(h.storage.saved, isEmpty);
    });

    test('a reset store is reported with its backup', () async {
      h = Harness();
      h.storage.corruptBackup = File(r'C:\Users\x\store.json.corrupt-1');
      await h.start();
      expect(h.model.alerts.single.title, 'Settings were reset');
      expect(
        h.model.alerts.single.action,
        const AppAction.revealFile(r'C:\Users\x\store.json.corrupt-1'),
      );
      h.model.dismissAlert(h.model.alerts.single);
      expect(h.model.alerts, isEmpty);
    });

    test('mirrors the launch-at-login registration', () async {
      h = Harness();
      h.launchAtLogin.setEnabled(true);
      await h.start();
      await pumpEventQueue();
      expect(h.model.settings.launchAtLogin, isTrue);
      expect(h.storage.saved.last.settings.launchAtLogin, isTrue);
    });
  });

  group('on / off', () {
    test('turn on applies, turn off stops and refreshes the status', () async {
      h = Harness();
      h.service.onStop = (_) => h.service.status = RuntimeStatus.stopped;
      await h.startOn();
      expect(h.model.desiredOn, isTrue);
      expect(h.service.applied, hasLength(1));
      expect(h.model.transition, isA<AppTransitionStarting>());
      h.service.current.pushStatus(
        running(planHash: h.model.lastPlan!.planHash),
      );
      await pumpEventQueue();
      expect(h.model.globalState, const GlobalState.on());

      await h.model.turnOff();
      expect(h.service.calls.last, ServiceMethod.getStatus);
      expect(h.service.calls, contains(ServiceMethod.stop));
      expect(h.model.desiredOn, isFalse);
      expect(h.model.status, RuntimeStatus.stopped);
      expect(h.model.globalState, const GlobalState.off());
      expect(h.model.traffic, isNull);
      expect(
        h.appLog,
        containsAll(['Turn On requested', 'Turn Off requested']),
      );
    });

    test('toggle and repeated turn on are idempotent', () async {
      h = Harness();
      await h.startOn();
      await h.model.turnOn();
      expect(h.service.applied, hasLength(1));
      await h.model.toggle();
      expect(h.model.desiredOn, isFalse);
      await h.model.toggle();
      expect(h.model.desiredOn, isTrue);
      expect(h.service.applied, hasLength(2));
    });

    test('starting gives up after the timeout', () async {
      h = Harness();
      await h.startOn();
      expect(h.model.transition, isA<AppTransitionStarting>());
      await h.settle(const Duration(milliseconds: 500));
      expect(h.model.transition, isNull);
    });

    test(
      'a pipe missing right after launch reads as starting, not broken',
      () async {
        h = Harness(serviceStartupGrace: const Duration(minutes: 3));
        h.service.available = false;
        await h.start();
        expect(h.model.serviceIssue?.kind, ServiceIssueKind.starting);
        expect(h.model.serviceIssue?.needsRepair, isFalse);
        expect(
          h.model.serviceIssue?.hint,
          contains('Waiting for the Wayfork service'),
        );

        // The service comes up late, as an auto-start service does at boot.
        h.service.available = true;
        h.client.retryNow();
        await h.settle();
        expect(h.model.serviceIssue, isNull);
      },
    );

    test('the same connection problem is logged once, not per retry', () async {
      h = Harness();
      h.service.available = false;
      await h.start();
      await h.settle(const Duration(milliseconds: 200));
      expect(
        h.appLog.where((line) => line.contains(r'\\.\pipe\wayfork')).length,
        1,
      );
    });

    test(
      'turn on fails with a repair hint when the service is missing',
      () async {
        h = Harness();
        h.service.available = false;
        await h.start();
        expect(h.model.serviceIssue?.kind, ServiceIssueKind.missing);
        expect(h.model.serviceIssue?.needsRepair, isTrue);
        expect(h.model.summary, contains('Repair the installation'));
        await h.model.turnOn();
        expect(h.model.desiredOn, isFalse);
        expect(h.model.transition, isNull);
        expect(h.model.alerts.single.title, "Can't reach the Wayfork service");
        expect(
          h.model.alerts.single.action,
          const AppAction.repairInstallation(),
        );
        expect(h.appLog, contains(startsWith('Turn On failed')));

        // The service gets installed: the client picks it up on its own.
        h.service.available = true;
        h.client.retryNow();
        await nextPhase(h.client, ServiceClientPhase.connected);
        await pumpEventQueue();
        expect(h.model.serviceIssue, isNull);
        expect(h.model.serviceInfo, isNotNull);
      },
    );

    test('an incompatible service is reported', () async {
      h = Harness();
      h.service.hello = const ServiceHello(
        protocol: 2,
        planVersion: 1,
        version: '9.9.9',
      );
      await h.start();
      final issue = h.model.serviceIssue!;
      expect(issue.kind, ServiceIssueKind.versionMismatch);
      expect(issue.message, contains('9.9.9'));
      expect(issue.needsRepair, isTrue);
      expect(h.appLog, contains(contains('protocol 2')));
    });

    test('reconnect forwards to the service', () async {
      h = Harness();
      h.service.knownTunnelIDs.add(h.sample.work.id);
      await h.startOn();
      await h.model.reconnect(h.sample.work.id);
      await h.model.reconnect(h.sample.lab.id);
      expect(
        h.service.calls.where((c) => c == ServiceMethod.reconnect),
        hasLength(2),
      );
      expect(h.appLog, contains('reconnect requested for Work'));
      expect(
        h.appLog,
        contains('reconnect: tunnel not found: ${h.sample.lab.id}'),
      );
    });
  });

  group('apply pipeline', () {
    test('store changes re-apply once after the debounce', () async {
      h = Harness();
      await h.startOn();
      final first = h.model.lastPlan!;
      await h.model.setRuleEnabled(h.sample.store.rules[2].id, true);
      await h.model.addRule(
        pattern: 'new.example.com',
        match: RuleMatch.suffix,
        target: RuleTargetTunnel(h.sample.home.id),
      );
      expect(h.service.applied, hasLength(1));
      await h.settle();
      expect(h.service.applied, hasLength(2));
      expect(h.service.applied.last.planHash, isNot(first.planHash));
      expect(h.model.lastPlan, h.service.applied.last);
      expect(h.storage.saved.last, h.model.store);
    });

    test('nothing is applied while off', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      await h.model.setEnabled(h.sample.work.id, false);
      await h.settle();
      expect(h.service.applied, isEmpty);
      expect(h.storage.saved, hasLength(1));
    });

    test('secret changes re-apply without a store change', () async {
      h = Harness();
      await h.startOn();
      expect(
        await h.model.setCredentials(
          h.sample.work.id,
          username: 'bob',
          password: 'x',
        ),
        isNull,
      );
      await h.settle();
      expect(h.service.applied, hasLength(2));
      expect(
        h.service.applied.last.openVPN.single.credentials?.username,
        'bob',
      );
      expect(
        await h.model.setKeyPassphrase(h.sample.work.id, 'secret'),
        isNull,
      );
      await h.settle();
      // Work's profile has no encrypted key, so the passphrase stays out of
      // the plan; the change still re-applies.
      expect(h.service.applied, hasLength(3));
      expect(h.service.applied.last.openVPN.single.keyPassphrase, isNull);
      expect(await h.model.keyPassphrase(h.sample.work.id), 'secret');
      expect((await h.model.credentials(h.sample.work.id))?.username, 'bob');
    });

    test('a rejected plan queues an alert', () async {
      h = Harness();
      h.service.applyResult = ApplyResult.failure(
        const DaemonError.configInvalid(output: 'bad line\nmore'),
      );
      await h.startOn();
      final alert = h.model.alerts.single;
      expect(alert.title, 'Routing config rejected');
      expect(alert.message, contains('bad line'));
      expect(alert.action, const AppAction.exportDiagnostics());
      expect(h.appLog, contains('apply rejected: config invalid: bad line'));

      h.service.applyResult = ApplyResult.failure(
        DaemonError.startFailed(logTail: const ['boom']),
      );
      await h.model.setEnabled(h.sample.home.id, false);
      await h.settle();
      expect(
        h.model.alerts.last.action,
        const AppAction.showLogs(source: 'sing-box'),
      );
    });

    test('unreadable secrets abort the apply', () async {
      h = Harness();
      await h.startOn();
      h.secrets.readError = const SecretStoreException(
        kind: SecretStoreError.unprotectFailed,
      );
      await h.model.setEnabled(h.sample.home.id, false);
      await h.settle();
      expect(h.service.applied, hasLength(1));
      expect(h.model.alerts.single.title, 'Secrets error');
    });

    test('system DNS changes re-apply only when they matter', () async {
      // Without the resolver override the system resolvers are routed into
      // the TUN (minus the gateway), so their changes matter.
      h = Harness(settings: const Settings(overrideSystemDNS: false));
      await h.startOn();
      expect(
        h.appLog,
        contains(
          contains('system dns 192.168.1.1 1.1.1.1, gateway 192.168.1.1'),
        ),
      );
      expect(
        h.appLog,
        contains(
          startsWith('system resolver 192.168.1.1 is the default gateway'),
        ),
      );
      h.networkChanges.add(null);
      await h.settle();
      expect(h.service.applied, hasLength(1));
      h.dns = SystemDnsSnapshot(const ['9.9.9.9'], '192.168.1.1');
      h.networkChanges.add(null);
      await waitFor(
        () => h.service.applied.length == 2,
        what: 'the re-apply after the DNS change',
      );
      expect(
        h.appLog,
        contains('system DNS changed: 9.9.9.9 (gateway 192.168.1.1)'),
      );
    });

    test('an unresolvable server is logged', () async {
      h = Harness();
      h.resolvable.clear();
      await h.startOn();
      expect(h.appLog, contains(startsWith('cannot resolve vpn.example.com')));
    });

    test('concurrent apply requests are coalesced', () async {
      h = Harness();
      await h.startOn();
      final a = h.model.applyNow();
      final b = h.model.applyNow();
      final c = h.model.applyNow();
      await Future.wait([a, b, c]);
      expect(h.service.applied, hasLength(3));
    });
  });

  group('reconnect', () {
    test('a restarted idle service gets the plan again', () async {
      h = Harness();
      await h.startOn();
      await h.service.current.drop();
      await nextPhase(h.client, ServiceClientPhase.disconnected);
      expect(h.model.status, isNull);
      expect(h.model.serviceInfo, isNull);
      expect(h.model.desiredOn, isTrue);
      expect(h.model.serviceIssue?.kind, ServiceIssueKind.disconnected);
      expect(h.model.summary, contains('Reconnecting'));
      h.service.status = RuntimeStatus.stopped;
      await nextPhase(h.client, ServiceClientPhase.connected);
      await h.settle();
      expect(h.service.applied, hasLength(2));
      expect(h.appLog, contains('service is idle; applying the current plan'));
      expect(h.appLog, contains(startsWith('service connection lost')));
    });

    test('a service running the current plan is left alone', () async {
      h = Harness();
      await h.startOn();
      h.service.status = running(planHash: h.model.lastPlan!.planHash);
      await h.service.current.drop();
      await nextPhase(h.client, ServiceClientPhase.disconnected);
      await nextPhase(h.client, ServiceClientPhase.connected);
      await h.settle();
      expect(h.service.applied, hasLength(1));
      expect(h.model.globalState, const GlobalState.on());
    });

    test('a service running another plan is re-applied', () async {
      h = Harness();
      await h.startOn();
      h.service.status = running(planHash: 'stale');
      await h.service.current.drop();
      await nextPhase(h.client, ServiceClientPhase.disconnected);
      await nextPhase(h.client, ServiceClientPhase.connected);
      await h.settle();
      expect(h.service.applied, hasLength(2));
      expect(h.appLog, contains(contains('re-applying')));
    });

    test('a lost connection while off is quiet', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      await h.service.current.drop();
      await nextPhase(h.client, ServiceClientPhase.disconnected);
      expect(h.model.serviceIssue?.kind, ServiceIssueKind.disconnected);
      expect(h.model.summary, isNot(contains('Reconnecting')));
      await nextPhase(h.client, ServiceClientPhase.connected);
      await h.settle();
      expect(h.service.applied, isEmpty);
    });
  });

  group('status', () {
    test('permanent tunnel failures notify once', () async {
      h = Harness();
      await h.startOn();
      final failed = running(
        planHash: h.model.lastPlan!.planHash,
        tunnels: {
          h.sample.work.id: const TunnelState.failed(
            reason: 'ovpn.authFailed',
            permanent: true,
          ),
        },
      );
      h.service.current.pushStatus(failed);
      h.service.current.pushStatus(failed);
      await pumpEventQueue();
      expect(h.notifier.posts, hasLength(1));
      expect(h.notifier.posts.single.title, 'Work failed');
      expect(
        h.notifier.posts.single.body,
        StatusText.failureMessage('ovpn.authFailed'),
      );
      expect(h.appLog, contains('tunnel Work failed: ovpn.authFailed'));
      expect(
        h.model.globalState,
        GlobalState.degraded(failingTunnelIDs: [h.sample.work.id]),
      );
      expect(h.model.tunnelState(h.sample.work.id), isA<TunnelStateFailed>());
      expect(h.model.card(h.sample.work).isError, isTrue);
    });

    test('engine failures notify unless notifications are off', () async {
      h = Harness();
      await h.startOn();
      h.service.current.pushStatus(
        RuntimeStatus(
          engine: const EngineState.failed(reason: 'singbox.crashLoop'),
        ),
      );
      await pumpEventQueue();
      expect(h.notifier.posts.single.title, 'Routing engine failed');
      expect(
        h.model.globalState,
        const GlobalState.error(reason: 'singbox.crashLoop'),
      );

      await h.model.updateSettings(
        (s) => s.copyWith(notifyOnTunnelFailure: false),
      );
      // Back up, so the next failure starts a fresh streak and would notify.
      h.service.current.pushStatus(
        running(planHash: h.model.lastPlan!.planHash),
      );
      await pumpEventQueue();
      h.service.current.pushStatus(
        RuntimeStatus(
          engine: const EngineState.failed(reason: 'singbox.startFailed'),
        ),
      );
      await pumpEventQueue();
      expect(h.notifier.posts, hasLength(1));
      expect(h.appLog, contains('routing engine failed: singbox.startFailed'));
    });

    // H2: `failed` is terminal for the service, so the app keeps re-applying.
    test('a failed engine is re-applied until it comes up', () async {
      h = Harness(recoveryDelays: const [Duration(milliseconds: 20)]);
      var attempts = 0;
      h.service.onApply = (plan, connection) {
        attempts += 1;
        if (attempts < 3) {
          h.service.applyResult = ApplyResult.failure(
            DaemonError.startFailed(logTail: const ['utun did not come up']),
          );
          connection.pushStatus(
            RuntimeStatus(
              engine: const EngineState.failed(reason: 'singbox.startFailed'),
            ),
          );
        } else {
          h.service.applyResult = ApplyResult.success;
          connection.pushStatus(running(planHash: plan.planHash));
        }
      };
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      await h.model.turnOn();
      await waitFor(
        () => h.model.status?.engine.isRunning == true,
        what: 'the engine to come back up',
      );
      expect(attempts, 3);
      expect(
        h.appLog,
        contains(contains('routing engine down; re-applying in')),
      );
      // One notification for the whole streak, and only the user's own Turn On
      // got an alert — the two automatic retries stayed quiet.
      expect(h.notifier.posts, hasLength(1));
      expect(h.notifier.posts.single.body, contains('keeps retrying'));
      expect(
        h.model.alerts.where(
          (a) => a.title == 'Routing engine failed to start',
        ),
        hasLength(1),
      );
      // Up again: the streak is over, so a later failure notifies afresh.
      h.service.current.pushStatus(
        RuntimeStatus(
          engine: const EngineState.failed(reason: 'singbox.startFailed'),
        ),
      );
      await pumpEventQueue();
      expect(h.notifier.posts, hasLength(2));
    });

    test('turning off stops the automatic re-applies', () async {
      h = Harness(recoveryDelays: const [Duration(milliseconds: 20)]);
      await h.startOn();
      await h.settle();
      final applies = h.service.applied.length;
      h.service.current.pushStatus(
        RuntimeStatus(
          engine: const EngineState.failed(reason: 'singbox.startFailed'),
        ),
      );
      await pumpEventQueue();
      await h.model.turnOff();
      await h.settle();
      expect(h.service.applied, hasLength(applies));
    });

    test('discovered DNS lands in the store and re-applies', () async {
      h = Harness();
      await h.startOn();
      h.service.current.pushStatus(
        RuntimeStatus(
          engine: EngineState.running(since: fakeSince),
          discoveredDNS: {
            h.sample.work.id: ['10.8.0.1'],
          },
        ),
      );
      await h.settle();
      final work = h.model.store.tunnel(h.sample.work.id)!;
      expect(work.kind.openVPN?.discoveredDNS, ['10.8.0.1']);
      expect(h.model.discoveredDNS(work), ['10.8.0.1']);
      expect(h.appLog, contains('Work pushed DNS 10.8.0.1'));
      expect(h.service.applied, hasLength(2));
    });

    test('resolver override changes are logged', () async {
      h = Harness();
      await h.startOn();
      h.service.current.pushStatus(
        RuntimeStatus(
          engine: EngineState.running(since: fakeSince),
          resolverOverride: const ResolverOverrideState.active(service: 'NRPT'),
        ),
      );
      h.service.current.pushStatus(
        RuntimeStatus(engine: EngineState.running(since: fakeSince)),
      );
      await pumpEventQueue();
      expect(
        h.appLog,
        containsAll([
          'system resolver is Wayfork (172.19.0.2) via NRPT',
          'system resolver restored',
        ]),
      );
    });

    test('the service stopping on its own is logged', () async {
      h = Harness();
      await h.startOn();
      h.service.current.pushStatus(
        running(planHash: h.model.lastPlan!.planHash),
      );
      await pumpEventQueue();
      h.service.current.pushStatus(RuntimeStatus.stopped);
      await pumpEventQueue();
      expect(h.appLog, contains('service reports stopped'));
      expect(h.model.globalState, const GlobalState.off());
      expect(h.model.desiredOn, isTrue);
    });
  });

  group('traffic', () {
    test('samples are kept while running and go stale', () async {
      h = Harness();
      await h.startOn();
      final snapshot = TrafficSnapshot(
        sampledAt: fakeSince,
        interval: 1,
        tunnels: {h.sample.work.id: const TrafficCounters(connections: 3)},
        direct: const TrafficCounters(connections: 2),
      );
      // Not running yet: ignored.
      h.service.current.push(ServiceEvent.trafficChanged, snapshot.toJson());
      await pumpEventQueue();
      expect(h.model.traffic, isNull);

      h.service.current.pushStatus(
        running(planHash: h.model.lastPlan!.planHash),
      );
      h.service.current.push(ServiceEvent.trafficChanged, snapshot.toJson());
      await pumpEventQueue();
      expect(h.model.traffic, snapshot);
      expect(h.model.trafficCounters(h.sample.work)?.connections, 3);
      expect(h.model.directTraffic?.connections, 2);
      await h.settle(const Duration(milliseconds: 150));
      expect(h.model.traffic, isNull);
    });
  });

  group('tunnels', () {
    test('adds an OpenVPN profile and asks for credentials', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      final result = OpenVPNImportResult(
        sanitizedConfig: 'client\nremote a.example.com 1194 udp\n',
        meta: OpenVPNMeta(
          remotes: const [
            Remote(host: 'a.example.com', port: 1194, proto: 'udp'),
          ],
          needsCredentials: true,
          needsKeyPassphrase: false,
          configHash: 'h1',
        ),
        strippedDirectives: const ['comp-lzo'],
        credentials: null,
      );
      expect(await h.model.addOpenVPN(result, name: 'Work'), isNull);
      final added = h.model.store.tunnels.last;
      expect(added.name, 'Work (2)');
      expect(added.slot, 3);
      expect(h.model.expandedTunnelID, added.id);
      expect(h.model.pendingFocus, TunnelField.username);
      expect(h.model.missingSecrets, {h.sample.lab.id});
      expect(
        await h.secrets.read(SecretKey(SecretKind.ovpn, added.id)),
        result.sanitizedConfig,
      );
      expect(
        h.appLog,
        contains('imported OpenVPN tunnel Work (2) (stripped: comp-lzo)'),
      );

      // Replacing keeps the DNS choice.
      await h.model.setDNS(added.id, TunnelDNSCustom(const ['10.0.0.53']));
      expect(
        await h.model.replaceOpenVPNConfig(
          added.id,
          OpenVPNImportResult(
            sanitizedConfig: 'client\nremote b.example.com 443 tcp\n',
            meta: OpenVPNMeta(
              remotes: const [
                Remote(host: 'b.example.com', port: 443, proto: 'tcp'),
              ],
              needsCredentials: false,
              needsKeyPassphrase: true,
              configHash: 'h2',
            ),
            strippedDirectives: const [],
            credentials: const Credentials(username: 'u', password: 'p'),
          ),
        ),
        isNull,
      );
      final replaced = h.model.store.tunnel(added.id)!.kind.openVPN!;
      expect(replaced.configHash, 'h2');
      expect(replaced.dns, TunnelDNSCustom(const ['10.0.0.53']));
      expect((await h.model.credentials(added.id))?.username, 'u');
    });

    test('secret store failures are reported', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      h.secrets.writeError = const SecretStoreException(
        kind: SecretStoreError.dpapi,
        status: 5,
      );
      final message = await h.model.addVLESS(
        VLESSImportResult(
          uuid: sampleVLESSUUID,
          meta: h.sample.home.kind.vless!,
          name: 'X',
        ),
      );
      expect(message, startsWith('Cannot store the UUID'));
      expect(h.model.alerts.single.title, 'Secrets error');
      expect(h.model.store.tunnels, hasLength(3));
    });

    test('adds VLESS and exposes the URI', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      final meta = h.sample.home.kind.vless!;
      expect(
        await h.model.addVLESS(
          VLESSImportResult(uuid: sampleVLESSUUID, meta: meta, name: ''),
        ),
        isNull,
      );
      final added = h.model.store.tunnels.last;
      expect(added.name, meta.server);
      expect(
        await h.model.vlessURI(added),
        startsWith('vless://$sampleVLESSUUID@'),
      );
      expect(h.model.maskedVLESSURI(added), contains('••••••••@'));
      expect(await h.model.vlessURI(h.sample.work), isNull);

      expect(
        await h.model.replaceVLESS(
          added.id,
          VLESSImportResult(
            uuid: '00000000-0000-4000-8000-0000000000bb',
            meta: meta,
            name: 'n',
          ),
        ),
        isNull,
      );
      expect(
        await h.secrets.read(SecretKey(SecretKind.uuid, added.id)),
        '00000000-0000-4000-8000-0000000000bb',
      );
    });

    test('renames with validation', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      final id = h.sample.work.id;
      expect(await h.model.rename(id, '  '), "Name can't be empty");
      expect(await h.model.rename(id, 'x' * 41), contains('limited to 40'));
      expect(
        await h.model.rename(id, 'home'),
        'Another tunnel is already called home',
      );
      expect(await h.model.rename(id, ' Office '), isNull);
      expect(h.model.store.tunnel(id)!.name, 'Office');
      expect(h.model.uniqueName('Office'), 'Office (2)');
      expect(h.model.uniqueName(''), 'Tunnel');
      expect(h.model.uniqueName('a' * 50).length, 40);
    });

    test('deletes a tunnel with its rules, secrets and default', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      final id = h.sample.work.id;
      await h.model.setDefaultTunnel(id);
      expect(h.model.isDefaultTunnel(id), isTrue);
      expect(h.model.effectiveDefaultTunnel?.id, id);
      expect(h.model.deleteTunnelMessage(id), contains('and its 3 rules'));
      expect(
        h.model.deleteTunnelMessage(h.sample.lab.id),
        contains('its 1 rule?'),
      );
      h.model.expandedTunnelID = id;
      await h.model.deleteTunnel(id);
      expect(h.model.store.tunnel(id), isNull);
      expect(h.model.store.rulesForTunnel(id), isEmpty);
      expect(h.model.store.rules, hasLength(3));
      expect(h.model.store.defaultTunnelID, isNull);
      expect(h.model.expandedTunnelID, isNull);
      expect(await h.secrets.allKeys(), hasLength(1));
      expect(
        h.appLog,
        containsAll(['default tunnel: Work', 'deleted tunnel Work']),
      );
    });

    test('refuses the 33rd tunnel', () async {
      final tunnels = [
        for (var slot = 0; slot < Tunnel.maxSlots; slot++)
          vlessTunnel('T$slot', slot: slot),
      ];
      h = Harness(store: Store(tunnels: tunnels), seedSecrets: false);
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      final message = await h.model.addVLESS(
        VLESSImportResult(
          uuid: sampleVLESSUUID,
          meta: tunnels.first.kind.vless!,
          name: 'x',
        ),
      );
      expect(message, contains('up to 32 tunnels'));
      expect(h.model.alerts.single.title, 'Tunnel limit reached');
    });

    test('default tunnel hints', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      expect(h.model.directGroupHint, startsWith('Overrides tunnel rules'));
      await h.model.setDefaultTunnel(h.sample.lab.id);
      expect(h.model.defaultTunnelIssue, DefaultTunnelIssue.missingSecret);
      expect(h.model.defaultTunnelHint(h.sample.lab).isWarning, isTrue);
      expect(h.model.effectiveDefaultTunnel, isNull);
      await h.model.setDefaultTunnel(h.sample.home.id);
      expect(h.model.directGroupHint, contains('through Home'));
      expect(h.model.defaultTunnelHint(h.sample.home).isWarning, isFalse);
      expect(
        h.model.defaultTunnelHint(h.sample.work).text,
        startsWith('Domains without a rule'),
      );
      await h.model.setEnabled(h.sample.home.id, false);
      expect(h.model.defaultTunnelIssue, DefaultTunnelIssue.disabled);
      await h.model.setDefaultTunnel(null);
      expect(h.appLog.last, 'default tunnel cleared');
    });
  });

  group('rules', () {
    test('quick add appends or updates', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      final home = RuleTargetTunnel(h.sample.home.id);
      expect(
        await h.model.quickAdd(
          input: 'https://New.Example.org/x',
          target: home,
        ),
        isNull,
      );
      expect(h.model.store.rules.last.pattern, 'new.example.org');
      expect(h.model.store.rules.last.target, home);
      expect(h.model.quickAddTarget, home);
      // The same name moves to another target instead of duplicating.
      expect(
        await h.model.quickAdd(
          input: 'new.example.org',
          target: const RuleTargetDirect(),
        ),
        isNull,
      );
      expect(
        h.model.store.rules.where((r) => r.pattern == 'new.example.org'),
        hasLength(1),
      );
      expect(h.model.store.rules.last.target, const RuleTargetDirect());
      expect(
        await h.model.quickAdd(input: 'not a host!', target: home),
        isNotNull,
      );
      expect(h.appLog, contains('rule added: new.example.org → Home'));
      expect(h.appLog, contains('rule updated: new.example.org → Direct'));
    });

    test('add, update, move and remove within groups', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      final work = RuleTargetTunnel(h.sample.work.id);
      final home = RuleTargetTunnel(h.sample.home.id);
      expect(
        await h.model.addRule(
          pattern: 'x.example.com',
          match: RuleMatch.exact,
          target: work,
        ),
        isNull,
      );
      // Appended right after Work's last rule, before Home's group.
      expect(h.model.store.rules[3].pattern, 'x.example.com');
      expect(h.model.store.rules[3].target, work);
      expect(
        await h.model.addRule(
          pattern: 'x.example.com',
          match: RuleMatch.exact,
          target: work,
        ),
        'This rule already exists in this group',
      );
      final id = h.model.store.rules[3].id;
      expect(
        await h.model.updateRule(
          id,
          pattern: '*.y.example.com',
          match: RuleMatch.wildcard,
        ),
        isNull,
      );
      expect(h.model.store.rules[3].pattern, '*.y.example.com');
      expect(h.model.store.rules[3].match, RuleMatch.wildcard);

      await h.model.setRuleNote(id, '  note ');
      expect(h.model.store.rules[3].note, 'note');
      await h.model.setRuleNote(id, ' ');
      expect(h.model.store.rules[3].note, isNull);
      await h.model.setRuleEnabled(id, false);
      expect(h.model.store.rules[3].isEnabled, isFalse);

      // To Home, before its first rule.
      final homeFirst = h.model.store.rulesForTunnel(h.sample.home.id).first.id;
      await h.model.moveRule(id, to: home, before: homeFirst);
      expect(h.model.store.rulesForTunnel(h.sample.home.id).first.id, id);
      // To Direct (an exception), at the end.
      await h.model.moveRule(id, to: const RuleTargetDirect());
      expect(h.model.store.exceptions.single.id, id);
      expect(h.model.ruleCount(const RuleTargetDirect()), 1);
      expect(h.model.ruleCountForTunnel(h.sample.home.id), 2);
      await h.model.removeRule(id);
      expect(h.model.store.rules.where((r) => r.id == id), isEmpty);
      expect(h.model.targetName(const RuleTargetDirect()), 'Direct');
      expect(h.model.targetName(home), 'Home');
      expect(h.model.tunnelName('00000000-0000-4000-8000-0000000000ff'), '?');
    });

    test('a fake IP is translated from the sing-box log', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      h.service.current.push(ServiceEvent.logLines, [
        LogLine(
          ts: fakeSince,
          source: 'sing-box',
          level: LogLevel.info,
          message: 'dns: exchanged A shop.example.net. 1 IN A 198.18.0.7',
        ).toJson(),
      ]);
      await pumpEventQueue();
      expect(h.logs.lines.last.source, 'sing-box');
      final home = RuleTargetTunnel(h.sample.home.id);
      expect(
        await h.model.quickAdd(input: '198.18.0.9', target: home),
        isNotNull,
      );
      expect(await h.model.quickAdd(input: '198.18.0.7', target: home), isNull);
      // The wildcard of the name's siblings, as in the fields.
      expect(h.model.store.rules.last.pattern, '*.example.net');
      expect(h.model.store.rules.last.match, RuleMatch.wildcard);
      expect(
        h.appLog,
        contains(contains('is the fake IP of shop.example.net')),
      );
      expect(
        await h.model.addRule(
          pattern: '198.18.0.7',
          match: RuleMatch.ip,
          target: home,
        ),
        'This rule already exists in this group',
      );
    });
  });

  group('settings', () {
    test(
      'launch at login goes through the backend and reverts on failure',
      () async {
        h = Harness();
        h.service.status = RuntimeStatus.stopped;
        await h.start();
        await h.model.updateSettings((s) => s.copyWith(launchAtLogin: true));
        expect(h.launchAtLogin.isEnabled, isTrue);
        h.launchAtLogin.failure = StateError('registry locked');
        await h.model.updateSettings((s) => s.copyWith(launchAtLogin: false));
        expect(h.model.settings.launchAtLogin, isTrue);
        expect(h.model.alerts.single.title, 'Launch at login');
        expect(h.appLog, contains(contains('registry locked')));
      },
    );

    test('log level and retention follow the settings', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      expect(h.logs.minimumLevel, LogLevel.info);
      await h.model.updateSettings(
        (s) => s.copyWith(logLevel: LogLevel.debug, logRetentionDays: 1),
      );
      expect(h.logs.minimumLevel, LogLevel.debug);
      expect(h.model.settings.logRetentionDays, 1);
    });
  });

  group('import / export', () {
    test('exports with secrets and imports a replacement', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      final document = await h.model.exportDocument(includeSecrets: true);
      expect(document.tunnels, hasLength(3));
      expect(document.tunnels.first.secrets.ovpn, sampleOpenVPNConfig);
      expect(h.appLog, contains('exported 3 tunnels, 6 rules with secrets'));

      final replacement = ExportDocument(
        includesSecrets: true,
        tunnels: [document.tunnels[1]],
        rules: const [],
        settings: const Settings(logLevel: LogLevel.debug),
      );
      expect(h.model.decodeImport(replacement.encode()), isNotNull);
      expect(
        h.model.decodeImport(
          replacement.encode().replaceFirst('wayfork-export', 'other'),
        ),
        isNull,
      );
      expect(h.model.alerts.single.title, 'Not a Wayfork export');

      final outcome = await h.model.performImport(
        replacement,
        ImportMode.replace,
      );
      expect(outcome.tunnelsAdded, 1);
      expect(h.model.store.tunnels.single.name, 'Home');
      expect(h.model.store.settings.logLevel, LogLevel.debug);
      expect(h.logs.minimumLevel, LogLevel.debug);
      expect(h.model.missingSecrets, isEmpty);
      expect(await h.secrets.allKeys(), hasLength(1));
      expect(h.appLog, contains(startsWith('import (replace): +1/~0 tunnels')));
    });
  });

  group('actions', () {
    test('failure actions turn into navigation', () async {
      h = Harness();
      h.service.status = RuntimeStatus.stopped;
      await h.start();
      final actions = <AppAction>[];
      h.model.actions.listen(actions.add);
      h.model.perform(FailureAction.editCredentials, h.sample.work);
      h.model.perform(FailureAction.showLog, h.sample.work);
      h.model.perform(FailureAction.repairInstallation, h.sample.work);
      h.model.perform(FailureAction.replaceConfig, h.sample.home);
      await pumpEventQueue();
      expect(actions, [
        AppAction.openTunnel(h.sample.work.id, focus: TunnelField.username),
        AppAction.showLogs(source: 'openvpn:${h.sample.work.id}'),
        const AppAction.repairInstallation(),
        AppAction.openTunnel(h.sample.home.id, focus: TunnelField.url),
      ]);
      expect(h.model.expandedTunnelID, h.sample.home.id);
      expect(h.model.pendingFocus, TunnelField.url);
      expect(actions.first.title, 'Edit Tunnel');
    });

    test('shutdown stops routing and flushes the store', () async {
      h = Harness();
      await h.startOn();
      await h.model.shutdown();
      expect(h.service.calls, contains(ServiceMethod.stop));
      expect(h.storage.flushes, 1);
      expect(h.client.state.phase, ServiceClientPhase.disconnected);
    });
  });
}
