/// A loopback SOCKS5 / HTTP port that sends an app through one tunnel or group
/// without a rule (F17, docs/design/01-data-model.md, "Local proxy"). The port
/// is kept while the switch is off so turning it back on gives the same
/// address.
final class LocalProxy {
  const LocalProxy({required this.isEnabled, required this.port});

  factory LocalProxy.fromJson(Map<String, Object?> json) {
    final isEnabled = json['isEnabled'];
    final port = json['port'];
    if (isEnabled is! bool) {
      throw const FormatException('isEnabled must be a boolean');
    }
    if (port is! int) {
      throw const FormatException('port must be an integer');
    }
    return LocalProxy(isEnabled: isEnabled, port: port);
  }

  static const minPort = 1024;
  static const maxPort = 65535;

  /// The app hands out ports from here up (the lowest free one).
  static const firstPort = 1081;
  static const listenAddress = '127.0.0.1';

  /// sing-box inbound tag prefix: `proxy-t-<id>` / `proxy-g-<id>`.
  static const inboundTagPrefix = 'proxy-';

  final bool isEnabled;

  /// `minPort`…`maxPort`, unique across tunnels and groups.
  final int port;

  static bool isValidPort(int port) => port >= minPort && port <= maxPort;

  /// `127.0.0.1:1081`.
  String get address => '$listenAddress:$port';

  /// What *Copy* puts on the clipboard: the `socks5h` form, so the client hands
  /// the name to the proxy and nothing is resolved outside the tunnel.
  String get copyText => 'socks5h://$address';

  static String inboundTag(String outboundTag) =>
      '$inboundTagPrefix$outboundTag';

  /// The outbound tag behind an inbound tag (`proxy-t-<id>` → `t-<id>`).
  static String? outboundTag(String inboundTag) =>
      inboundTag.startsWith(inboundTagPrefix) &&
          inboundTag.length > inboundTagPrefix.length
      ? inboundTag.substring(inboundTagPrefix.length)
      : null;

  Map<String, Object?> toJson() => {'isEnabled': isEnabled, 'port': port};

  LocalProxy copyWith({bool? isEnabled, int? port}) => LocalProxy(
    isEnabled: isEnabled ?? this.isEnabled,
    port: port ?? this.port,
  );

  @override
  bool operator ==(Object other) =>
      other is LocalProxy && isEnabled == other.isEnabled && port == other.port;

  @override
  int get hashCode => Object.hash(isEnabled, port);
}
