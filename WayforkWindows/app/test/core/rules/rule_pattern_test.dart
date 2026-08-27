import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/rules/punycode.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';

void main() {
  test('punycode matches reference vectors', () {
    expect(Punycode.encode('bücher'), 'bcher-kva');
    expect(Punycode.encode('münchen'), 'mnchen-3ya');
    expect(Punycode.encode('пример'), 'e1afmkfd');
    expect(Punycode.encode('рф'), 'p1ai');
    expect(Punycode.encode('日本語'), 'wgv71a119e');
    expect(Punycode.toASCII('ascii'), 'ascii');
    expect(Punycode.toASCII('пример'), 'xn--e1afmkfd');
  });

  test('normalization strips URL parts and case', () {
    expect(
      RulePattern.normalize(
        'HTTPS://User@Example.COM:443/path?q=1#x',
        match: RuleMatch.suffix,
      ),
      'example.com',
    );
    expect(
      RulePattern.normalize('  example.com.  ', match: RuleMatch.exact),
      'example.com',
    );
    expect(
      RulePattern.normalize('api.example.com:8443', match: RuleMatch.exact),
      'api.example.com',
    );
    expect(
      RulePattern.normalize('localhost', match: RuleMatch.exact),
      'localhost',
    );
  });

  test('normalization converts IDNs to punycode', () {
    expect(
      RulePattern.normalize('Пример.РФ', match: RuleMatch.suffix),
      'xn--e1afmkfd.xn--p1ai',
    );
    expect(
      RulePattern.normalize('*.пример.рф', match: RuleMatch.wildcard),
      '*.xn--e1afmkfd.xn--p1ai',
    );
  });

  test('normalization rejects invalid domains', () {
    _expectPatternError('https://', RuleMatch.suffix, RulePatternError.empty);
    _expectPatternError(
      '*.example.com',
      RuleMatch.suffix,
      RulePatternError.wildcardNotAllowed,
    );
    _expectPatternError(
      'example.com',
      RuleMatch.wildcard,
      RulePatternError.wildcardRequired,
    );
    _expectPatternError(
      'ex ample.com',
      RuleMatch.suffix,
      RulePatternError.invalidHostname,
      label: 'ex ample',
    );
    _expectPatternError(
      '-bad.example.com',
      RuleMatch.suffix,
      RulePatternError.invalidHostname,
      label: '-bad',
    );
    _expectPatternError(
      'a..b',
      RuleMatch.suffix,
      RulePatternError.invalidHostname,
      label: '',
    );
    _expectPatternError(
      '1.2.3.4',
      RuleMatch.exact,
      RulePatternError.looksLikeIP,
    );
    _expectPatternError(
      List.filled(26, 'abcdefghij').join('.'),
      RuleMatch.suffix,
      RulePatternError.tooLong,
    );
  });

  test('infer match and domain matching semantics', () {
    expect(RulePattern.inferMatch('example.com'), RuleMatch.suffix);
    expect(RulePattern.inferMatch('*.example.com'), RuleMatch.wildcard);
    expect(
      RulePattern.matches(
        host: 'example.com',
        pattern: 'example.com',
        match: RuleMatch.suffix,
      ),
      isTrue,
    );
    expect(
      RulePattern.matches(
        host: 'a.b.example.com',
        pattern: 'example.com',
        match: RuleMatch.suffix,
      ),
      isTrue,
    );
    expect(
      RulePattern.matches(
        host: 'notexample.com',
        pattern: 'example.com',
        match: RuleMatch.suffix,
      ),
      isFalse,
    );
    expect(
      RulePattern.matches(
        host: 'api.example.com',
        pattern: 'api.example.com',
        match: RuleMatch.exact,
      ),
      isTrue,
    );
    expect(
      RulePattern.matches(
        host: 'v2.api.example.com',
        pattern: 'api.example.com',
        match: RuleMatch.exact,
      ),
      isFalse,
    );
    for (final host in ['a.cdn.example.com', 'a.b.cdn.example.com']) {
      expect(
        RulePattern.matches(
          host: host,
          pattern: '*.cdn.example.com',
          match: RuleMatch.wildcard,
        ),
        isTrue,
      );
    }
    expect(
      RulePattern.matches(
        host: 'cdn.example.com',
        pattern: '*.cdn.example.com',
        match: RuleMatch.wildcard,
      ),
      isFalse,
    );
    expect(
      RulePattern.wildcardRegex('*.cdn.example.com'),
      r'^.+\.cdn\.example\.com$',
    );
  });

  test('macOS application rules normalize bundle paths', () {
    expect(
      RulePattern.normalize(
        ' /Applications/Telegram.app/ ',
        match: RuleMatch.app,
        platform: WayforkPlatform.macOS,
      ),
      '/Applications/Telegram.app',
    );
    expect(
      RulePattern.normalize(
        'file:///Applications/Foo%20Bar.app',
        match: RuleMatch.app,
        platform: WayforkPlatform.macOS,
      ),
      '/Applications/Foo Bar.app',
    );
    expect(
      RulePattern.normalize(
        '/Users/me/Apps/Beta.APP',
        match: RuleMatch.app,
        platform: WayforkPlatform.macOS,
      ),
      '/Users/me/Apps/Beta.APP',
    );
    for (final bad in [
      'Telegram.app',
      '/Applications/Telegram',
      '/Applications/../x.app',
      '.app',
    ]) {
      _expectPatternError(
        bad,
        RuleMatch.app,
        RulePatternError.notAnApplication,
        platform: WayforkPlatform.macOS,
      );
    }
    _expectPatternError(
      '  ',
      RuleMatch.app,
      RulePatternError.empty,
      platform: WayforkPlatform.macOS,
    );
    _expectPatternError(
      '/Applications/Telegram.app',
      RuleMatch.suffix,
      RulePatternError.empty,
    );
    _expectPatternError(
      'telegram.org',
      RuleMatch.app,
      RulePatternError.notAnApplication,
      platform: WayforkPlatform.macOS,
    );
  });

  test('application rules match processes, not hosts', () {
    expect(
      RulePattern.matches(
        host: 'telegram.org',
        pattern: '/Applications/Telegram.app',
        match: RuleMatch.app,
      ),
      isFalse,
    );
    final regex = RulePattern.appPathRegex(
      '/Applications/Foo (Beta).app',
      platform: WayforkPlatform.macOS,
    );
    expect(regex, r'^/Applications/Foo \(Beta\)\.app/');
    final compiled = RegExp(regex);
    expect(
      compiled.hasMatch('/Applications/Foo (Beta).app/Contents/MacOS/Foo'),
      isTrue,
    );
    expect(
      compiled.hasMatch(
        '/Applications/Foo (Beta).app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper',
      ),
      isTrue,
    );
    expect(
      compiled.hasMatch('/Applications/Foo (Beta).app 2/Contents/MacOS/Foo'),
      isFalse,
    );
    expect(
      compiled.hasMatch('/Applications/Foo (Beta)_app/Contents/MacOS/Foo'),
      isFalse,
    );
    expect(
      RulePattern.appName(
        '/Applications/Foo Bar.app',
        platform: WayforkPlatform.macOS,
      ),
      'Foo Bar',
    );
    expect(RulePattern.appName('/x/y', platform: WayforkPlatform.macOS), 'y');
  });

  test('Windows application paths and RE2 regex', () {
    expect(
      RulePattern.normalize(
        r'C:\Program Files\Telegram Desktop\Telegram.exe',
        match: RuleMatch.app,
      ),
      r'C:\Program Files\Telegram Desktop\Telegram.exe',
    );
    expect(
      RulePattern.normalize('file:///C:/Apps/x.exe', match: RuleMatch.app),
      r'C:\Apps\x.exe',
    );
    expect(
      RulePattern.normalize('C:/Apps/x.exe/', match: RuleMatch.app),
      r'C:\Apps\x.exe',
    );
    expect(
      RulePattern.normalize(r'\\nas\apps\tool.EXE', match: RuleMatch.app),
      r'\\nas\apps\tool.EXE',
    );
    for (final bad in [
      'Telegram.exe',
      r'C:\Apps\x.dll',
      r'C:\Apps\..\x.exe',
      'C:\\Apps\\',
    ]) {
      _expectPatternError(
        bad,
        RuleMatch.app,
        RulePatternError.notAnApplication,
      );
    }
    final regex = RulePattern.appPathRegex(r'C:\Program Files\x.exe');
    expect(regex, r'(?i)^C:\\Program Files\\x\.exe$');
    final compiled = RegExp(regex.substring(4), caseSensitive: false);
    expect(compiled.hasMatch(r'c:\program files\X.EXE'), isTrue);
    expect(compiled.hasMatch(r'C:\Program Files\x.exe.bak'), isFalse);
    expect(RulePattern.appName(r'C:\Apps\Tool.EXE'), 'Tool');
  });

  test('IP rules normalize to canonical form', () {
    expect(
      RulePattern.normalize(' 10.8.0.5/24 ', match: RuleMatch.ip),
      '10.8.0.0/24',
    );
    expect(
      RulePattern.normalize('203.0.113.7', match: RuleMatch.ip),
      '203.0.113.7',
    );
    expect(
      RulePattern.normalize('203.0.113.7/32', match: RuleMatch.ip),
      '203.0.113.7',
    );
    expect(
      RulePattern.normalize('http://10.8.0.5:8080/x', match: RuleMatch.ip),
      '10.8.0.5',
    );
    expect(
      RulePattern.normalize('10.8.0.5:22', match: RuleMatch.ip),
      '10.8.0.5',
    );
    _expectPatternError(' ', RuleMatch.ip, RulePatternError.empty);
    for (final bad in ['example.com', '::1', '10.8.0.0/33', '2001:db8::/32']) {
      _expectPatternError(bad, RuleMatch.ip, RulePatternError.invalidIP);
    }
    for (final reserved in [
      '0.0.0.0/0',
      '127.0.0.1',
      '169.254.1.1',
      '224.0.0.1',
      '255.255.255.255',
      '198.18.0.5',
      '198.19.0.0/16',
      '172.19.0.1',
    ]) {
      _expectPatternError(
        reserved,
        RuleMatch.ip,
        RulePatternError.reservedRange,
      );
    }
    expect(
      RulePattern.normalize('172.16.0.0/12', match: RuleMatch.ip),
      '172.16.0.0/12',
    );
    expect(
      RulePattern.normalize('198.0.0.0/8', match: RuleMatch.ip),
      '198.0.0.0/8',
    );
    _expectPatternError(
      '10.8.0.0/24',
      RuleMatch.suffix,
      RulePatternError.looksLikeIP,
    );
    _expectPatternError(
      '203.0.113.7',
      RuleMatch.exact,
      RulePatternError.looksLikeIP,
    );
    _expectPatternError(
      '1234',
      RuleMatch.suffix,
      RulePatternError.invalidHostname,
      label: '1234',
    );
    expect(RulePattern.inferMatch('10.8.0.0/24'), RuleMatch.ip);
    expect(RulePattern.inferMatch('https://203.0.113.7/'), RuleMatch.ip);
    expect(RulePattern.inferMatch('*.10.8.0.0'), RuleMatch.wildcard);
    expect(
      RulePattern.matches(
        host: '10.8.0.5',
        pattern: '10.8.0.0/24',
        match: RuleMatch.ip,
      ),
      isFalse,
    );
  });
}

void _expectPatternError(
  String raw,
  RuleMatch match,
  RulePatternError kind, {
  String? label,
  WayforkPlatform platform = WayforkPlatform.windows,
}) {
  expect(
    () => RulePattern.normalize(raw, match: match, platform: platform),
    throwsA(RulePatternException(kind, label: label)),
    reason: raw,
  );
}
