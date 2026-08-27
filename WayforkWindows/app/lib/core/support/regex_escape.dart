/// Escapes RE2 metacharacters so [text] matches literally.
String escapeRegex(String text) {
  final output = StringBuffer();
  for (final code in text.codeUnits) {
    final character = String.fromCharCode(code);
    if (r'\.+*?()|[]{}^$'.contains(character)) output.write(r'\');
    output.write(character);
  }
  return output.toString();
}
