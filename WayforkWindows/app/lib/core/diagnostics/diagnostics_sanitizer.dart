import 'dart:convert';
import 'dart:io';

import 'package:wayfork/core/json_text.dart';

final class SanitizerOptions {
  const SanitizerOptions({this.includeServerAddresses = false});

  final bool includeServerAddresses;

  @override
  bool operator ==(Object other) =>
      other is SanitizerOptions &&
      includeServerAddresses == other.includeServerAddresses;

  @override
  int get hashCode => includeServerAddresses.hashCode;
}

abstract final class DiagnosticsSanitizer {
  static const _secretKeys = {
    'uuid',
    'password',
    'keypassphrase',
    'key_passphrase',
    'realitypublickey',
    'realityshortid',
    'public_key',
    'short_id',
    'private_key',
    'psk',
    'ovpn',
    'credentials',
    'secrets',
  };
  static const _serverKeys = {
    'server',
    'host',
    'server_name',
    'sni',
    'hostname',
    'Host',
  };

  /// Sanitizes any JSON document, including a top-level scalar. Dart maps keep
  /// source order, so one depth-first walk assigns stable server placeholders.
  static String sanitizeJSON(
    String text, {
    SanitizerOptions options = const SanitizerOptions(),
  }) {
    final Object? document;
    try {
      document = jsonDecode(text);
    } on FormatException {
      rethrow;
    }
    final sanitizer = _TreeSanitizer(options);
    return JsonText.render(sanitizer.sanitize(document));
  }

  static bool _isPrivateOrLoopbackIP(String value) {
    final address = InternetAddress.tryParse(value);
    if (address == null) return false;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      return bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          bytes[0] == 127 ||
          (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
    }
    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      final uniqueLocal = bytes[0] & 0xfe == 0xfc;
      final loopback =
          bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
      return uniqueLocal || loopback;
    }
    return false;
  }

  static String _abbreviateUserPath(String value) {
    const macPrefix = '/Users/';
    if (value.startsWith(macPrefix)) {
      final slash = value.indexOf('/', macPrefix.length);
      if (slash > macPrefix.length) return '~/${value.substring(slash + 1)}';
      return value;
    }

    if (value.length < 4 ||
        !_isAsciiLetter(value.codeUnitAt(0)) ||
        value[1] != ':' ||
        !_isSeparator(value[2])) {
      return value;
    }
    final afterDrive = value.substring(3);
    final usersEnd = _indexOfSeparator(afterDrive);
    if (usersEnd == -1 ||
        afterDrive.substring(0, usersEnd).toLowerCase() != 'users') {
      return value;
    }
    final usernameStart = usersEnd + 1;
    final usernameEnd = _indexOfSeparator(afterDrive, usernameStart);
    if (usernameEnd <= usernameStart || usernameEnd == afterDrive.length - 1) {
      return value;
    }
    return r'~\' + afterDrive.substring(usernameEnd + 1).replaceAll('/', r'\');
  }

  static bool _isSeparator(String value) => value == r'\' || value == '/';

  static bool _isAsciiLetter(int code) =>
      (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);

  static int _indexOfSeparator(String value, [int start = 0]) {
    for (var index = start; index < value.length; index++) {
      if (_isSeparator(value[index])) return index;
    }
    return -1;
  }
}

final class _TreeSanitizer {
  _TreeSanitizer(this.options);

  final SanitizerOptions options;
  final Map<String, String> _serverPlaceholders = {};

  Object? sanitize(Object? value, {String? key}) {
    // Redact before descending so server-looking values under secret keys do
    // not consume placeholder numbers.
    if (key != null &&
        DiagnosticsSanitizer._secretKeys.contains(key.toLowerCase())) {
      return '<redacted>';
    }
    if (value is Map<String, Object?>) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key: sanitize(entry.value, key: entry.key),
      };
    }
    if (value is List<Object?>) return value.map(sanitize).toList();
    if (value is! String) return value;
    if (value.contains('-----BEGIN')) return '<redacted>';
    if (!options.includeServerAddresses &&
        key != null &&
        DiagnosticsSanitizer._serverKeys.contains(key) &&
        !DiagnosticsSanitizer._isPrivateOrLoopbackIP(value)) {
      return _serverPlaceholders.putIfAbsent(
        value,
        () => 'server-${_serverPlaceholders.length + 1}',
      );
    }
    return DiagnosticsSanitizer._abbreviateUserPath(value);
  }
}
