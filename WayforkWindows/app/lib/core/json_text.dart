import 'dart:convert';

/// JSON rendering compatible with Foundation's sorted JSON output.
abstract final class JsonText {
  static String render(Object? value, {bool pretty = true}) {
    final buffer = StringBuffer();
    _write(buffer, value, pretty: pretty, indent: 0);
    return buffer.toString();
  }

  static void _write(
    StringBuffer buffer,
    Object? value, {
    required bool pretty,
    required int indent,
  }) {
    switch (value) {
      case null:
        buffer.write('null');
      case bool():
        buffer.write(value ? 'true' : 'false');
      case int():
        buffer.write(value);
      case double():
        if (!value.isFinite) {
          throw const FormatException('JSON cannot encode a non-finite number');
        }
        buffer.write(value == value.truncateToDouble() ? value.toInt() : value);
      case String():
        _writeString(buffer, value);
      case List<Object?>():
        _writeList(buffer, value, pretty: pretty, indent: indent);
      case Map<String, Object?>():
        _writeMap(buffer, value, pretty: pretty, indent: indent);
      default:
        throw FormatException('Unsupported JSON value: ${value.runtimeType}');
    }
  }

  static void _writeList(
    StringBuffer buffer,
    List<Object?> values, {
    required bool pretty,
    required int indent,
  }) {
    buffer.write('[');
    if (!pretty) {
      for (var i = 0; i < values.length; i++) {
        if (i != 0) buffer.write(',');
        _write(buffer, values[i], pretty: false, indent: indent);
      }
      buffer.write(']');
      return;
    }

    buffer.write('\n');
    if (values.isEmpty) {
      buffer.write('\n${'  ' * indent}]');
      return;
    }
    for (var i = 0; i < values.length; i++) {
      buffer.write('  ' * (indent + 1));
      _write(buffer, values[i], pretty: true, indent: indent + 1);
      if (i != values.length - 1) buffer.write(',');
      buffer.write('\n');
    }
    buffer.write('${'  ' * indent}]');
  }

  static void _writeMap(
    StringBuffer buffer,
    Map<String, Object?> values, {
    required bool pretty,
    required int indent,
  }) {
    final keys = values.keys.toList()
      ..sort((a, b) {
        final folded = a.toLowerCase().compareTo(b.toLowerCase());
        return folded != 0 ? folded : a.compareTo(b);
      });
    buffer.write('{');
    if (!pretty) {
      for (var i = 0; i < keys.length; i++) {
        if (i != 0) buffer.write(',');
        _writeString(buffer, keys[i]);
        buffer.write(':');
        _write(buffer, values[keys[i]], pretty: false, indent: indent);
      }
      buffer.write('}');
      return;
    }

    buffer.write('\n');
    if (keys.isEmpty) {
      buffer.write('\n${'  ' * indent}}');
      return;
    }
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      buffer.write('  ' * (indent + 1));
      _writeString(buffer, key);
      buffer.write(' : ');
      _write(buffer, values[key], pretty: true, indent: indent + 1);
      if (i != keys.length - 1) buffer.write(',');
      buffer.write('\n');
    }
    buffer.write('${'  ' * indent}}');
  }

  static void _writeString(StringBuffer buffer, String value) {
    buffer.write('"');
    for (final rune in value.runes) {
      switch (rune) {
        case 0x22:
          buffer.write(r'\"');
        case 0x5c:
          buffer.write(r'\\');
        case 0x08:
          buffer.write(r'\b');
        case 0x0c:
          buffer.write(r'\f');
        case 0x0a:
          buffer.write(r'\n');
        case 0x0d:
          buffer.write(r'\r');
        case 0x09:
          buffer.write(r'\t');
        default:
          if (rune < 0x20) {
            buffer.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
          } else {
            buffer.writeCharCode(rune);
          }
      }
    }
    buffer.write('"');
  }
}

abstract final class JsonCoding {
  static String encodePretty(Object? tree) => JsonText.render(tree);

  static String encodeCompact(Object? tree) =>
      JsonText.render(tree, pretty: false);

  static Object? decode(String text) => jsonDecode(text);

  static String encodeDate(DateTime date) {
    final utc = date.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    String four(int value) => value.toString().padLeft(4, '0');
    return '${four(utc.year)}-${two(utc.month)}-${two(utc.day)}T'
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
  }

  static DateTime decodeDate(String text) {
    try {
      return DateTime.parse(text).toUtc();
    } on FormatException catch (error) {
      throw FormatException('Invalid ISO 8601 date: $text', error);
    }
  }
}
