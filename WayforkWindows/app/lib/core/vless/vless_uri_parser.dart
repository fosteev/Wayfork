import 'dart:convert';
import 'dart:io';

import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/support/uuid.dart';

final class VLESSImportResult {
  const VLESSImportResult({
    required this.uuid,
    required this.meta,
    required this.name,
  });

  final String uuid;
  final VLESSMeta meta;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is VLESSImportResult &&
      uuid == other.uuid &&
      meta == other.meta &&
      name == other.name;
  @override
  int get hashCode => Object.hash(uuid, meta, name);
}

enum VLESSImportError { invalid, unsupported }

final class VLESSImportException implements Exception {
  const VLESSImportException(this.kind, this.message);

  final VLESSImportError kind;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is VLESSImportException &&
      kind == other.kind &&
      message == other.message;
  @override
  int get hashCode => Object.hash(kind, message);
  @override
  String toString() => message;
}

abstract final class VLESSURIParser {
  static VLESSImportResult parse(String uri) {
    final fragmentParts = _splitOnce(uri, '#');
    final queryParts = _splitOnce(fragmentParts.$1, '?');
    final withoutQuery = queryParts.$1;

    final schemeEnd = withoutQuery.indexOf('://');
    if (schemeEnd == -1) _invalid('scheme is missing');
    final scheme = withoutQuery.substring(0, schemeEnd);
    if (scheme.toLowerCase() != 'vless') _invalid('scheme must be vless');

    final authority = withoutQuery.substring(schemeEnd + 3);
    final at = authority.indexOf('@');
    if (at == -1) _invalid('UUID is missing');
    final rawUUID = authority.substring(0, at);
    if (rawUUID.isEmpty) _invalid('UUID is missing');
    final uuid = Uuid.normalize(rawUUID);
    if (uuid == null) _invalid('UUID is invalid');

    final endpoint = _parseEndpoint(authority.substring(at + 1));
    final host = endpoint.$1;
    final port = endpoint.$2;
    final query = _parseQuery(queryParts.$2);

    final encryption = query['encryption'];
    if (encryption != null && encryption != 'none') {
      _invalid('encryption must be none');
    }
    final headerType = query['headerType'];
    if (headerType != null && headerType != 'none') {
      _unsupported('headerType "$headerType" is not supported yet.');
    }

    final security = switch (query['security']) {
      null || 'none' => VLESSSecurity.none,
      'tls' => VLESSSecurity.tls,
      'reality' => VLESSSecurity.reality,
      _ => _invalid('security must be none, tls, or reality'),
    };

    final transport = switch (query['type']) {
      null || 'tcp' => const VLESSTransportTCP(),
      'ws' => VLESSTransportWS(path: query['path'] ?? '/', host: query['host']),
      'grpc' => VLESSTransportGRPC(serviceName: query['serviceName'] ?? ''),
      final type => _unsupported('Transport "$type" is not supported yet.'),
    };

    final String? flow;
    switch (query['flow']) {
      case null:
        flow = null;
      case 'xtls-rprx-vision':
        flow = 'xtls-rprx-vision';
      case final unsupported:
        _unsupported('Flow "$unsupported" is not supported yet.');
    }
    if (flow != null &&
        (security == VLESSSecurity.none || transport is! VLESSTransportTCP)) {
      _invalid('flow requires TLS/REALITY over TCP');
    }

    if (security == VLESSSecurity.reality) {
      final publicKey = query['pbk'];
      if (publicKey == null || publicKey.isEmpty) {
        _invalid('REALITY requires pbk');
      }
      if (transport is! VLESSTransportTCP) {
        _unsupported('REALITY over ws/grpc is not supported');
      }
    }

    final sni = security == VLESSSecurity.none ? null : query['sni'] ?? host;
    final alpn =
        query['alpn']
            ?.split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList() ??
        const <String>[];
    final allowInsecure =
        _isTrue(query['allowInsecure']) || _isTrue(query['insecure']);
    final decodedFragment = _decode(fragmentParts.$2 ?? '', 'fragment').trim();
    final fullName = decodedFragment.isEmpty ? host : decodedFragment;
    final name = String.fromCharCodes(
      fullName.runes.take(Tunnel.nameMaxLength),
    );

    return VLESSImportResult(
      uuid: uuid,
      meta: VLESSMeta(
        server: host,
        port: port,
        flow: flow,
        security: security,
        sni: sni,
        fingerprint: query['fp'],
        alpn: alpn,
        realityPublicKey: query['pbk'],
        realityShortID: switch (query['sid']) {
          final value? when value.isNotEmpty => value,
          _ => null,
        },
        transport: transport,
        allowInsecure: allowInsecure,
      ),
      name: name,
    );
  }

  /// Rebuilds a VLESS sharing link. [uuid] may be a display placeholder.
  static String uri(VLESSMeta meta, String uuid, String name) {
    final query = <(String, String)>[('encryption', 'none')];
    _append(meta.flow, 'flow', query);
    query.add(('security', meta.security.jsonValue));
    _append(meta.sni, 'sni', query);
    _append(meta.fingerprint, 'fp', query);
    if (meta.alpn.isNotEmpty) query.add(('alpn', meta.alpn.join(',')));
    _append(meta.realityPublicKey, 'pbk', query);
    _append(meta.realityShortID, 'sid', query);
    switch (meta.transport) {
      case VLESSTransportTCP():
        query.add(('type', 'tcp'));
      case VLESSTransportWS(:final path, :final host):
        query.add(('type', 'ws'));
        query.add(('path', path));
        _append(host, 'host', query);
      case VLESSTransportGRPC(:final serviceName):
        query.add(('type', 'grpc'));
        query.add(('serviceName', serviceName));
    }
    if (meta.allowInsecure) query.add(('allowInsecure', '1'));
    final host = _isIPv6(meta.server) ? '[${meta.server}]' : meta.server;
    final encodedQuery = query
        .map((pair) => '${pair.$1}=${_percentEncode(pair.$2)}')
        .join('&');
    return 'vless://$uuid@$host:${meta.port}?$encodedQuery#${_percentEncode(name)}';
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
    if (!_asciiDigits(rawPort)) _invalid('port must be between 1 and 65535');
    final port = int.tryParse(rawPort);
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
      result[pair.$1] = _decode(pair.$2 ?? '', 'query value');
    }
    return result;
  }

  static String _decode(String value, String component) {
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      _invalid('$component has invalid percent encoding');
    } on FormatException {
      _invalid('$component has invalid percent encoding');
    }
  }

  static bool _isTrue(String? value) => value == '1' || value == 'true';

  static void _append(String? value, String key, List<(String, String)> query) {
    if (value != null) query.add((key, value));
  }

  static String _percentEncode(String value) {
    const hexadecimal = '0123456789ABCDEF';
    final result = StringBuffer();
    for (final byte in utf8.encode(value)) {
      if ((byte >= 0x41 && byte <= 0x5a) ||
          (byte >= 0x61 && byte <= 0x7a) ||
          (byte >= 0x30 && byte <= 0x39) ||
          byte == 0x2d ||
          byte == 0x2e ||
          byte == 0x5f ||
          byte == 0x7e) {
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

  static bool _isValidHost(String host) {
    if (_isIPv6(host)) return true;
    final ipv4 = IPv4Prefix.parse(host);
    if (ipv4 != null && ipv4.isHost) return true;
    if (host.codeUnits.every(
      (code) => (code >= 0x30 && code <= 0x39) || code == 0x2e,
    )) {
      return false;
    }
    if (host.length > 253) return false;
    final labels = host.split('.');
    return labels.isNotEmpty &&
        labels.every((label) {
          if (label.isEmpty ||
              label.length > 63 ||
              label.startsWith('-') ||
              label.endsWith('-')) {
            return false;
          }
          return label.codeUnits.every(
            (code) =>
                (code >= 0x41 && code <= 0x5a) ||
                (code >= 0x61 && code <= 0x7a) ||
                (code >= 0x30 && code <= 0x39) ||
                code == 0x2d,
          );
        });
  }

  static bool _isIPv6(String host) =>
      InternetAddress.tryParse(host)?.type == InternetAddressType.IPv6;

  static bool _asciiDigits(String value) =>
      value.isNotEmpty &&
      value.codeUnits.every((code) => code >= 0x30 && code <= 0x39);

  static Never _invalid(String message) =>
      throw VLESSImportException(VLESSImportError.invalid, message);
  static Never _unsupported(String message) =>
      throw VLESSImportException(VLESSImportError.unsupported, message);
}
