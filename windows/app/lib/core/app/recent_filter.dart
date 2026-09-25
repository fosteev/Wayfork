import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';

/// Which of the service's recent hosts (F15) the app shows: within the window,
/// not hidden for the session, and not already covered by an active domain
/// rule — the service cannot tell a rule that points at the default tunnel
/// from no rule at all.
abstract final class RecentFilter {
  static List<RecentHost> visible(
    List<RecentHost> hosts, {
    required DateTime sampledAt,
    required Duration window,
    required Set<String> hidden,
    required Store store,
  }) {
    final cutoff = sampledAt.subtract(window);
    final rules = store.rules
        .where(
          (rule) => rule.isEnabled && !rule.isApp && rule.match != RuleMatch.ip,
        )
        .toList();
    return hosts.where((entry) {
      if (entry.lastSeen.isBefore(cutoff) || hidden.contains(entry.host)) {
        return false;
      }
      return !rules.any(
        (rule) => RulePattern.matches(
          host: entry.host,
          pattern: rule.pattern,
          match: rule.match,
        ),
      );
    }).toList();
  }
}
