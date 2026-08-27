enum OpenVPNImportError { missingFiles, unsupported, noRemote, malformed }

final class OpenVPNImportException implements Exception {
  const OpenVPNImportException(
    this.kind, {
    this.files = const [],
    this.reason,
    this.line,
  });

  const OpenVPNImportException.missingFiles(List<String> files)
    : this(OpenVPNImportError.missingFiles, files: files);
  const OpenVPNImportException.unsupported(String reason)
    : this(OpenVPNImportError.unsupported, reason: reason);
  const OpenVPNImportException.noRemote() : this(OpenVPNImportError.noRemote);
  const OpenVPNImportException.malformed(int line, String reason)
    : this(OpenVPNImportError.malformed, line: line, reason: reason);

  final OpenVPNImportError kind;
  final List<String> files;
  final String? reason;
  final int? line;

  @override
  bool operator ==(Object other) =>
      other is OpenVPNImportException &&
      kind == other.kind &&
      _listEquals(files, other.files) &&
      reason == other.reason &&
      line == other.line;

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(files), reason, line);

  @override
  String toString() => switch (kind) {
    OpenVPNImportError.missingFiles => 'Missing files: ${files.join(', ')}',
    OpenVPNImportError.unsupported => 'Unsupported OpenVPN profile: $reason',
    OpenVPNImportError.noRemote => 'OpenVPN profile has no remote',
    OpenVPNImportError.malformed =>
      'Malformed OpenVPN profile at line $line: $reason',
  };
}

final class OpenVPNArgument {
  const OpenVPNArgument(this.value, {this.quote});

  final String value;
  final String? quote;

  @override
  bool operator ==(Object other) =>
      other is OpenVPNArgument && value == other.value && quote == other.quote;
  @override
  int get hashCode => Object.hash(value, quote);
}

abstract final class OpenVPNConfigLexer {
  static final RegExp _whitespace = RegExp(r'^\s$', unicode: true);

  static List<OpenVPNArgument> tokenize(String line, int lineNumber) {
    final result = <OpenVPNArgument>[];
    var value = StringBuffer();
    String? quote;
    String? currentQuote;
    var escaping = false;
    var tokenStarted = false;

    void appendToken() {
      result.add(OpenVPNArgument(value.toString(), quote: quote));
    }

    for (final rune in line.runes) {
      final character = String.fromCharCode(rune);
      if (escaping) {
        value.write(character);
        escaping = false;
        tokenStarted = true;
        continue;
      }
      if (currentQuote == '"' && character == r'\') {
        escaping = true;
        tokenStarted = true;
        continue;
      }
      if (currentQuote != null) {
        if (character == currentQuote) {
          currentQuote = null;
        } else {
          value.write(character);
        }
        tokenStarted = true;
        continue;
      }
      if (character == '"' || character == "'") {
        currentQuote = character;
        quote = quote == null || quote == character ? character : '"';
        tokenStarted = true;
      } else if (_isWhitespace(rune)) {
        if (tokenStarted) {
          appendToken();
          value = StringBuffer();
          quote = null;
          tokenStarted = false;
        }
      } else {
        value.write(character);
        tokenStarted = true;
      }
    }
    if (escaping || currentQuote != null) {
      throw OpenVPNImportException.malformed(lineNumber, 'unbalanced quotes');
    }
    if (tokenStarted) appendToken();
    return result;
  }

  static String renderDirective(
    String directive,
    List<OpenVPNArgument> arguments,
  ) => [directive, ...arguments.map(renderArgument)].join(' ');

  static String renderArgument(OpenVPNArgument argument) {
    if (!argument.value.runes.any(_isWhitespace)) return argument.value;
    if (argument.quote == "'" && !argument.value.contains("'")) {
      return "'${argument.value}'";
    }
    final escaped = argument.value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"');
    return '"$escaped"';
  }

  static bool _isWhitespace(int rune) =>
      _whitespace.hasMatch(String.fromCharCode(rune));
}

bool _listEquals(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
