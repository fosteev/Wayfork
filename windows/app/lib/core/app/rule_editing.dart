import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';

/// Why an edited rule was rejected (docs/design/02-ux.md, `rule.invalid`).
sealed class RuleEditingFailure {
  const RuleEditingFailure();

  const factory RuleEditingFailure.pattern(RulePatternError error) =
      RuleEditingFailurePattern;

  /// Same pattern and match already exists under the same tunnel.
  const factory RuleEditingFailure.duplicate() = RuleEditingFailureDuplicate;
}

final class RuleEditingFailurePattern extends RuleEditingFailure {
  const RuleEditingFailurePattern(this.error);

  final RulePatternError error;

  @override
  bool operator ==(Object other) =>
      other is RuleEditingFailurePattern && error == other.error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => 'pattern($error)';
}

final class RuleEditingFailureDuplicate extends RuleEditingFailure {
  const RuleEditingFailureDuplicate();

  @override
  bool operator ==(Object other) => other is RuleEditingFailureDuplicate;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'duplicate';
}

/// Outcome of [RuleEditing.normalize].
sealed class RuleEditingResult {
  const RuleEditingResult();

  const factory RuleEditingResult.success(String pattern) = RuleEditingSuccess;
  const factory RuleEditingResult.failure(RuleEditingFailure failure) =
      RuleEditingFailed;
}

final class RuleEditingSuccess extends RuleEditingResult {
  const RuleEditingSuccess(this.pattern);

  final String pattern;

  @override
  bool operator ==(Object other) =>
      other is RuleEditingSuccess && pattern == other.pattern;

  @override
  int get hashCode => pattern.hashCode;

  @override
  String toString() => 'success($pattern)';
}

final class RuleEditingFailed extends RuleEditingResult {
  const RuleEditingFailed(this.failure);

  final RuleEditingFailure failure;

  @override
  bool operator ==(Object other) =>
      other is RuleEditingFailed && failure == other.failure;

  @override
  int get hashCode => failure.hashCode;

  @override
  String toString() => 'failure($failure)';
}

/// Validation shared by the tray quick add and the inline rule editor
/// (docs/design/02-ux.md, `rule.invalid`).
abstract final class RuleEditing {
  /// Normalizes [input] for [match] and rejects duplicates within [target]'s
  /// group.
  static RuleEditingResult normalize(
    String input, {
    required RuleMatch match,
    required RuleTarget target,
    required Store store,
    String? excluding,
    WayforkPlatform platform = WayforkPlatform.windows,
  }) {
    final String pattern;
    try {
      pattern = RulePattern.normalize(input, match: match, platform: platform);
    } on RulePatternException catch (error) {
      return RuleEditingResult.failure(RuleEditingFailure.pattern(error.kind));
    }
    final duplicate = store.rules.any(
      (rule) =>
          rule.id != excluding &&
          rule.target == target &&
          rule.pattern == pattern &&
          rule.match == match,
    );
    return duplicate
        ? const RuleEditingResult.failure(RuleEditingFailure.duplicate())
        : RuleEditingResult.success(pattern);
  }

  static String message(RuleEditingFailure failure) => switch (failure) {
    RuleEditingFailureDuplicate() => 'This rule already exists in this group',
    RuleEditingFailurePattern(:final error) => patternMessage(error),
  };

  static String patternMessage(RulePatternError error) => switch (error) {
    RulePatternError.empty => 'Enter a domain',
    RulePatternError.invalidHostname => 'Not a valid domain',
    RulePatternError.tooLong => 'Domain is too long',
    RulePatternError.wildcardNotAllowed => '`*` only allowed in wildcard rules',
    RulePatternError.wildcardRequired => 'Wildcard rules need a `*`',
    RulePatternError.notAnApplication => 'Choose an application (.exe)',
    RulePatternError.invalidIP => 'Not a valid IP address or subnet',
    RulePatternError.looksLikeIP => 'This is an IP address — pick the IP match',
    RulePatternError.reservedRange => 'This range is reserved',
  };
}

/// Outcome of [QuickAdd.evaluate].
sealed class QuickAddOutcome {
  const QuickAddOutcome();

  /// New rule to append.
  const factory QuickAddOutcome.add(Rule rule) = QuickAddAdd;

  /// An existing rule with the same pattern, re-pointed at the chosen target.
  const factory QuickAddOutcome.update(Rule rule) = QuickAddUpdate;
  const factory QuickAddOutcome.invalid(String message) = QuickAddInvalid;
}

final class QuickAddAdd extends QuickAddOutcome {
  const QuickAddAdd(this.rule);

  final Rule rule;

  @override
  bool operator ==(Object other) => other is QuickAddAdd && rule == other.rule;

  @override
  int get hashCode => rule.hashCode;
}

final class QuickAddUpdate extends QuickAddOutcome {
  const QuickAddUpdate(this.rule);

  final Rule rule;

  @override
  bool operator ==(Object other) =>
      other is QuickAddUpdate && rule == other.rule;

  @override
  int get hashCode => rule.hashCode;
}

final class QuickAddInvalid extends QuickAddOutcome {
  const QuickAddInvalid(this.message);

  final String message;

  @override
  bool operator ==(Object other) =>
      other is QuickAddInvalid && message == other.message;

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() => 'invalid($message)';
}

/// "Route `<domain>` via `<tunnel>`" from the tray (docs/design/02-ux.md,
/// "Quick add").
abstract final class QuickAdd {
  /// Match type is `suffix`; a `*` in the input switches to `wildcard`.
  /// A direct target adds an exception (F8).
  static QuickAddOutcome evaluate({
    required String input,
    required RuleTarget target,
    required Store store,
  }) {
    final match = RulePattern.inferMatch(input);
    final String pattern;
    try {
      pattern = RulePattern.normalize(input, match: match);
    } on RulePatternException catch (error) {
      return QuickAddOutcome.invalid(RuleEditing.patternMessage(error.kind));
    }
    for (final existing in store.rules) {
      if (existing.pattern == pattern) {
        return QuickAddOutcome.update(
          existing.copyWith(target: target, match: match, isEnabled: true),
        );
      }
    }
    return QuickAddOutcome.add(
      Rule(pattern: pattern, match: match, target: target),
    );
  }

  /// True when the input names a rule that already exists (the button reads
  /// "Update").
  static bool isUpdate({required String input, required Store store}) {
    final match = RulePattern.inferMatch(input);
    final String pattern;
    try {
      pattern = RulePattern.normalize(input, match: match);
    } on RulePatternException {
      return false;
    }
    return store.rules.any((rule) => rule.pattern == pattern);
  }

  /// The normalized host when the clipboard looks like a URL or a hostname;
  /// null otherwise.
  static String? clipboardCandidate(String? text) {
    if (text == null) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 2048 ||
        trimmed.contains('\n') ||
        trimmed.contains('\r') ||
        trimmed.contains(' ')) {
      return null;
    }
    final lower = trimmed.toLowerCase();
    final looksLikeURL =
        lower.startsWith('http://') || lower.startsWith('https://');
    if (!looksLikeURL && !trimmed.contains('.')) return null;
    final String host;
    try {
      host = RulePattern.normalize(trimmed, match: RuleMatch.suffix);
    } on RulePatternException {
      return null;
    }
    return host.contains('.') ? host : null;
  }
}
