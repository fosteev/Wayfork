import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/local_proxy.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';

/// Strings of the *Local proxy* row (F17) and the port validation the app
/// applies before a store change.
abstract final class LocalProxyText {
  static String offHint(String exitName) =>
      'Turn on to get a 127.0.0.1 address that sends an app through $exitName '
      'without a rule — for curl, a browser profile, Telegram.';

  static String onHint(String exitName) =>
      'for curl, a browser profile, Telegram — uses $exitName, no rule needed';

  static String portTaken(int port) =>
      'Port $port is taken by another program — pick another';

  /// Inline validation of a typed port: null when it can be stored.
  static String? portProblem(
    String text, {
    required Store store,
    required String excluding,
  }) {
    final port = int.tryParse(text.trim());
    if (port == null || !LocalProxy.isValidPort(port)) {
      return 'Ports 1024–65535';
    }
    final owner = store.localProxyPortOwner(port, excluding: excluding);
    if (owner != null) return 'Port already used by $owner';
    return null;
  }
}

/// What the build knows about its bundled block list (F18): the sidecar next
/// to `block-ads.srs`.
final class BlockListInfo {
  const BlockListInfo({
    required this.isAvailable,
    this.name,
    this.entries,
    this.version,
  });

  factory BlockListInfo.fromSidecar(Map<String, Object?> json) => BlockListInfo(
    isAvailable: true,
    name: json['name'] as String?,
    entries: json['entries'] as int?,
    version: json['version'] as String?,
  );

  static const missing = BlockListInfo(isAvailable: false);

  final bool isAvailable;
  final String? name;
  final int? entries;
  final String? version;
}

/// Strings of the *Blocking* section (docs/design/02-ux.md, "Variant C" ›
/// General).
abstract final class BlockListText {
  /// `Blocked 12 today · list of 56,069 sites · from Wayfork 0.7.0`.
  static String hint({
    required BlockListInfo info,
    required bool isEnabled,
    required int? blockedToday,
    required bool isRunning,
    required bool countingPossible,
    required String appVersion,
  }) {
    if (!info.isAvailable) {
      return 'The block list is missing from this build — reinstall Wayfork';
    }
    final parts = <String>[];
    if (isEnabled && isRunning) {
      parts.add(
        countingPossible
            ? 'Blocked ${blockedToday ?? 0} today'
            : 'Blocked — (counting needs log detail Normal)',
      );
    }
    final entries = info.entries;
    if (entries != null) parts.add('list of ${grouped(entries)} sites');
    parts.add('from Wayfork $appVersion');
    return parts.join(' · ');
  }

  /// `56,069` — English grouping regardless of the locale.
  static String grouped(int number) {
    final digits = number.toString();
    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
      buffer.write(digits[index]);
    }
    return buffer.toString();
  }

  static const exceptionsHint =
      'Sites the list gets wrong — they load as usual';

  /// Validates a *Never block* entry like a suffix rule pattern; throws
  /// `RulePatternException`.
  static String normalizeException(String input) =>
      RulePattern.normalize(input, match: RuleMatch.suffix);
}

/// Strings of the *Can't reach* pane and the flyout line (F19).
abstract final class FailedText {
  /// How far back the flyout line looks.
  static const recentWindow = Duration(minutes: 5);

  /// The reason in the user's words; `exitName` names the tunnel for *‹tunnel›
  /// is down*.
  static String reason(FailureReason reason, {String? exitName}) =>
      switch (reason.kind) {
        FailureKind.noAnswer => 'no answer',
        FailureKind.refused => 'refused',
        FailureKind.reset => 'reset',
        FailureKind.noSuchName => 'no such name',
        FailureKind.blocked => 'blocked by your list',
        FailureKind.tunnelDown => '${exitName ?? 'the tunnel'} is down',
        FailureKind.other => 'failed',
      };

  /// The raw error for the tooltip of *failed*; null for the classified reasons.
  static String? detail(FailureReason reason) =>
      reason.kind == FailureKind.other && reason.detail.isNotEmpty
      ? reason.detail
      : null;

  /// `×14`.
  static String tries(int count) => '×$count';

  /// `12 s ago` / `3 min ago` / `14:02` (older than an hour).
  static String lastSeen(DateTime date, {required DateTime now}) {
    final elapsed = now.difference(date).inSeconds;
    final seconds = elapsed < 0 ? 0 : elapsed;
    if (seconds < 60) return '$seconds s ago';
    if (seconds < 3600) return '${seconds ~/ 60} min ago';
    return clock(date);
  }

  /// `4 sites since 14:31 — click a row to see its log lines`.
  static String header({
    required int count,
    required DateTime? since,
    required bool appsUnknown,
  }) {
    var text = _count(count, 'site');
    if (since != null) text += ' since ${clock(since)}';
    text += appsUnknown
        ? ' — which app needs log detail Normal'
        : ' — click a row to see its log lines';
    return text;
  }

  /// The collapsed strip when nothing failed.
  static String empty({required DateTime? since}) => since == null
      ? 'Every site your apps tried could be reached.'
      : 'Every site your apps tried since ${clock(since)} could be reached.';

  /// `Showing lines for cdn.example.net · 14 tries, all no answer · went direct`.
  static String showing({
    required String host,
    required int tries,
    required String reason,
    required String via,
  }) =>
      'Showing lines for $host · ${tries == 1 ? '1 try' : '$tries tries'}, '
      'all $reason · went $via';

  /// `3 sites can't be reached`.
  static String flyoutLine(int count) =>
      "${_count(count, 'site')} can't be reached";

  static String clock(DateTime date) {
    final local = date.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}

/// Strings of the Connections view (F20).
abstract final class ExitsText {
  static const header = 'Connections by exit';
  static const totalLabel = 'All exits';
  static const blockedLabel = 'Blocked by your list';
  static const notCountedAsFailures = 'not counted as failures';
  static const problemsHint =
      'Connections and the rate need log detail Normal — change it';
  static const footerTitle = 'Connections';

  /// `since 14:31 · click an exit to see what failed through it`.
  static String hint({required DateTime? since}) {
    const tail = 'click an exit to see what failed through it';
    if (since == null) return tail;
    return 'since ${FailedText.clock(since)} · $tail';
  }

  /// `using Home` under a group's name.
  static String using(String memberName) => 'using $memberName';

  /// `no answer · 12 min ago`; null when the exit has not failed (in the
  /// chosen window).
  static String? lastFailure(
    ExitStats stats, {
    required String? exitName,
    required DateTime now,
  }) {
    final reasonValue = stats.lastFailure;
    final at = stats.lastFailedAt;
    if (reasonValue == null || at == null) return null;
    return '${FailedText.reason(reasonValue, exitName: exitName)} · '
        '${FailedText.lastSeen(at, now: now)}';
  }

  /// `0%` / `0.2%` / `100%`.
  static String rate(double value) {
    final percent = value * 100;
    if (percent <= 0) return '0%';
    if (percent >= 100) return '100%';
    return '${percent.toStringAsFixed(1)}%';
  }

  /// Grey ≤ 1 %, amber ≤ 5 %, red above.
  static ExitsRateClass rateClass(double value) {
    if (value > 0.05) return ExitsRateClass.bad;
    if (value > 0.01) return ExitsRateClass.warn;
    return ExitsRateClass.ok;
  }

  /// The collapsed table when nothing has gone through any exit yet.
  static String empty({required DateTime? since}) => since == null
      ? 'No connections yet.'
      : 'No connections since ${FailedText.clock(since)} yet.';
}

enum ExitsRateClass { ok, warn, bad }
