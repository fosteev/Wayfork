part of 'app_model.dart';

// Tunnel management (F1): import, edit, enable/disable, delete. The file
// pickers and the missing-files loop live in the UI (WM3d); the model takes
// parsed results.

extension AppModelTunnels on AppModel {
  static String get _limitMessage =>
      'Wayfork supports up to ${Tunnel.maxSlots} tunnels.';

  // OpenVPN

  /// Adds a tunnel from a parsed profile. Returns an error message, or null
  /// when the tunnel was added (then it is expanded in Tunnels).
  Future<String?> addOpenVPN(
    OpenVPNImportResult result, {
    required String name,
  }) async {
    final slot = _store.nextFreeSlot();
    if (slot == null) {
      _alert(AppAlert(title: 'Tunnel limit reached', message: _limitMessage));
      return _limitMessage;
    }
    final tunnel = Tunnel(
      name: uniqueName(name),
      slot: slot,
      kind: TunnelKindOpenVPN(result.meta),
    );
    try {
      await _secrets.write(
        result.sanitizedConfig,
        SecretKey(SecretKind.ovpn, tunnel.id),
      );
      final credentials = result.credentials;
      if (credentials != null) {
        await _secrets.writeCredentials(credentials, tunnel.id);
      }
    } on Object catch (error) {
      return _secretsFailed('Cannot store the config: $error');
    }
    await update(
      (store) => store.copyWith(tunnels: [...store.tunnels, tunnel]),
    );
    logs.app(
      LogLevel.info,
      'imported OpenVPN tunnel ${tunnel.name}'
      '${result.strippedDirectives.isEmpty ? '' : ' (stripped: ${result.strippedDirectives.join(', ')})'}',
    );
    expandedTunnelID = tunnel.id;
    if (result.meta.needsCredentials && result.credentials == null) {
      pendingFocus = TunnelField.username;
    } else if (result.meta.needsKeyPassphrase) {
      pendingFocus = TunnelField.keyPassphrase;
    } else {
      pendingFocus = null;
    }
    _changed();
    return null;
  }

  /// Replaces the profile of an OpenVPN tunnel, keeping its DNS choice.
  Future<String?> replaceOpenVPNConfig(
    String tunnelID,
    OpenVPNImportResult result,
  ) async {
    final tunnel = _store.tunnel(tunnelID);
    final old = tunnel?.kind.openVPN;
    if (tunnel == null || old == null) return 'Tunnel not found';
    final meta = AppModel._copyMeta(result.meta, dns: old.dns);
    try {
      await _secrets.write(
        result.sanitizedConfig,
        SecretKey(SecretKind.ovpn, tunnel.id),
      );
      final credentials = result.credentials;
      if (credentials != null) {
        await _secrets.writeCredentials(credentials, tunnel.id);
      }
    } on Object catch (error) {
      return _secretsFailed('Cannot store the config: $error');
    }
    await _updateTunnel(
      tunnel.id,
      (t) => t.copyWith(kind: TunnelKindOpenVPN(meta)),
    );
    secretsChanged();
    logs.app(LogLevel.info, 'replaced config of ${tunnel.name}');
    return null;
  }

  Future<Credentials?> credentials(String tunnelID) async {
    try {
      return await _secrets.readCredentials(tunnelID);
    } on Object {
      return null;
    }
  }

  Future<String?> setCredentials(
    String tunnelID, {
    required String username,
    required String password,
  }) async {
    try {
      if (username.isEmpty && password.isEmpty) {
        await _secrets.delete(SecretKey(SecretKind.credentials, tunnelID));
      } else {
        await _secrets.writeCredentials(
          Credentials(username: username, password: password),
          tunnelID,
        );
      }
    } on Object catch (error) {
      return _secretsFailed('$error');
    }
    secretsChanged();
    return null;
  }

  Future<String?> keyPassphrase(String tunnelID) async {
    try {
      return await _secrets.read(SecretKey(SecretKind.keyPassphrase, tunnelID));
    } on Object {
      return null;
    }
  }

  Future<String?> setKeyPassphrase(String tunnelID, String passphrase) async {
    try {
      if (passphrase.isEmpty) {
        await _secrets.delete(SecretKey(SecretKind.keyPassphrase, tunnelID));
      } else {
        await _secrets.write(
          passphrase,
          SecretKey(SecretKind.keyPassphrase, tunnelID),
        );
      }
    } on Object catch (error) {
      return _secretsFailed('$error');
    }
    secretsChanged();
    return null;
  }

  Future<void> setDNS(String tunnelID, TunnelDNS dns) =>
      _updateTunnel(tunnelID, (tunnel) {
        final meta = tunnel.kind.openVPN;
        if (meta == null) return tunnel;
        return tunnel.copyWith(
          kind: TunnelKindOpenVPN(AppModel._copyMeta(meta, dns: dns)),
        );
      });

  // VLESS

  /// Adds a tunnel from an already validated `vless://` URI.
  Future<String?> addVLESS(VLESSImportResult result) async {
    final slot = _store.nextFreeSlot();
    if (slot == null) {
      _alert(AppAlert(title: 'Tunnel limit reached', message: _limitMessage));
      return _limitMessage;
    }
    final tunnel = Tunnel(
      name: uniqueName(result.name.isEmpty ? result.meta.server : result.name),
      slot: slot,
      kind: TunnelKindVLESS(result.meta),
    );
    try {
      await _secrets.write(result.uuid, SecretKey(SecretKind.uuid, tunnel.id));
    } on Object catch (error) {
      return _secretsFailed('Cannot store the UUID: $error');
    }
    await update(
      (store) => store.copyWith(tunnels: [...store.tunnels, tunnel]),
    );
    logs.app(LogLevel.info, 'added VLESS tunnel ${tunnel.name}');
    expandedTunnelID = tunnel.id;
    pendingFocus = null;
    _changed();
    return null;
  }

  Future<String?> replaceVLESS(
    String tunnelID,
    VLESSImportResult result,
  ) async {
    final tunnel = _store.tunnel(tunnelID);
    if (tunnel == null) return 'Tunnel not found';
    try {
      await _secrets.write(result.uuid, SecretKey(SecretKind.uuid, tunnel.id));
    } on Object catch (error) {
      return _secretsFailed('Cannot store the UUID: $error');
    }
    await _updateTunnel(
      tunnel.id,
      (t) => t.copyWith(kind: TunnelKindVLESS(result.meta)),
    );
    secretsChanged();
    logs.app(LogLevel.info, 'replaced URL of ${tunnel.name}');
    return null;
  }

  /// Full `vless://` URI with the stored UUID (for Copy); null when it is
  /// missing.
  Future<String?> vlessURI(Tunnel tunnel) async {
    final meta = tunnel.kind.vless;
    if (meta == null) return null;
    final String? uuid;
    try {
      uuid = await _secrets.read(SecretKey(SecretKind.uuid, tunnel.id));
    } on Object {
      return null;
    }
    if (uuid == null) return null;
    return VLESSURIParser.uri(meta, uuid, tunnel.name);
  }

  /// The URI with the UUID masked, for display.
  String maskedVLESSURI(Tunnel tunnel) {
    final meta = tunnel.kind.vless;
    if (meta == null) return '';
    return VLESSURIParser.uri(meta, '••••••••', tunnel.name);
  }

  // Common

  /// Returns an error message, or null when the rename went through.
  Future<String?> rename(String tunnelID, String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) return "Name can't be empty";
    if (name.length > Tunnel.nameMaxLength) {
      return 'Name is limited to ${Tunnel.nameMaxLength} characters';
    }
    if (!_store.isNameAvailable(name, excluding: tunnelID)) {
      return 'Another tunnel is already called $name';
    }
    await _updateTunnel(tunnelID, (tunnel) => tunnel.copyWith(name: name));
    return null;
  }

  Future<void> setEnabled(String tunnelID, bool enabled) =>
      _updateTunnel(tunnelID, (tunnel) => tunnel.copyWith(isEnabled: enabled));

  /// The confirmation text for [deleteTunnel]; null when the tunnel is
  /// unknown.
  String? deleteTunnelMessage(String tunnelID) {
    final tunnel = _store.tunnel(tunnelID);
    if (tunnel == null) return null;
    final rules = ruleCountForTunnel(tunnelID);
    return rules > 0
        ? 'Delete ${tunnel.name} and its ${StatusText.count(rules, 'rule')}? '
              'The rules go with it.'
        : 'Delete ${tunnel.name}?';
  }

  /// Removes the tunnel, its rules and its secrets (the UI confirms first
  /// with [deleteTunnelMessage]).
  Future<void> deleteTunnel(String tunnelID) async {
    final tunnel = _store.tunnel(tunnelID);
    if (tunnel == null) return;
    await update(
      (store) => store.copyWith(
        tunnels: store.tunnels.where((t) => t.id != tunnelID).toList(),
        rules: store.rules
            .where((rule) => rule.target != RuleTargetTunnel(tunnelID))
            .toList(),
        defaultTunnelID: store.defaultTunnelID == tunnelID
            ? null
            : store.defaultTunnelID,
      ),
    );
    try {
      await _secrets.deleteAll(tunnelID);
    } on Object catch (error) {
      logs.app(
        LogLevel.warning,
        'cannot delete secrets of ${tunnel.name}: $error',
      );
    }
    if (expandedTunnelID == tunnelID) expandedTunnelID = null;
    logs.app(LogLevel.info, 'deleted tunnel ${tunnel.name}');
    _changed();
  }

  String uniqueName(String base) {
    var candidate = base.trim();
    if (candidate.length > Tunnel.nameMaxLength) {
      candidate = candidate.substring(0, Tunnel.nameMaxLength);
    }
    if (candidate.isEmpty) candidate = 'Tunnel';
    if (_store.isNameAvailable(candidate)) return candidate;
    var n = 2;
    while (true) {
      final suffix = ' ($n)';
      final room = Tunnel.nameMaxLength - suffix.length;
      final trimmed = candidate.length > room
          ? candidate.substring(0, room)
          : candidate;
      final attempt = '$trimmed$suffix';
      if (_store.isNameAvailable(attempt)) return attempt;
      n += 1;
    }
  }

  Future<void> _updateTunnel(
    String tunnelID,
    Tunnel Function(Tunnel tunnel) mutate,
  ) => update(
    (store) => store.copyWith(
      tunnels: [
        for (final tunnel in store.tunnels)
          if (tunnel.id == tunnelID) mutate(tunnel) else tunnel,
      ],
    ),
  );

  String _secretsFailed(String message) {
    _alert(AppAlert(title: 'Secrets error', message: message));
    return message;
  }
}
