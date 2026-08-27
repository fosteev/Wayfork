import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/rules/punycode.dart';
import 'package:wayfork/core/rules/rule_pattern_error.dart';
import 'package:wayfork/core/singbox/constants.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/support/regex_escape.dart' as support;

export 'package:wayfork/core/rules/rule_pattern_error.dart';

/// Normalization, validation and matching of rule patterns.
abstract final class RulePattern {
  static const maxLength = 253;
  static const maxLabelLength = 63;

  /// What the UI picks while the user is typing.
  static RuleMatch inferMatch(String raw) {
    if (raw.contains('*')) return RuleMatch.wildcard;
    return ipPrefix(fromInput: raw) != null ? RuleMatch.ip : RuleMatch.suffix;
  }

  /// Unroutable ranges plus Wayfork's own fake-IP and TUN ranges.
  static final List<IPv4Prefix> reservedRanges = [
    '0.0.0.0/8',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '224.0.0.0/4',
    '240.0.0.0/4',
    SingBoxConstants.fakeIPv4Range,
    SingBoxConstants.tunAddress,
  ].map(IPv4Prefix.parse).whereType<IPv4Prefix>().toList(growable: false);

  /// Extracts an IPv4 address or subnet after stripping URL parts.
  static IPv4Prefix? ipPrefix({required String fromInput}) {
    final trimmed = fromInput.trim();
    final direct = IPv4Prefix.parse(trimmed);
    if (direct != null) return direct;
    if (trimmed.contains('/') && !trimmed.contains('://')) return null;
    return IPv4Prefix.parse(stripURLParts(trimmed));
  }

  /// Turns user input into its stored form.
  static String normalize(
    String raw, {
    required RuleMatch match,
    WayforkPlatform platform = WayforkPlatform.windows,
  }) {
    if (match == RuleMatch.app) return platform.normalizeAppPath(raw);
    if (match == RuleMatch.ip) return normalizeIP(raw);
    var value = stripURLParts(raw.trim()).toLowerCase();
    // NFC normalisation is not applied (no normaliser in the Dart SDK); UI input
    // on Windows is NFC in practice.
    while (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    if (value.isEmpty) {
      throw const RulePatternException(RulePatternError.empty);
    }

    final hasWildcard = value.contains('*');
    if ((match == RuleMatch.suffix || match == RuleMatch.exact) &&
        hasWildcard) {
      throw const RulePatternException(RulePatternError.wildcardNotAllowed);
    }
    if (match == RuleMatch.wildcard && !hasWildcard) {
      throw const RulePatternException(RulePatternError.wildcardRequired);
    }

    final labels = <String>[];
    for (final original in value.split('.')) {
      final ascii = Punycode.toASCII(original);
      if (ascii == null) {
        throw RulePatternException(
          RulePatternError.invalidHostname,
          label: original,
        );
      }
      _validateLabel(ascii, original);
      labels.add(ascii);
    }
    if (labels.every(_isASCIIDigits)) {
      if (labels.length == 4) {
        throw const RulePatternException(RulePatternError.looksLikeIP);
      }
      throw RulePatternException(
        RulePatternError.invalidHostname,
        label: value,
      );
    }
    final result = labels.join('.');
    if (result.length > maxLength) {
      throw const RulePatternException(RulePatternError.tooLong);
    }
    return result;
  }

  /// Domain matching never applies to application or IP rules.
  static bool matches({
    required String host,
    required String pattern,
    required RuleMatch match,
  }) => switch (match) {
    RuleMatch.exact => host == pattern,
    RuleMatch.suffix => host == pattern || host.endsWith('.$pattern'),
    RuleMatch.wildcard => RegExp(wildcardRegex(pattern)).hasMatch(host),
    RuleMatch.app || RuleMatch.ip => false,
  };

  static String appPathRegex(
    String pattern, {
    WayforkPlatform platform = WayforkPlatform.windows,
  }) => platform.appPathRegex(pattern);

  static String appName(
    String pattern, {
    WayforkPlatform platform = WayforkPlatform.windows,
  }) => platform.appName(pattern);

  /// Returns a wildcard covering the host's siblings without crossing common
  /// public second-level suffixes.
  static String wildcardForSiblings(String host) {
    final labels = host.toLowerCase().split('.');
    if (labels.length < 3) return host.toLowerCase();
    final parent = labels.sublist(1);
    if (parent.length == 2 &&
        parent[1].length == 2 &&
        publicSecondLevelLabels.contains(parent[0])) {
      return host.toLowerCase();
    }
    return '*.${parent.join('.')}';
  }

  static const Set<String> publicSecondLevelLabels = {
    'co',
    'com',
    'net',
    'org',
    'gov',
    'edu',
    'ac',
    'or',
    'ne',
    'gob',
    'mil',
    'info',
  };

  static String wildcardRegex(String pattern) {
    final output = StringBuffer('^');
    for (final code in pattern.codeUnits) {
      final character = String.fromCharCode(code);
      switch (character) {
        case '*':
          output.write('.+');
        case '.':
          output.write(r'\.');
        default:
          output.write(character);
      }
    }
    output.write(r'$');
    return output.toString();
  }

  static String normalizeIP(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const RulePatternException(RulePatternError.empty);
    }
    final prefix = ipPrefix(fromInput: trimmed);
    if (prefix == null) {
      throw const RulePatternException(RulePatternError.invalidIP);
    }
    if (prefix.bits == 0 ||
        reservedRanges.any((range) => range.contains(prefix))) {
      throw const RulePatternException(RulePatternError.reservedRange);
    }
    return prefix.canonical;
  }

  /// Escapes every character that RE2 (and ICU) treats specially.
  static String escapeRegex(String text) => support.escapeRegex(text);

  /// `https://user@host:443/path?q#f` becomes `host`.
  static String stripURLParts(String input) {
    var value = input;
    final scheme = value.indexOf('://');
    if (scheme != -1) value = value.substring(scheme + 3);
    final end = value.indexOf(RegExp(r'[/\?#]'));
    if (end != -1) value = value.substring(0, end);
    final at = value.lastIndexOf('@');
    if (at != -1) value = value.substring(at + 1);
    final colon = value.lastIndexOf(':');
    if (colon != -1 &&
        !value.contains('[') &&
        value
            .substring(colon + 1)
            .codeUnits
            .every((code) => code >= 0x30 && code <= 0x39)) {
      value = value.substring(0, colon);
    }
    return value;
  }

  static void _validateLabel(String label, String original) {
    if (label.isEmpty || label.length > maxLabelLength) {
      throw RulePatternException(
        RulePatternError.invalidHostname,
        label: original,
      );
    }
    for (final code in label.codeUnits) {
      final valid =
          (code >= 0x61 && code <= 0x7a) ||
          (code >= 0x30 && code <= 0x39) ||
          code == 0x2d ||
          code == 0x2a;
      if (!valid) {
        throw RulePatternException(
          RulePatternError.invalidHostname,
          label: original,
        );
      }
    }
    if (label.startsWith('-') || label.endsWith('-')) {
      throw RulePatternException(
        RulePatternError.invalidHostname,
        label: original,
      );
    }
  }

  static bool _isASCIIDigits(String value) {
    if (value.isEmpty) return false;
    return value.codeUnits.every((code) => code >= 0x30 && code <= 0x39);
  }
}
