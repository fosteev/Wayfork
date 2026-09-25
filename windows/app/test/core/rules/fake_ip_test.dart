import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/rules/fake_ip.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';

const answer =
    '[\u001b[38;5;116m55455588\u001b[0m 29ms] dns: exchanged A '
    'jira.example.com. 600 IN A 198.18.0.57';

void main() {
  test('the index learns names from sing-box answers', () {
    final index = FakeIPIndex();
    expect(index.ingest(answer), isTrue);
    expect(index.nameFor('198.18.0.57'), 'jira.example.com');
    expect(
      index.ingest('dns: cached A GitLab.Example.com. 12 IN A 198.19.255.254'),
      isTrue,
    );
    expect(index.nameFor('198.19.255.254'), 'gitlab.example.com');
    for (final line in [
      'dns: exchanged A vpn.example.org. 300 IN A 203.0.113.9',
      'dns: exchanged AAAA jira.example.com. 600 IN AAAA 2001:db8::1',
      'outbound/direct[t-1]: outbound connection to 198.18.0.57:443',
    ]) {
      expect(index.ingest(line), isFalse, reason: line);
    }
    expect(index.count, 2);
    expect(index.nameFor('198.18.0.1'), isNull);
  });

  test('only single addresses inside the fake range count', () {
    expect(FakeIPIndex.isFakeIP('198.18.0.118'), isTrue);
    expect(FakeIPIndex.isFakeIP(' 198.19.0.1 '), isTrue);
    expect(FakeIPIndex.isFakeIP('198.18.0.0/24'), isFalse);
    expect(FakeIPIndex.isFakeIP('198.20.0.1'), isFalse);
    expect(FakeIPIndex.isFakeIP('example.com'), isFalse);
  });

  test('sibling wildcard drops the host label only', () {
    expect(
      RulePattern.wildcardForSiblings('gitlab.example.com'),
      '*.example.com',
    );
    expect(
      RulePattern.wildcardForSiblings('a.b.example.com'),
      '*.b.example.com',
    );
    expect(RulePattern.wildcardForSiblings('Example.COM'), 'example.com');
    expect(
      RulePattern.wildcardForSiblings('shop.example.co.uk'),
      '*.example.co.uk',
    );
    expect(RulePattern.wildcardForSiblings('example.co.uk'), 'example.co.uk');
    expect(
      RulePattern.wildcardForSiblings('www.shop.example.co.uk'),
      '*.shop.example.co.uk',
    );
  });

  test('a pasted fake IP becomes the wildcard of its name', () {
    final index = FakeIPIndex()..ingest(answer);
    expect(
      FakeIP.translate('198.18.0.57', index),
      const FakeIPTranslation.pattern('*.example.com', 'jira.example.com'),
    );
    expect(
      FakeIP.translate('198.18.0.58', index),
      const FakeIPTranslation.unknown('198.18.0.58'),
    );
    expect(FakeIP.translate('jira.example.com', index), isNull);
    expect(FakeIP.translate('198.18.0.0/15', index), isNull);
    expect(FakeIP.translate('10.0.0.1', index), isNull);
    const pattern = '*.example.com';
    expect(RulePattern.inferMatch(pattern), RuleMatch.wildcard);
    expect(RulePattern.normalize(pattern, match: RuleMatch.wildcard), pattern);
  });
}
