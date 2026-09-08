import 'dart:convert';

import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';

final class WireGuardImportResult {
  const WireGuardImportResult({
    required this.privateKey,
    this.presharedKey,
    required this.meta,
    required this.name,
  });

  final String privateKey;
  final String? presharedKey;
  final WireGuardMeta meta;
  final String name;

  Map<String, Object?> toJson() => {
    'privateKey': privateKey,
    if (presharedKey != null) 'presharedKey': presharedKey,
    'meta': meta.toJson(),
    'name': name,
  };

  @override
  bool operator ==(Object other) =>
      other is WireGuardImportResult &&
      privateKey == other.privateKey &&
      presharedKey == other.presharedKey &&
      meta == other.meta &&
      name == other.name;

  @override
  int get hashCode => Object.hash(privateKey, presharedKey, meta, name);
}

enum WireGuardImportError { invalid, unsupported }

final class WireGuardImportException implements Exception {
  const WireGuardImportException(this.kind, this.message);

  final WireGuardImportError kind;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is WireGuardImportException &&
      kind == other.kind &&
      message == other.message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => message;
}

abstract final class WireGuardConfParser {
  static WireGuardImportResult parse(String text) {
    _ParsedSection? interface;
    final peers = <_ParsedSection>[];
    _Section? section;

    for (final rawLine in text.split(RegExp(r'\r\n|\n|\r'))) {
      final line = _stripComment(rawLine).trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        switch (line.substring(1, line.length - 1).trim().toLowerCase()) {
          case 'interface':
            if (interface != null) _invalid('multiple Interface sections');
            interface = _ParsedSection();
            section = _Section.interface;
          case 'peer':
            peers.add(_ParsedSection());
            section = _Section.peer;
          default:
            section = _Section.ignored;
        }
        continue;
      }

      final equals = line.indexOf('=');
      if (equals == -1) continue;
      final key = line.substring(0, equals).trim();
      final value = line.substring(equals + 1).trim();
      if (key.isEmpty) continue;
      switch (section) {
        case _Section.interface:
          interface!.append(key, value);
        case _Section.peer:
          peers.last.append(key, value);
        case _Section.ignored || null:
          break;
      }
    }

    if (interface == null) _invalid('Interface section is missing');
    if (peers.isEmpty) _invalid('at least one Peer section is required');
    final privateKey = _nonempty(interface.last('PrivateKey'));
    if (privateKey == null) _invalid('PrivateKey is missing');
    _validateKey(privateKey, 'PrivateKey');

    final addresses = interface
        .list('Address')
        .map(_normalizedIPv4Prefix)
        .whereType<String>()
        .toList();
    if (addresses.isEmpty) _invalid('Address must contain an IPv4 prefix');
    final discoveredDNS = interface.list('DNS').where((value) {
      if (value.contains('/')) return false;
      return IPv4Prefix.parse(value)?.isHost == true;
    }).toList();
    final mtu = _parseMTU(interface.last('MTU'));

    final resultPeers = <WireGuardPeer>[];
    String? presharedKey;
    for (var index = 0; index < peers.length; index++) {
      final peer = peers[index];
      final number = index + 1;
      final publicKey = _nonempty(peer.last('PublicKey'));
      if (publicKey == null) _invalid('peer $number PublicKey is missing');
      _validateKey(publicKey, 'peer $number PublicKey');

      final peerPresharedKey = _nonempty(peer.last('PresharedKey'));
      if (peerPresharedKey != null) {
        if (index != 0) {
          _unsupported('preshared keys are supported on the first peer only');
        }
        _validateKey(peerPresharedKey, 'PresharedKey');
        presharedKey = peerPresharedKey;
      }

      final endpoint = _nonempty(peer.last('Endpoint'));
      if (endpoint == null) _invalid('peer $number Endpoint is missing');
      final parsedEndpoint = _parseEndpoint(endpoint);
      final allowedIPs = peer
          .list('AllowedIPs')
          .map(_normalizedIPv4Prefix)
          .whereType<String>()
          .toList();
      if (allowedIPs.isEmpty) {
        _invalid('peer $number AllowedIPs must contain IPv4');
      }
      resultPeers.add(
        WireGuardPeer(
          host: parsedEndpoint.$1,
          port: parsedEndpoint.$2,
          publicKey: publicKey,
          hasPresharedKey: peerPresharedKey != null,
          allowedIPs: allowedIPs,
          keepalive: _parseKeepalive(peer.last('PersistentKeepalive'), number),
        ),
      );
    }

    return WireGuardImportResult(
      privateKey: privateKey,
      presharedKey: presharedKey,
      meta: WireGuardMeta(
        addresses: addresses,
        peers: resultPeers,
        mtu: mtu,
        discoveredDNS: discoveredDNS,
      ),
      name: resultPeers.first.host,
    );
  }

  static String _stripComment(String line) {
    final hash = line.indexOf('#');
    final semicolon = line.indexOf(';');
    final indexes = [hash, semicolon].where((index) => index >= 0);
    if (indexes.isEmpty) return line;
    return line.substring(
      0,
      indexes.reduce((left, right) => left < right ? left : right),
    );
  }

  static String? _nonempty(String? value) =>
      value == null || value.isEmpty ? null : value;

  static void _validateKey(String value, String field) {
    try {
      if (base64Decode(value).length == 32) return;
    } on FormatException {
      // Report the stable import error below.
    }
    _invalid('$field must be base64 encoding of 32 bytes');
  }

  static String? _normalizedIPv4Prefix(String value) {
    if (IPv4Prefix.parse(value) == null) return null;
    return value.contains('/') ? value : '$value/32';
  }

  static int? _parseMTU(String? raw) {
    final value = _nonempty(raw);
    if (value == null) return null;
    final mtu = _parseUnsigned(value);
    if (mtu == null || mtu < 576 || mtu > 9000) {
      _invalid('MTU must be between 576 and 9000');
    }
    return mtu;
  }

  static (String, int) _parseEndpoint(String value) {
    if (value.startsWith('[')) {
      _unsupported('IPv6 peer endpoints are not supported');
    }
    final colon = value.lastIndexOf(':');
    if (colon == -1) _invalid('Endpoint must be host:port');
    final host = value.substring(0, colon).trim();
    final rawPort = value.substring(colon + 1).trim();
    final port = _parseUnsigned(rawPort);
    if (host.isEmpty ||
        host.contains(':') ||
        port == null ||
        port < 1 ||
        port > 65535) {
      _invalid('Endpoint must be host:port with port 1...65535');
    }
    return (host, port);
  }

  static int? _parseKeepalive(String? raw, int peer) {
    final value = _nonempty(raw);
    if (value == null) return null;
    final keepalive = _parseUnsigned(value);
    if (keepalive == null || keepalive > 65535) {
      _invalid('peer $peer PersistentKeepalive must be between 0 and 65535');
    }
    return keepalive == 0 ? null : keepalive;
  }

  static int? _parseUnsigned(String value) {
    if (value.isEmpty ||
        !value.codeUnits.every((code) => code >= 0x30 && code <= 0x39)) {
      return null;
    }
    return int.tryParse(value);
  }

  static Never _invalid(String message) =>
      throw WireGuardImportException(WireGuardImportError.invalid, message);

  static Never _unsupported(String message) =>
      throw WireGuardImportException(WireGuardImportError.unsupported, message);
}

enum _Section { interface, peer, ignored }

final class _ParsedSection {
  final Map<String, List<String>> _values = {};

  void append(String key, String value) {
    (_values[key.toLowerCase()] ??= []).add(value);
  }

  String? last(String key) => _values[key.toLowerCase()]?.last;

  List<String> list(String key) => [
    for (final value in _values[key.toLowerCase()] ?? const <String>[])
      for (final item in value.split(',')) item.trim(),
  ];
}
