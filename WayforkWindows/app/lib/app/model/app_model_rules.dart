part of 'app_model.dart';

// Rule management (F2, F8): grouped by target (Direct or a tunnel), ordered
// within the group.

extension AppModelRules on AppModel {
  /// Quick add from the tray flyout. Returns an error message or null.
  Future<String?> quickAdd({
    required String input,
    required RuleTarget target,
  }) async {
    final translated = _translateFakeIP(input, null);
    if (translated.message != null) return translated.message;
    switch (QuickAdd.evaluate(
      input: translated.input,
      target: target,
      store: _store,
    )) {
      case QuickAddInvalid(:final message):
        return message;
      case QuickAddAdd(:final rule):
        await update((store) => store.copyWith(rules: [...store.rules, rule]));
        logs.app(
          LogLevel.info,
          'rule added: ${rule.pattern} → ${targetName(target)}',
        );
      case QuickAddUpdate(:final rule):
        await update(
          (store) => store.copyWith(
            rules: [
              for (final existing in store.rules)
                if (existing.id == rule.id) rule else existing,
            ],
          ),
        );
        logs.app(
          LogLevel.info,
          'rule updated: ${rule.pattern} → ${targetName(target)}',
        );
    }
    quickAddTarget = target;
    _changed();
    return null;
  }

  /// Adds a rule at the end of a group. Returns an error message or null.
  Future<String?> addRule({
    required String pattern,
    required RuleMatch match,
    required RuleTarget target,
  }) async {
    final translated = _translateFakeIP(pattern, match);
    if (translated.message != null) return translated.message;
    switch (RuleEditing.normalize(
      translated.input,
      match: translated.match!,
      target: target,
      store: _store,
    )) {
      case RuleEditingFailed(:final failure):
        return RuleEditing.message(failure);
      case RuleEditingSuccess(:final pattern):
        final rule = Rule(
          pattern: pattern,
          match: translated.match!,
          target: target,
        );
        await update((store) {
          final rules = [...store.rules];
          rules.insert(_endIndexOfGroup(store, target), rule);
          return store.copyWith(rules: rules);
        });
        return null;
    }
  }

  /// Edits pattern and match of an existing rule. Returns an error message
  /// or null.
  Future<String?> updateRule(
    String id, {
    required String pattern,
    required RuleMatch match,
  }) async {
    final translated = _translateFakeIP(pattern, match);
    if (translated.message != null) return translated.message;
    final rule = _store.rules.firstWhereOrNull((rule) => rule.id == id);
    if (rule == null) return null;
    switch (RuleEditing.normalize(
      translated.input,
      match: translated.match!,
      target: rule.target,
      store: _store,
      excluding: id,
    )) {
      case RuleEditingFailed(:final failure):
        return RuleEditing.message(failure);
      case RuleEditingSuccess(:final pattern):
        await _updateRule(
          id,
          (rule) => rule.copyWith(pattern: pattern, match: translated.match),
        );
        return null;
    }
  }

  Future<void> setRuleEnabled(String id, bool enabled) =>
      _updateRule(id, (rule) => rule.copyWith(isEnabled: enabled));

  Future<void> setRuleNote(String id, String note) {
    final trimmed = note.trim();
    return _updateRule(
      id,
      (rule) => rule.copyWith(note: trimmed.isEmpty ? null : trimmed),
    );
  }

  Future<void> removeRule(String id) => update(
    (store) =>
        store.copyWith(rules: store.rules.where((r) => r.id != id).toList()),
  );

  /// Moves a rule inside its group or to another group (a tunnel, or Direct
  /// — which turns it into an exception), placing it before [before]
  /// (another rule) or at the end of the group when [before] is null.
  Future<void> moveRule(
    String id, {
    required RuleTarget to,
    String? before,
  }) async {
    if (id == before) return;
    await update((store) {
      final index = store.rules.indexWhere((rule) => rule.id == id);
      if (index < 0) return store;
      final rules = [...store.rules];
      final rule = rules.removeAt(index).copyWith(target: to);
      final targetIndex = before == null
          ? -1
          : rules.indexWhere((rule) => rule.id == before);
      if (targetIndex >= 0 && rules[targetIndex].target == to) {
        rules.insert(targetIndex, rule);
      } else {
        rules.insert(_endIndexOfGroup(store.copyWith(rules: rules), to), rule);
      }
      return store.copyWith(rules: rules);
    });
  }

  /// A pasted fake IP becomes the wildcard rule of the name behind it
  /// (`FakeIP`); the fields replace it live, this is the safety net for the
  /// submit path. The message is set for a fake IP the logs have not
  /// explained.
  ({String input, RuleMatch? match, String? message}) _translateFakeIP(
    String input,
    RuleMatch? match,
  ) {
    switch (FakeIP.translate(input, fakeIPs)) {
      case null:
        return (input: input, match: match, message: null);
      case FakeIPUnknownTranslation(:final address):
        return (
          input: input,
          match: match,
          message: FakeIP.messageForUnknown(address),
        );
      case FakeIPPatternTranslation(:final pattern, :final name):
        logs.app(
          LogLevel.info,
          '$input is the fake IP of $name: using $pattern',
        );
        return (
          input: pattern,
          match: RulePattern.inferMatch(pattern),
          message: null,
        );
    }
  }

  String tunnelName(String id) => _store.tunnel(id)?.name ?? '?';

  String targetName(RuleTarget target) => switch (target) {
    RuleTargetDirect() => 'Direct',
    RuleTargetTunnel(:final tunnelID) => tunnelName(tunnelID),
  };

  Future<void> _updateRule(String id, Rule Function(Rule rule) mutate) =>
      update(
        (store) => store.copyWith(
          rules: [
            for (final rule in store.rules)
              if (rule.id == id) mutate(rule) else rule,
          ],
        ),
      );

  /// Index right after the last rule of [target]'s group (or `rules.length`).
  static int _endIndexOfGroup(Store store, RuleTarget target) {
    final last = store.rules.lastIndexWhere((rule) => rule.target == target);
    return last < 0 ? store.rules.length : last + 1;
  }
}
