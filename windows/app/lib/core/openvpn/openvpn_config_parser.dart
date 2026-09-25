import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/openvpn/openvpn_config_lexer.dart';
import 'package:wayfork/core/support/hashing.dart';

export 'openvpn_config_lexer.dart'
    show OpenVPNImportError, OpenVPNImportException;

final class OpenVPNImportResult {
  const OpenVPNImportResult({
    required this.sanitizedConfig,
    required this.meta,
    required this.strippedDirectives,
    required this.credentials,
  });

  /// Exactly what the service later writes to `run/t-<id>.ovpn`.
  final String sanitizedConfig;
  final OpenVPNMeta meta;
  final List<String> strippedDirectives;
  final Credentials? credentials;

  @override
  bool operator ==(Object other) =>
      other is OpenVPNImportResult &&
      sanitizedConfig == other.sanitizedConfig &&
      meta == other.meta &&
      const ListEquality<String>().equals(
        strippedDirectives,
        other.strippedDirectives,
      ) &&
      credentials == other.credentials;
  @override
  int get hashCode => Object.hash(
    sanitizedConfig,
    meta,
    const ListEquality<String>().hash(strippedDirectives),
    credentials,
  );
}

abstract final class OpenVPNConfigParser {
  static OpenVPNImportResult parse(String text, {Directory? baseDirectory}) =>
      parseWith(text, (name) {
        if (baseDirectory == null) return null;
        try {
          final separator = baseDirectory.path.endsWith(Platform.pathSeparator)
              ? ''
              : Platform.pathSeparator;
          return File('${baseDirectory.path}$separator$name').readAsBytesSync();
        } on FileSystemException {
          return null;
        }
      });

  static OpenVPNImportResult parseWith(
    String text,
    Uint8List? Function(String name) readFile,
  ) => _Parser(text, readFile).parse();
}

sealed class _OutputLine {
  const _OutputLine();
}

final class _TextLine extends _OutputLine {
  const _TextLine(this.text);
  final String text;
}

final class _GeneratedKeyDirection extends _OutputLine {
  const _GeneratedKeyDirection(this.direction);
  final String direction;
}

final class _RemoteSpec {
  const _RemoteSpec(this.host, this.port, this.proto);
  final String host;
  final int? port;
  final String? proto;
}

final class _BlockTag {
  const _BlockTag(this.name, this.isClosing);
  final String name;
  final bool isClosing;
}

final class _Parser {
  _Parser(String text, this.readFile)
    : lines = text
          .split('\n')
          .map(
            (line) =>
                line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
          )
          .toList();

  static const inlineFileDirectives = {
    'ca',
    'cert',
    'key',
    'tls-auth',
    'tls-crypt',
    'tls-crypt-v2',
    'dh',
    'pkcs12',
    'crl-verify',
    'extra-certs',
  };

  static const macOSStrippedDirectives = {
    'dev',
    'dev-type',
    'dev-node',
    'route',
    'route-ipv6',
    'redirect-gateway',
    'redirect-private',
    'dhcp-option',
    'route-nopull',
    'pull-filter',
    'block-outside-dns',
    'ifconfig-noexec',
    'route-noexec',
    'route-gateway',
    'route-metric',
    'daemon',
    'up',
    'down',
    'up-restart',
    'up-delay',
    'down-pre',
    'route-up',
    'route-pre-down',
    'ipchange',
    'client-connect',
    'client-disconnect',
    'learn-address',
    'auth-user-pass-verify',
    'tls-verify',
    'tls-export-cert',
    'script-security',
    'plugin',
    'log',
    'log-append',
    'writepid',
    'status',
    'status-version',
    'user',
    'group',
    'chroot',
    'verb',
    'mute',
    'askpass',
    'config',
    'dns-updown',
  };

  /// OpenVPN 2.7 otherwise falls back from ovpn-dco to TAP-Windows6; see
  /// docs/design/08-windows.md, Adapters and spike results.
  static const windowsStrippedDirectives = {
    'comp-lzo',
    'compress',
    'comp-noadapt',
    'allow-compression',
    'windows-driver',
    'ip-win32',
    'dhcp-renew',
    'dhcp-release',
    'register-dns',
    'tap-sleep',
    'route-method',
    'pause-exit',
    'show-net-up',
  };

  final List<String> lines;
  final Uint8List? Function(String name) readFile;
  final List<_OutputLine> output = [];
  final List<_RemoteSpec> remoteSpecs = [];
  int? globalPort;
  String? globalProto;
  bool needsCredentials = false;
  bool encryptedKeyFound = false;
  bool pkcs12Found = false;
  bool askpassFound = false;
  bool keyDirectionFound = false;
  Credentials? credentials;
  final List<String> stripped = [];
  final Set<String> strippedSet = {};
  final List<String> missingFiles = [];
  final Set<String> missingFileSet = {};
  String? unsupportedReason;

  OpenVPNImportResult parse() {
    _scan(0, lines.length, false);
    if (unsupportedReason != null) {
      throw OpenVPNImportException.unsupported(unsupportedReason!);
    }
    if (missingFiles.isNotEmpty) {
      throw OpenVPNImportException.missingFiles(
        List.unmodifiable(missingFiles),
      );
    }
    if (remoteSpecs.isEmpty) {
      throw const OpenVPNImportException.noRemote();
    }
    final sanitizedConfig = '${_renderOutput().join('\n')}\n';
    final remotes = remoteSpecs
        .map(
          (remote) => Remote(
            host: remote.host,
            port: remote.port ?? globalPort ?? 1194,
            proto: _normalizeProto(remote.proto ?? globalProto ?? 'udp'),
          ),
        )
        .toList();
    final meta = OpenVPNMeta(
      remotes: remotes,
      needsCredentials: needsCredentials,
      needsKeyPassphrase: encryptedKeyFound || (pkcs12Found && askpassFound),
      configHash: Hashing.sha256Hex(sanitizedConfig),
    );
    return OpenVPNImportResult(
      sanitizedConfig: sanitizedConfig,
      meta: meta,
      strippedDirectives: List.unmodifiable(stripped),
      credentials: credentials,
    );
  }

  void _scan(int start, int end, bool insideConnection) {
    var index = start;
    while (index < end) {
      final lineNumber = index + 1;
      final trimmed = lines[index].trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith(';')) {
        index++;
        continue;
      }
      final tag = _blockTag(trimmed);
      if (tag != null) {
        if (tag.isClosing) {
          throw OpenVPNImportException.malformed(
            lineNumber,
            'unexpected closing block </${tag.name}>',
          );
        }
        final closingIndex = _findClosingTag(tag.name, index, end);
        if (closingIndex == null) {
          throw OpenVPNImportException.malformed(
            lineNumber,
            'unterminated inline block <${tag.name}>',
          );
        }
        if (tag.name.toLowerCase() == 'connection') {
          output.add(_TextLine('<${tag.name}>'));
          _scan(index + 1, closingIndex, true);
          output.add(_TextLine('</${tag.name}>'));
        } else {
          _appendInlineBlock(tag.name, lines.sublist(index + 1, closingIndex));
        }
        index = closingIndex + 1;
        continue;
      }
      final arguments = OpenVPNConfigLexer.tokenize(trimmed, lineNumber);
      if (arguments.isEmpty) {
        index++;
        continue;
      }
      final directiveArgument = arguments.first;
      _processDirective(
        directiveArgument.value.toLowerCase(),
        directiveArgument.value,
        arguments.sublist(1),
        insideConnection,
      );
      index++;
    }
  }

  void _processDirective(
    String directive,
    String originalDirective,
    List<OpenVPNArgument> arguments,
    bool insideConnection,
  ) {
    _recordUnsupportedIfNeeded(directive, arguments);
    if (directive == 'askpass') askpassFound = true;
    if (directive == 'key-direction') keyDirectionFound = true;
    if (_shouldStrip(directive)) {
      _recordStripped(directive);
      return;
    }
    if (directive == 'auth-user-pass') {
      needsCredentials = true;
      if (arguments.isNotEmpty) {
        final fileName = arguments.first.value;
        final data = readFile(fileName);
        if (data == null) {
          _recordMissingFile(fileName);
        } else {
          credentials ??= _credentials(data);
        }
      }
      output.add(const _TextLine('auth-user-pass'));
      return;
    }
    if (inlineFileDirectives.contains(directive) && arguments.isNotEmpty) {
      final fileName = arguments.first.value;
      if (directive == 'crl-verify' &&
          arguments
              .skip(1)
              .any((argument) => argument.value.toLowerCase() == 'dir')) {
        _recordUnsupported('crl-verify dir');
        return;
      }
      final data = readFile(fileName);
      if (data == null) {
        _recordMissingFile(fileName);
        return;
      }
      _appendInlinedFile(directive, data);
      if (directive == 'tls-auth' && arguments.length > 1) {
        output.add(_GeneratedKeyDirection(arguments[1].value));
      }
      return;
    }
    if (directive == 'remote' && arguments.isNotEmpty) {
      int? explicitPort;
      String? explicitProto;
      if (arguments.length > 1 && int.tryParse(arguments[1].value) != null) {
        explicitPort = int.parse(arguments[1].value);
        explicitProto = arguments.length > 2 ? arguments[2].value : null;
      } else {
        explicitProto = arguments.length > 1 ? arguments[1].value : null;
      }
      remoteSpecs.add(
        _RemoteSpec(arguments.first.value, explicitPort, explicitProto),
      );
    } else if (!insideConnection &&
        directive == 'port' &&
        arguments.isNotEmpty) {
      globalPort = int.tryParse(arguments.first.value);
    } else if (!insideConnection &&
        directive == 'proto' &&
        arguments.isNotEmpty) {
      globalProto = arguments.first.value;
    }
    output.add(
      _TextLine(
        OpenVPNConfigLexer.renderDirective(originalDirective, arguments),
      ),
    );
  }

  void _appendInlineBlock(String name, List<String> sourceBody) {
    final normalizedName = name.toLowerCase();
    final body = sourceBody.map(_trimTrailingWhitespace).toList();
    output.add(_TextLine('<$name>'));
    output.addAll(body.map(_TextLine.new));
    output.add(_TextLine('</$name>'));
    if (normalizedName == 'key' &&
        body.any((line) => line.contains('ENCRYPTED'))) {
      encryptedKeyFound = true;
    }
    if (normalizedName == 'pkcs12') pkcs12Found = true;
  }

  void _appendInlinedFile(String directive, Uint8List data) {
    final body = directive == 'pkcs12'
        ? _base64Lines(data)
        : _fileLines(data).map(_trimTrailingWhitespace).toList();
    _appendInlineBlock(directive, body);
  }

  void _recordUnsupportedIfNeeded(
    String directive,
    List<OpenVPNArgument> arguments,
  ) {
    final first = arguments.isEmpty
        ? null
        : arguments.first.value.toLowerCase();
    if (directive == 'dev' && first == 'null') {
      _recordUnsupported('dev null');
    } else if (directive == 'dev' && first != null && _isTapDevice(first)) {
      _recordUnsupported('dev $first');
    } else if (directive == 'dev-type' && first == 'tap') {
      _recordUnsupported('dev-type tap');
    } else if (directive == 'mode' && first == 'server') {
      _recordUnsupported('mode server');
    } else if (directive == 'server') {
      _recordUnsupported('server');
    } else if (directive == 'server-bridge') {
      _recordUnsupported('server-bridge');
    }
  }

  void _recordUnsupported(String reason) => unsupportedReason ??= reason;
  void _recordStripped(String directive) {
    if (strippedSet.add(directive)) stripped.add(directive);
  }

  void _recordMissingFile(String name) {
    if (missingFileSet.add(name)) missingFiles.add(name);
  }

  int? _findClosingTag(String name, int openingIndex, int limit) {
    for (var index = openingIndex + 1; index < limit; index++) {
      final tag = _blockTag(lines[index].trim());
      if (tag != null &&
          tag.isClosing &&
          tag.name.toLowerCase() == name.toLowerCase()) {
        return index;
      }
    }
    return null;
  }

  List<String> _renderOutput() {
    var generatedDirectionUsed = false;
    final result = <String>[];
    for (final line in output) {
      switch (line) {
        case _TextLine(:final text):
          result.add(text);
        case _GeneratedKeyDirection(:final direction):
          if (keyDirectionFound || generatedDirectionUsed) continue;
          generatedDirectionUsed = true;
          result.add(
            'key-direction ${OpenVPNConfigLexer.renderArgument(OpenVPNArgument(direction))}',
          );
      }
    }
    return result;
  }

  static bool _shouldStrip(String directive) =>
      macOSStrippedDirectives.contains(directive) ||
      windowsStrippedDirectives.contains(directive) ||
      directive.startsWith('management');

  static _BlockTag? _blockTag(String line) {
    if (!line.startsWith('<') || !line.endsWith('>') || line.length < 3) {
      return null;
    }
    var contents = line.substring(1, line.length - 1);
    final isClosing = contents.startsWith('/');
    if (isClosing) contents = contents.substring(1);
    if (contents.isEmpty ||
        contents.contains(RegExp(r'\s')) ||
        contents.contains('<') ||
        contents.contains('>') ||
        contents.contains('/')) {
      return null;
    }
    return _BlockTag(contents, isClosing);
  }

  static Credentials? _credentials(Uint8List data) {
    final lines = _fileLines(data);
    if (lines.length < 2) return null;
    return Credentials(username: lines[0].trim(), password: lines[1].trim());
  }

  static List<String> _fileLines(Uint8List data) {
    final lines = utf8
        .decode(data, allowMalformed: true)
        .split('\n')
        .map(
          (line) =>
              line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
        )
        .toList();
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  static List<String> _base64Lines(Uint8List data) {
    final encoded = base64Encode(data);
    return [
      for (var offset = 0; offset < encoded.length; offset += 64)
        encoded.substring(offset, (offset + 64).clamp(0, encoded.length)),
    ];
  }

  static String _normalizeProto(String proto) => switch (proto.toLowerCase()) {
    'udp' || 'udp4' || 'udp6' => 'udp',
    'tcp' ||
    'tcp-client' ||
    'tcp4' ||
    'tcp6' ||
    'tcp4-client' ||
    'tcp6-client' => 'tcp',
    final value => value,
  };

  static bool _isTapDevice(String value) {
    if (!value.startsWith('tap')) return false;
    final unit = value.substring(3);
    return unit.isEmpty ||
        unit.codeUnits.every((code) => code >= 0x30 && code <= 0x39);
  }

  static String _trimTrailingWhitespace(String line) =>
      line.replaceFirst(RegExp(r'\s+$'), '');
}
