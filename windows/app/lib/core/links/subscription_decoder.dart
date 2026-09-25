import 'dart:convert';

import 'package:wayfork/core/links/proxy_link_parser.dart';

/// One line of a subscription body after decoding: a link the parser
/// accepted, or a line it did not, with the reason shown next to it. Line
/// numbers are 1-based and count lines of the decoded text.
sealed class SubscriptionEntry {
  const SubscriptionEntry({required this.line});

  final int line;
}

final class SubscriptionLink extends SubscriptionEntry {
  const SubscriptionLink(this.link, {required super.line, required this.uri});

  final ProxyLink link;
  final String uri;
}

final class SubscriptionSkipped extends SubscriptionEntry {
  const SubscriptionSkipped({required super.line, required this.reason});

  final String reason;
}

/// Dart twin of Swift's `SubscriptionDecoder` (docs/design/04-tunnels.md,
/// "Subscriptions"), replaying `fixtures/links/subscription.json`. Pure: the
/// body comes from `SubscriptionFetcher`.
abstract final class SubscriptionDecoder {
  static const schemes = ['vless://', 'ss://', 'trojan://', 'vmess://'];

  /// Plain link lines win; otherwise the whole body is tried as base64 of
  /// such lines. Anything else (YAML, JSON, HTML) is refused. Lines the link
  /// parser refuses are reported per line, never fatal.
  static List<SubscriptionEntry> decode(String body) {
    final text = _normalized(body);
    if (text.isEmpty) {
      throw const ProxyLinkException(
        ProxyLinkError.invalid,
        'subscription is empty',
      );
    }
    final List<String> lines;
    if (_containsLinkLine(text)) {
      lines = text.split('\n');
    } else {
      final decoded = _decodeBase64Body(text);
      if (decoded == null || !_containsLinkLine(decoded)) {
        throw const ProxyLinkException(
          ProxyLinkError.invalid,
          'not a list of links',
        );
      }
      lines = decoded.split('\n');
    }

    final entries = <SubscriptionEntry>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      final number = index + 1;
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      final schemeEnd = line.indexOf('://');
      if (schemeEnd == -1) {
        entries.add(SubscriptionSkipped(line: number, reason: 'not a link'));
        continue;
      }
      final scheme = line.substring(0, schemeEnd + 3).toLowerCase();
      if (!schemes.contains(scheme)) {
        entries.add(
          SubscriptionSkipped(
            line: number,
            reason: 'unsupported scheme $scheme',
          ),
        );
        continue;
      }
      try {
        entries.add(
          SubscriptionLink(
            ProxyLinkParser.parse(line),
            line: number,
            uri: line,
          ),
        );
      } on ProxyLinkException catch (error) {
        entries.add(SubscriptionSkipped(line: number, reason: error.message));
      }
    }
    return entries;
  }

  /// Whether a subscription-looking URL was pasted where a link was expected.
  static bool isURL(String text) {
    final lowercased = text.trim().toLowerCase();
    return lowercased.startsWith('https://') ||
        lowercased.startsWith('http://');
  }

  static String _normalized(String body) =>
      body.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();

  static bool _containsLinkLine(String text) => text.split('\n').any((line) {
    final lowercased = line.trim().toLowerCase();
    return schemes.any(lowercased.startsWith);
  });

  static final _base64Alphabet = RegExp(r'^[A-Za-z0-9+/=]*$');

  /// Standard or URL-safe alphabet, padding optional, whitespace anywhere
  /// (exporters wrap the base64 at 76 columns).
  static String? _decodeBase64Body(String text) {
    final compact = text
        .replaceAll(RegExp(r'\s'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    if (!_base64Alphabet.hasMatch(compact)) return null;
    final unpadded = compact.replaceAll(RegExp(r'=+$'), '');
    if (unpadded.isEmpty || unpadded.length % 4 == 1) return null;
    final padded = unpadded + '=' * ((4 - unpadded.length % 4) % 4);
    try {
      return _normalized(utf8.decode(base64.decode(padded)));
    } on FormatException {
      return null;
    }
  }
}
