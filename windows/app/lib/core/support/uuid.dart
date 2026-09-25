import 'dart:math';

abstract final class Uuid {
  static String? normalize(String text) {
    if (text.length != 36 ||
        text[8] != '-' ||
        text[13] != '-' ||
        text[18] != '-' ||
        text[23] != '-') {
      return null;
    }
    for (var i = 0; i < text.length; i++) {
      if (i == 8 || i == 13 || i == 18 || i == 23) continue;
      final code = text.codeUnitAt(i);
      final isDigit = code >= 0x30 && code <= 0x39;
      final isLowerHex = code >= 0x61 && code <= 0x66;
      final isUpperHex = code >= 0x41 && code <= 0x46;
      if (!isDigit && !isLowerHex && !isUpperHex) return null;
    }
    return text.toLowerCase();
  }

  static bool isValid(String text) => normalize(text) != null;

  static String encode(String text) {
    final normalized = normalize(text);
    if (normalized == null) throw FormatException('Invalid UUID: $text');
    return normalized.toUpperCase();
  }

  static String generate() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
