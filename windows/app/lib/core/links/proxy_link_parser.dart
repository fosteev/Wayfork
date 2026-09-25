import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/support/uuid.dart';
import 'package:wayfork/core/vless/vless_uri_parser.dart';

final class ShadowsocksImportResult {
  const ShadowsocksImportResult({
    required this.password,
    required this.meta,
    required this.name,
  });

  final String password;
  final ShadowsocksMeta meta;
  final String name;

  Map<String, Object?> toJson() => {
    'password': password,
    'meta': meta.toJson(),
    'name': name,
  };

  @override
  bool operator ==(Object other) =>
      other is ShadowsocksImportResult &&
      password == other.password &&
      meta == other.meta &&
      name == other.name;

  @override
  int get hashCode => Object.hash(password, meta, name);
}

final class TrojanImportResult {
  const TrojanImportResult({
    required this.password,
    required this.meta,
    required this.name,
  });

  final String password;
  final TrojanMeta meta;
  final String name;

  Map<String, Object?> toJson() => {
    'password': password,
    'meta': meta.toJson(),
    'name': name,
  };

  @override
  bool operator ==(Object other) =>
      other is TrojanImportResult &&
      password == other.password &&
      meta == other.meta &&
      name == other.name;

  @override
  int get hashCode => Object.hash(password, meta, name);
}

final class VMessImportResult {
  const VMessImportResult({
    required this.uuid,
    required this.meta,
    required this.name,
  });

  final String uuid;
  final VMessMeta meta;
  final String name;

  Map<String, Object?> toJson() => {
    'uuid': uuid,
    'meta': meta.toJson(),
    'name': name,
  };

  @override
  bool operator ==(Object other) =>
      other is VMessImportResult &&
      uuid == other.uuid &&
      meta == other.meta &&
      name == other.name;

  @override
  int get hashCode => Object.hash(uuid, meta, name);
}

sealed class ProxyLink {
  const ProxyLink();
}

final class ProxyLinkVLESS extends ProxyLink {
  const ProxyLinkVLESS(this.result);
  final VLESSImportResult result;

  @override
  bool operator ==(Object other) =>
      other is ProxyLinkVLESS && result == other.result;

  @override
  int get hashCode => result.hashCode;
}

final class ProxyLinkShadowsocks extends ProxyLink {
  const ProxyLinkShadowsocks(this.result);
  final ShadowsocksImportResult result;

  @override
  bool operator ==(Object other) =>
      other is ProxyLinkShadowsocks && result == other.result;

  @override
  int get hashCode => result.hashCode;
}

final class ProxyLinkTrojan extends ProxyLink {
  const ProxyLinkTrojan(this.result);
  final TrojanImportResult result;

  @override
  bool operator ==(Object other) =>
      other is ProxyLinkTrojan && result == other.result;

  @override
  int get hashCode => result.hashCode;
}

final class ProxyLinkVMess extends ProxyLink {
  const ProxyLinkVMess(this.result);
  final VMessImportResult result;

  @override
  bool operator ==(Object other) =>
      other is ProxyLinkVMess && result == other.result;

  @override
  int get hashCode => result.hashCode;
}

/// What every link kind has in common, for the sheets and the store.
extension ProxyLinkInfo on ProxyLink {
  /// The tunnel kind this link imports as.
  TunnelKind get tunnelKind => switch (this) {
    ProxyLinkVLESS(:final result) => TunnelKindVLESS(result.meta),
    ProxyLinkShadowsocks(:final result) => TunnelKindShadowsocks(result.meta),
    ProxyLinkTrojan(:final result) => TunnelKindTrojan(result.meta),
    ProxyLinkVMess(:final result) => TunnelKindVMess(result.meta),
  };

  /// The name from the link's fragment (or `ps`), possibly empty.
  String get linkName => switch (this) {
    ProxyLinkVLESS(:final result) => result.name,
    ProxyLinkShadowsocks(:final result) => result.name,
    ProxyLinkTrojan(:final result) => result.name,
    ProxyLinkVMess(:final result) => result.name,
  };

  String get server => switch (this) {
    ProxyLinkVLESS(:final result) => result.meta.server,
    ProxyLinkShadowsocks(:final result) => result.meta.server,
    ProxyLinkTrojan(:final result) => result.meta.server,
    ProxyLinkVMess(:final result) => result.meta.server,
  };

  int get port => switch (this) {
    ProxyLinkVLESS(:final result) => result.meta.port,
    ProxyLinkShadowsocks(:final result) => result.meta.port,
    ProxyLinkTrojan(:final result) => result.meta.port,
    ProxyLinkVMess(:final result) => result.meta.port,
  };
}

enum ProxyLinkError { invalid, unsupported }

final class ProxyLinkException implements Exception {
  const ProxyLinkException(this.kind, this.message);

  final ProxyLinkError kind;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is ProxyLinkException &&
      kind == other.kind &&
      message == other.message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => message;
}

abstract final class ProxyLinkParser {
  static const _shadowsocksMethods = {
    'aes-128-gcm',
    'aes-256-gcm',
    'chacha20-ietf-poly1305',
    'xchacha20-ietf-poly1305',
    '2022-blake3-aes-128-gcm',
    '2022-blake3-aes-256-gcm',
    '2022-blake3-chacha20-poly1305',
    'none',
  };

  static ProxyLink parse(String input) {
    final text = input.trim();
    final schemeEnd = text.indexOf('://');
    if (schemeEnd == -1) _invalid('unsupported link scheme');
    switch (text.substring(0, schemeEnd).toLowerCase()) {
      case 'vless':
        try {
          return ProxyLinkVLESS(VLESSURIParser.parse(text));
        } on VLESSImportException catch (error) {
          throw ProxyLinkException(
            error.kind == VLESSImportError.unsupported
                ? ProxyLinkError.unsupported
                : ProxyLinkError.invalid,
            error.message,
          );
        }
      case 'ss':
        return ProxyLinkShadowsocks(_parseShadowsocks(text, schemeEnd + 3));
      case 'trojan':
        return ProxyLinkTrojan(_parseTrojan(text, schemeEnd + 3));
      case 'vmess':
        return ProxyLinkVMess(_parseVMess(text, schemeEnd + 3));
      default:
        _invalid('unsupported link scheme');
    }
  }

  static String shadowsocksURI(
    ShadowsocksMeta meta,
    String password,
    String name,
  ) {
    final credentials = base64Url
        .encode(utf8.encode('${meta.method}:$password'))
        .replaceAll('=', '');
    return 'ss://$credentials@${_encodedHost(meta.server)}:${meta.port}'
        '#${_percentEncode(name)}';
  }

  static String trojanURI(TrojanMeta meta, String password, String name) {
    final query = <(String, String)>[];
    if (meta.security == TlsSecurity.reality) {
      query.add(('security', 'reality'));
    }
    if (meta.sni != null && meta.sni != meta.server) {
      query.add(('sni', meta.sni!));
    }
    _append(meta.fingerprint, 'fp', query);
    if (meta.alpn.isNotEmpty) query.add(('alpn', meta.alpn.join(',')));
    _append(meta.realityPublicKey, 'pbk', query);
    _append(meta.realityShortID, 'sid', query);
    _appendTransport(meta.transport, query);
    if (meta.allowInsecure) query.add(('allowInsecure', '1'));
    final suffix = query.isEmpty ? '' : '?${_encodedQuery(query)}';
    return 'trojan://${_percentEncode(password)}@${_encodedHost(meta.server)}:'
        '${meta.port}$suffix#${_percentEncode(name)}';
  }

  static String vmessURI(VMessMeta meta, String uuid, String name) {
    final transport = switch (meta.transport) {
      ProxyTransportTCP() => ('tcp', '', ''),
      ProxyTransportWS(:final path, :final host) => ('ws', host ?? '', path),
      ProxyTransportGRPC(:final serviceName) => ('grpc', '', serviceName),
    };
    final json = <String, String>{
      'add': meta.server,
      'aid': '0',
      'alpn': meta.alpn.join(','),
      'fp': meta.fingerprint ?? '',
      'host': transport.$2,
      'id': uuid,
      'net': transport.$1,
      'path': transport.$3,
      'port': '${meta.port}',
      'ps': name,
      'scy': meta.security,
      'sni': meta.sni ?? '',
      'tls': meta.tlsSecurity == TlsSecurity.none
          ? ''
          : meta.tlsSecurity.jsonValue,
      'type': 'none',
      'v': '2',
      if (meta.tlsSecurity == TlsSecurity.reality) ...{
        'pbk': meta.realityPublicKey ?? '',
        'sid': meta.realityShortID ?? '',
      },
      if (meta.allowInsecure) 'allowInsecure': '1',
    };
    return 'vmess://${base64Encode(utf8.encode(jsonEncode(SplayTreeMap.of(json))))}';
  }

  static ShadowsocksImportResult _parseShadowsocks(String text, int bodyStart) {
    final fragmentParts = _splitOnce(text, '#');
    final queryParts = _splitOnce(fragmentParts.$1, '?');
    final query = _parseQuery(queryParts.$2);
    if (query.containsKey('plugin')) {
      _unsupported('SIP003 plugins are not supported');
    }

    final rawBody = queryParts.$1.substring(bodyStart);
    late String methodAndPassword;
    late String endpoint;
    final at = rawBody.indexOf('@');
    if (at != -1) {
      methodAndPassword = _decodeShadowsocksUserinfo(rawBody.substring(0, at));
      endpoint = _trimTrailingSlash(rawBody.substring(at + 1));
    } else {
      final decoded = _decodeBase64Text(rawBody);
      final decodedAt = decoded?.lastIndexOf('@') ?? -1;
      if (decodedAt == -1) _invalid('Shadowsocks userinfo is invalid');
      methodAndPassword = decoded!.substring(0, decodedAt);
      endpoint = decoded.substring(decodedAt + 1);
    }

    final credentials = _splitOnce(methodAndPassword, ':');
    final method = credentials.$1;
    final password = credentials.$2 ?? '';
    if (method.isEmpty || credentials.$2 == null) {
      _invalid('Shadowsocks userinfo must be method:password');
    }
    if (!_shadowsocksMethods.contains(method)) {
      _unsupported('method "$method" is not supported');
    }
    if (password.isEmpty) _invalid('password is missing');
    if (method.startsWith('2022-blake3-')) {
      final byteCount = method == '2022-blake3-aes-128-gcm' ? 16 : 32;
      if (_decodeBase64(password)?.length != byteCount) {
        _invalid(
          'password for "$method" must be base64 encoding of $byteCount bytes',
        );
      }
    }
    final parsedEndpoint = _parseEndpoint(endpoint);
    return ShadowsocksImportResult(
      password: password,
      meta: ShadowsocksMeta(
        server: parsedEndpoint.$1,
        port: parsedEndpoint.$2,
        method: method,
      ),
      name: _parsedName(fragmentParts.$2, parsedEndpoint.$1),
    );
  }

  static TrojanImportResult _parseTrojan(String text, int bodyStart) {
    final fragmentParts = _splitOnce(text, '#');
    final queryParts = _splitOnce(fragmentParts.$1, '?');
    final authority = queryParts.$1.substring(bodyStart);
    final at = authority.indexOf('@');
    if (at == -1) _invalid('password is missing');
    final password = _decode(authority.substring(0, at), 'password');
    if (password.isEmpty) _invalid('password is missing');
    final endpoint = _parseEndpoint(authority.substring(at + 1));
    final query = _parseQuery(queryParts.$2);
    final security = switch (query['security']) {
      null || 'tls' => TlsSecurity.tls,
      'reality' => TlsSecurity.reality,
      'none' => _unsupported('security=none is not supported'),
      _ => _invalid('security must be tls or reality'),
    };
    final headerType = query['headerType'];
    if (headerType != null && headerType.isNotEmpty && headerType != 'none') {
      _unsupported('headerType "$headerType" is not supported yet.');
    }
    final transport = _parseTransport(query);
    if (security == TlsSecurity.reality && (query['pbk'] ?? '').isEmpty) {
      _invalid('REALITY requires pbk');
    }
    return TrojanImportResult(
      password: password,
      meta: TrojanMeta(
        server: endpoint.$1,
        port: endpoint.$2,
        security: security,
        sni: query['sni'] ?? endpoint.$1,
        fingerprint:
            query['fp'] ?? (security == TlsSecurity.reality ? 'chrome' : null),
        alpn: _parseALPN(query['alpn']),
        realityPublicKey: query['pbk'],
        realityShortID: _nonempty(query['sid']),
        transport: transport,
        allowInsecure:
            _isTrue(query['allowInsecure']) || _isTrue(query['insecure']),
      ),
      name: _parsedName(fragmentParts.$2, endpoint.$1),
    );
  }

  static VMessImportResult _parseVMess(String text, int bodyStart) {
    final withoutFragment = _splitOnce(text, '#').$1;
    final body = withoutFragment.substring(bodyStart);
    final decoded = _decodeBase64Text(body);
    Object? object;
    if (decoded != null) {
      try {
        object = jsonDecode(decoded);
      } on FormatException {
        // Report the supported dialect below.
      }
    }
    if (object is! Map<String, Object?>) {
      _unsupported('only the V2RayN vmess:// form is supported');
    }
    final json = object;
    final server = _nonempty(json['add'] as String?);
    if (server == null) _invalid('server is missing');
    if (!_isValidHost(server)) _invalid('host is invalid');
    final port = _integer(json['port'], 'port');
    if (port < 1 || port > 65535) {
      _invalid('port must be between 1 and 65535');
    }
    final rawUUID = _nonempty(json['id'] as String?);
    if (rawUUID == null) _invalid('UUID is missing');
    final uuid = Uuid.normalize(rawUUID);
    if (uuid == null) _invalid('UUID is invalid');
    final alterID = _optionalInteger(json['aid'], 'aid') ?? 0;
    if (alterID != 0) _unsupported('alterId other than 0 is not supported');

    final security =
        _nonempty(json['scy'] as String?) ??
        _nonempty(json['security'] as String?) ??
        'auto';
    if (!const {
      'auto',
      'none',
      'zero',
      'aes-128-gcm',
      'chacha20-poly1305',
    }.contains(security)) {
      _unsupported('security "$security" is not supported');
    }
    final tlsSecurity = switch (json['tls'] as String?) {
      null || '' => TlsSecurity.none,
      'tls' => TlsSecurity.tls,
      'reality' => TlsSecurity.reality,
      _ => _invalid('tls must be empty, tls, or reality'),
    };
    if (tlsSecurity == TlsSecurity.reality &&
        _nonempty(json['pbk'] as String?) == null) {
      _invalid('REALITY requires pbk');
    }
    final headerType = json['type'] as String?;
    if (headerType != null && headerType.isNotEmpty && headerType != 'none') {
      _unsupported('header type "$headerType" is not supported');
    }
    final transport = switch (_nonempty(json['net'] as String?) ?? 'tcp') {
      'tcp' => const ProxyTransportTCP(),
      'ws' => ProxyTransportWS(
        path: _nonempty(json['path'] as String?) ?? '/',
        host: _nonempty(json['host'] as String?),
      ),
      'grpc' => ProxyTransportGRPC(
        serviceName: _nonempty(json['path'] as String?) ?? '',
      ),
      final unsupported => _unsupported(
        'Transport "$unsupported" is not supported yet.',
      ),
    };
    final fingerprint =
        _nonempty(json['fp'] as String?) ??
        (tlsSecurity == TlsSecurity.reality ? 'chrome' : null);
    final rawName = _nonempty((json['ps'] as String?)?.trim()) ?? server;
    final name = String.fromCharCodes(rawName.runes.take(Tunnel.nameMaxLength));
    return VMessImportResult(
      uuid: uuid,
      meta: VMessMeta(
        server: server,
        port: port,
        security: security,
        tlsSecurity: tlsSecurity,
        sni: tlsSecurity == TlsSecurity.none
            ? null
            : _nonempty(json['sni'] as String?) ?? server,
        fingerprint: fingerprint,
        alpn: _parseALPN(json['alpn'] as String?),
        realityPublicKey: _nonempty(json['pbk'] as String?),
        realityShortID: _nonempty(json['sid'] as String?),
        transport: transport,
        allowInsecure:
            _jsonBoolean(json['allowInsecure']) ||
            _jsonBoolean(json['insecure']),
      ),
      name: name,
    );
  }

  static String _decodeShadowsocksUserinfo(String value) {
    final decoded = _decode(value, 'userinfo');
    final base64Text = _decodeBase64Text(decoded);
    return base64Text != null && base64Text.contains(':')
        ? base64Text
        : decoded;
  }

  static ProxyTransport _parseTransport(Map<String, String> query) =>
      switch (query['type']) {
        null || 'tcp' => const ProxyTransportTCP(),
        'ws' => ProxyTransportWS(
          path: query['path'] ?? '/',
          host: query['host'],
        ),
        'grpc' => ProxyTransportGRPC(serviceName: query['serviceName'] ?? ''),
        final type => _unsupported('Transport "$type" is not supported yet.'),
      };

  static void _appendTransport(
    ProxyTransport transport,
    List<(String, String)> query,
  ) {
    switch (transport) {
      case ProxyTransportTCP():
        break;
      case ProxyTransportWS(:final path, :final host):
        query.add(('type', 'ws'));
        if (path != '/') query.add(('path', path));
        _append(host, 'host', query);
      case ProxyTransportGRPC(:final serviceName):
        query.add(('type', 'grpc'));
        if (serviceName.isNotEmpty) query.add(('serviceName', serviceName));
    }
  }

  static (String, int) _parseEndpoint(String endpoint) {
    late String rawHost;
    late String rawPort;
    if (endpoint.startsWith('[')) {
      final closingBracket = endpoint.indexOf(']');
      if (closingBracket == -1) {
        _invalid('IPv6 host is missing a closing bracket');
      }
      rawHost = endpoint.substring(1, closingBracket);
      final afterBracket = endpoint.substring(closingBracket + 1);
      if (!afterBracket.startsWith(':')) _invalid('port is missing');
      rawPort = afterBracket.substring(1);
      if (!_isIPv6(rawHost)) _invalid('host is invalid');
    } else {
      final colon = endpoint.lastIndexOf(':');
      if (colon == -1) _invalid('port is missing');
      rawHost = endpoint.substring(0, colon);
      rawPort = endpoint.substring(colon + 1);
      if (rawHost.contains(':')) {
        _invalid('IPv6 host must be enclosed in brackets');
      }
    }
    if (rawHost.isEmpty) _invalid('host is missing');
    if (!_isValidHost(rawHost)) _invalid('host is invalid');
    if (rawPort.isEmpty) _invalid('port is missing');
    final port = _parseUnsigned(rawPort);
    if (port == null || port < 1 || port > 65535) {
      _invalid('port must be between 1 and 65535');
    }
    return (rawHost, port);
  }

  static Map<String, String> _parseQuery(String? rawQuery) {
    if (rawQuery == null) return {};
    final result = <String, String>{};
    for (final item in rawQuery.split('&').where((item) => item.isNotEmpty)) {
      final pair = _splitOnce(item, '=');
      result[_decode(pair.$1, 'query key')] = _decode(
        pair.$2 ?? '',
        'query value',
      );
    }
    return result;
  }

  static String _parsedName(String? rawFragment, String fallback) {
    final decoded = _decode(rawFragment ?? '', 'fragment').trim();
    final name = decoded.isEmpty ? fallback : decoded;
    return String.fromCharCodes(name.runes.take(Tunnel.nameMaxLength));
  }

  static String _decode(String value, String component) {
    try {
      return Uri.decodeComponent(value);
    } on Object {
      _invalid('$component has invalid percent encoding');
    }
  }

  static List<int>? _decodeBase64(String value) {
    var normalized = value.replaceAll('-', '+').replaceAll('_', '/');
    if (normalized.length % 4 == 1) return null;
    normalized += '=' * ((4 - normalized.length % 4) % 4);
    try {
      return base64Decode(normalized);
    } on FormatException {
      return null;
    }
  }

  static String? _decodeBase64Text(String value) {
    final bytes = _decodeBase64(value);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  static void _append(String? value, String key, List<(String, String)> query) {
    if (value != null) query.add((key, value));
  }

  static String _encodedQuery(List<(String, String)> query) =>
      query.map((pair) => '${pair.$1}=${_percentEncode(pair.$2)}').join('&');

  static String _encodedHost(String host) => _isIPv6(host) ? '[$host]' : host;

  static String _percentEncode(String value) {
    const hexadecimal = '0123456789ABCDEF';
    final result = StringBuffer();
    for (final byte in utf8.encode(value)) {
      if ((byte >= 0x41 && byte <= 0x5a) ||
          (byte >= 0x61 && byte <= 0x7a) ||
          (byte >= 0x30 && byte <= 0x39) ||
          const [0x2d, 0x2e, 0x5f, 0x7e].contains(byte)) {
        result.writeCharCode(byte);
      } else {
        result
          ..write('%')
          ..write(hexadecimal[byte >> 4])
          ..write(hexadecimal[byte & 0x0f]);
      }
    }
    return result.toString();
  }

  static int _integer(Object? value, String field) {
    final result = _optionalInteger(value, field);
    if (result == null) _invalid('$field is missing');
    return result;
  }

  static int? _optionalInteger(Object? value, String field) {
    if (value == null) return null;
    if (value is String) {
      final result = _parseUnsigned(value);
      if (result != null) return result;
    } else if (value is int) {
      return value;
    } else if (value is double &&
        value.isFinite &&
        value == value.roundToDouble()) {
      return value.toInt();
    }
    _invalid('$field must be a number or numeric string');
  }

  static (String, String?) _splitOnce(String value, String separator) {
    final index = value.indexOf(separator);
    return index == -1
        ? (value, null)
        : (
            value.substring(0, index),
            value.substring(index + separator.length),
          );
  }

  static String _trimTrailingSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  static String? _nonempty(String? value) =>
      value == null || value.isEmpty ? null : value;

  static List<String> _parseALPN(String? value) =>
      value
          ?.split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList() ??
      const [];

  static bool _isTrue(String? value) => value == '1' || value == 'true';

  static bool _jsonBoolean(Object? value) => switch (value) {
    final bool value => value,
    final String value => _isTrue(value),
    final num value => value == 1,
    _ => false,
  };

  static bool _isValidHost(String host) {
    if (_isIPv6(host)) return true;
    if (IPv4Prefix.parse(host)?.isHost == true) return true;
    if (host.codeUnits.every(
      (code) => (code >= 0x30 && code <= 0x39) || code == 0x2e,
    )) {
      return false;
    }
    if (host.length > 253) return false;
    final labels = host.split('.');
    return labels.isNotEmpty &&
        labels.every(
          (label) =>
              label.isNotEmpty &&
              label.length <= 63 &&
              !label.startsWith('-') &&
              !label.endsWith('-') &&
              label.codeUnits.every(
                (code) =>
                    (code >= 0x41 && code <= 0x5a) ||
                    (code >= 0x61 && code <= 0x7a) ||
                    (code >= 0x30 && code <= 0x39) ||
                    code == 0x2d,
              ),
        );
  }

  static bool _isIPv6(String host) =>
      InternetAddress.tryParse(host)?.type == InternetAddressType.IPv6;

  static int? _parseUnsigned(String value) {
    if (value.isEmpty ||
        !value.codeUnits.every((code) => code >= 0x30 && code <= 0x39)) {
      return null;
    }
    return int.tryParse(value);
  }

  static Never _invalid(String message) =>
      throw ProxyLinkException(ProxyLinkError.invalid, message);

  static Never _unsupported(String message) =>
      throw ProxyLinkException(ProxyLinkError.unsupported, message);
}
