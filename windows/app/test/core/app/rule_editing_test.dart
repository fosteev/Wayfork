import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/app/rule_editing.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/rules/rule_pattern_error.dart';

import 'sample_store.dart';

void main() {
  test('quick add normalizes and infers the match', () {
    final sample = SampleStore();
    final store = sample.store;
    final added = QuickAdd.evaluate(
      input: 'https://Shop.Example.ORG/cart',
      target: RuleTargetTunnel(sample.home.id),
      store: store,
    );
    expect(added, isA<QuickAddAdd>());
    final rule = (added as QuickAddAdd).rule;
    expect(rule.pattern, 'shop.example.org');
    expect(rule.match, RuleMatch.suffix);
    expect(rule.tunnelID, sample.home.id);

    final wildcard = QuickAdd.evaluate(
      input: '*.img.example.org',
      target: RuleTargetTunnel(sample.work.id),
      store: store,
    );
    expect((wildcard as QuickAddAdd).rule.match, RuleMatch.wildcard);

    // An existing pattern is re-pointed instead of duplicated.
    final updated = QuickAdd.evaluate(
      input: 'example.com',
      target: RuleTargetTunnel(sample.home.id),
      store: store,
    );
    expect(updated, isA<QuickAddUpdate>());
    final updatedRule = (updated as QuickAddUpdate).rule;
    expect(updatedRule.id, store.rules[0].id);
    expect(updatedRule.tunnelID, sample.home.id);
    expect(QuickAdd.isUpdate(input: 'EXAMPLE.com', store: store), isTrue);
    expect(QuickAdd.isUpdate(input: 'new.example.com', store: store), isFalse);
    expect(QuickAdd.isUpdate(input: '', store: store), isFalse);

    expect(
      QuickAdd.evaluate(
        input: 'not a domain',
        target: RuleTargetTunnel(sample.work.id),
        store: store,
      ),
      const QuickAddOutcome.invalid('Not a valid domain'),
    );
    expect(
      QuickAdd.evaluate(
        input: '',
        target: RuleTargetTunnel(sample.work.id),
        store: store,
      ),
      const QuickAddOutcome.invalid('Enter a domain'),
    );
  });

  test('quick add clipboard candidate', () {
    expect(
      QuickAdd.clipboardCandidate('https://news.example.org/a/b?x=1'),
      'news.example.org',
    );
    expect(QuickAdd.clipboardCandidate('  Example.COM  '), 'example.com');
    expect(QuickAdd.clipboardCandidate('hello world'), isNull);
    expect(QuickAdd.clipboardCandidate('localhost'), isNull);
    expect(QuickAdd.clipboardCandidate('line one\nexample.com'), isNull);
    expect(QuickAdd.clipboardCandidate(null), isNull);
  });

  test('rule editing rejects duplicates within a group', () {
    final sample = SampleStore();
    final store = sample.store;
    expect(
      RuleEditing.normalize(
        'Example.com',
        match: RuleMatch.suffix,
        target: RuleTargetTunnel(sample.work.id),
        store: store,
      ),
      const RuleEditingResult.failure(RuleEditingFailure.duplicate()),
    );
    // Same pattern under another tunnel is legal (flagged as shadowed).
    expect(
      RuleEditing.normalize(
        'example.com',
        match: RuleMatch.suffix,
        target: RuleTargetTunnel(sample.home.id),
        store: store,
      ),
      const RuleEditingResult.success('example.com'),
    );
    // Editing the rule itself is not a duplicate of itself.
    expect(
      RuleEditing.normalize(
        'example.com',
        match: RuleMatch.suffix,
        target: RuleTargetTunnel(sample.work.id),
        store: store,
        excluding: store.rules[0].id,
      ),
      const RuleEditingResult.success('example.com'),
    );
    expect(
      RuleEditing.normalize(
        '*.example.com',
        match: RuleMatch.suffix,
        target: RuleTargetTunnel(sample.work.id),
        store: store,
      ),
      const RuleEditingResult.failure(
        RuleEditingFailure.pattern(RulePatternError.wildcardNotAllowed),
      ),
    );
    expect(
      RuleEditing.message(const RuleEditingFailure.duplicate()),
      'This rule already exists in this group',
    );
    expect(
      RuleEditing.message(
        const RuleEditingFailure.pattern(RulePatternError.wildcardNotAllowed),
      ),
      '`*` only allowed in wildcard rules',
    );
    expect(
      RuleEditing.patternMessage(RulePatternError.notAnApplication),
      'Choose an application (.exe)',
    );
  });

  test('quick add and editing support Direct (F8)', () {
    final sample = SampleStore();
    final store = sample.store;
    final added = QuickAdd.evaluate(
      input: 'bank.example.org',
      target: const RuleTargetDirect(),
      store: store,
    );
    expect((added as QuickAddAdd).rule.target, const RuleTargetDirect());
    // Re-pointing an existing tunnel rule at Direct turns it into an exception.
    final updated = QuickAdd.evaluate(
      input: 'example.com',
      target: const RuleTargetDirect(),
      store: store,
    );
    final updatedRule = (updated as QuickAddUpdate).rule;
    expect(updatedRule.id, store.rules[0].id);
    expect(updatedRule.isException, isTrue);

    final withException = store.copyWith(
      rules: [
        ...store.rules,
        Rule(pattern: 'bank.example.org', target: const RuleTargetDirect()),
      ],
    );
    expect(
      RuleEditing.normalize(
        'bank.example.org',
        match: RuleMatch.suffix,
        target: const RuleTargetDirect(),
        store: withException,
      ),
      const RuleEditingResult.failure(RuleEditingFailure.duplicate()),
    );
    expect(
      RuleEditing.normalize(
        'bank.example.org',
        match: RuleMatch.suffix,
        target: RuleTargetTunnel(sample.work.id),
        store: withException,
      ),
      const RuleEditingResult.success('bank.example.org'),
    );
  });
}
