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

  /// OpenVPN and WireGuard are the kinds that resolve names themselves, so they
  /// are the only ones with a DNS editor (docs/design/03-routing.md).
  Future<void> setDNS(String tunnelID, TunnelDNS dns) => _updateTunnel(
    tunnelID,
    (tunnel) => switch (tunnel.kind) {
      TunnelKindOpenVPN(:final meta) => tunnel.copyWith(
        kind: TunnelKindOpenVPN(AppModel._copyMeta(meta, dns: dns)),
      ),
      TunnelKindWireGuard(:final meta) => tunnel.copyWith(
        kind: TunnelKindWireGuard(AppModel._copyWireGuardMeta(meta, dns: dns)),
      ),
      _ => tunnel,
    },
  );

  // WireGuard

  /// Adds a tunnel from an already parsed `.conf`; [rawName] is the file name.
  Future<String?> addWireGuard(
    WireGuardImportResult result,
    String rawName,
  ) async {
    final slot = _store.nextFreeSlot();
    if (slot == null) {
      _alert(AppAlert(title: 'Tunnel limit reached', message: _limitMessage));
      return _limitMessage;
    }
    final tunnel = Tunnel(
      name: uniqueName(rawName.isEmpty ? result.name : rawName),
      slot: slot,
      kind: TunnelKindWireGuard(result.meta),
    );
    try {
      await _secrets.write(
        result.privateKey,
        SecretKey(SecretKind.privateKey, tunnel.id),
      );
      final presharedKey = result.presharedKey;
      if (presharedKey != null) {
        await _secrets.write(
          presharedKey,
          SecretKey(SecretKind.presharedKey, tunnel.id),
        );
      }
    } on Object catch (error) {
      return _secretsFailed('Cannot store the keys: $error');
    }
    await update(
      (store) => store.copyWith(tunnels: [...store.tunnels, tunnel]),
    );
    logs.app(LogLevel.info, 'added WireGuard tunnel ${tunnel.name}');
    expandedTunnelID = tunnel.id;
    pendingFocus = null;
    _changed();
    return null;
  }

  /// Replaces the config, keeping the tunnel's own DNS choice.
  Future<String?> replaceWireGuardConfig(
    String tunnelID,
    WireGuardImportResult result,
  ) async {
    final tunnel = _store.tunnel(tunnelID);
    final old = tunnel?.kind.wireGuard;
    if (tunnel == null || old == null) return 'Tunnel not found';
    final meta = AppModel._copyWireGuardMeta(result.meta, dns: old.dns);
    try {
      await _secrets.write(
        result.privateKey,
        SecretKey(SecretKind.privateKey, tunnel.id),
      );
      final presharedKey = result.presharedKey;
      if (presharedKey == null) {
        await _secrets.delete(SecretKey(SecretKind.presharedKey, tunnel.id));
      } else {
        await _secrets.write(
          presharedKey,
          SecretKey(SecretKind.presharedKey, tunnel.id),
        );
      }
    } on Object catch (error) {
      return _secretsFailed('Cannot store the keys: $error');
    }
    await _updateTunnel(
      tunnel.id,
      (t) => t.copyWith(kind: TunnelKindWireGuard(meta)),
    );
    secretsChanged();
    logs.app(LogLevel.info, 'replaced config of ${tunnel.name}');
    return null;
  }

  // Proxy links

  /// Adds a tunnel from an already validated link of any supported scheme.
  Future<String?> addLink(ProxyLink link) async {
    final slot = _store.nextFreeSlot();
    if (slot == null) {
      _alert(AppAlert(title: 'Tunnel limit reached', message: _limitMessage));
      return _limitMessage;
    }
    final kind = link.tunnelKind;
    final tunnel = Tunnel(
      name: uniqueName(
        link.linkName.isEmpty ? kind.serverHosts.first : link.linkName,
      ),
      slot: slot,
      kind: kind,
    );
    try {
      await _secrets.write(link.secret, SecretKey(link.secretKind, tunnel.id));
    } on Object catch (error) {
      return _secretsFailed('Cannot store the ${link.secretLabel}: $error');
    }
    await update(
      (store) => store.copyWith(tunnels: [...store.tunnels, tunnel]),
    );
    logs.app(
      LogLevel.info,
      'added ${StatusText.typeBadge(kind)} tunnel ${tunnel.name}',
    );
    expandedTunnelID = tunnel.id;
    pendingFocus = null;
    _changed();
    return null;
  }

  /// Adds every link of a subscription in one store update
  /// (docs/design/04-tunnels.md, "Subscriptions"). Stops at the first secrets
  /// failure, keeping what was written; returns the message shown for the
  /// stop, or null. `host` is all the log ever sees of the subscription URL.
  Future<String?> addLinks(
    List<ProxyLink> links, {
    required String host,
  }) async {
    final added = <Tunnel>[];
    final takenNames = <String>{};
    String? failure;
    for (final link in links) {
      final slot = _store.nextFreeSlot(
        excluding: added.map((tunnel) => tunnel.slot),
      );
      if (slot == null) {
        failure = _limitMessage;
        break;
      }
      final kind = link.tunnelKind;
      final name = uniqueName(
        link.linkName.isEmpty ? kind.serverHosts.first : link.linkName,
        taken: takenNames,
      );
      final tunnel = Tunnel(name: name, slot: slot, kind: kind);
      try {
        await _secrets.write(
          link.secret,
          SecretKey(link.secretKind, tunnel.id),
        );
      } on Object catch (error) {
        failure = 'Cannot store the ${link.secretLabel}: $error';
        break;
      }
      added.add(tunnel);
      takenNames.add(name.toLowerCase());
    }
    if (added.isNotEmpty) {
      await update(
        (store) => store.copyWith(tunnels: [...store.tunnels, ...added]),
      );
      expandedTunnelID = added.first.id;
      pendingFocus = null;
    }
    logs.app(
      LogLevel.info,
      'added ${StatusText.count(added.length, 'tunnel')} from $host',
    );
    if (failure != null) {
      final message =
          '${StatusText.count(added.length, 'tunnel')} added. '
          '$failure';
      _alert(AppAlert(title: 'Subscription import stopped', message: message));
      _changed();
      return message;
    }
    _changed();
    return null;
  }

  Future<String?> replaceLink(String tunnelID, ProxyLink link) async {
    final tunnel = _store.tunnel(tunnelID);
    if (tunnel == null) return 'Tunnel not found';
    // Identity by case, never by the badge text: this is what stops a pasted
    // link from overwriting a tunnel of another kind.
    if (!link.matches(tunnel.kind)) {
      return 'That link is a ${StatusText.typeBadge(link.tunnelKind)} link; '
          'this tunnel is ${StatusText.typeBadge(tunnel.kind)}.';
    }
    try {
      await _secrets.write(link.secret, SecretKey(link.secretKind, tunnel.id));
    } on Object catch (error) {
      return _secretsFailed('Cannot store the ${link.secretLabel}: $error');
    }
    await _updateTunnel(tunnel.id, (t) => t.copyWith(kind: link.tunnelKind));
    secretsChanged();
    logs.app(LogLevel.info, 'replaced link of ${tunnel.name}');
    return null;
  }

  /// Full link with the stored secret (for Copy); null when it is missing or
  /// the kind has no link form.
  Future<String?> linkURI(Tunnel tunnel) async {
    final secretKind = _linkSecretKind(tunnel.kind);
    if (secretKind == null) return null;
    final String? secret;
    try {
      secret = await _secrets.read(SecretKey(secretKind, tunnel.id));
    } on Object {
      return null;
    }
    if (secret == null) return null;
    return _linkURI(tunnel, secret);
  }

  /// The link with its secret masked, for display.
  String maskedLinkURI(Tunnel tunnel) => _linkURI(tunnel, '••••••••') ?? '';

  static SecretKind? _linkSecretKind(TunnelKind kind) => switch (kind) {
    TunnelKindVLESS() || TunnelKindVMess() => SecretKind.uuid,
    TunnelKindShadowsocks() || TunnelKindTrojan() => SecretKind.password,
    _ => null,
  };

  static String? _linkURI(Tunnel tunnel, String secret) =>
      switch (tunnel.kind) {
        TunnelKindVLESS(:final meta) => VLESSURIParser.uri(
          meta,
          secret,
          tunnel.name,
        ),
        TunnelKindShadowsocks(:final meta) => ProxyLinkParser.shadowsocksURI(
          meta,
          secret,
          tunnel.name,
        ),
        TunnelKindTrojan(:final meta) => ProxyLinkParser.trojanURI(
          meta,
          secret,
          tunnel.name,
        ),
        TunnelKindVMess(:final meta) => ProxyLinkParser.vmessURI(
          meta,
          secret,
          tunnel.name,
        ),
        _ => null,
      };

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

  /// `taken` holds lowercased names claimed earlier in the same batch, before
  /// they reach the store.
  String uniqueName(String base, {Set<String> taken = const {}}) {
    var candidate = base.trim();
    if (candidate.length > Tunnel.nameMaxLength) {
      candidate = candidate.substring(0, Tunnel.nameMaxLength);
    }
    if (candidate.isEmpty) candidate = 'Tunnel';
    bool available(String name) =>
        _store.isNameAvailable(name) && !taken.contains(name.toLowerCase());
    if (available(candidate)) return candidate;
    var n = 2;
    while (true) {
      final suffix = ' ($n)';
      final room = Tunnel.nameMaxLength - suffix.length;
      final trimmed = candidate.length > room
          ? candidate.substring(0, room)
          : candidate;
      final attempt = '$trimmed$suffix';
      if (available(attempt)) return attempt;
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

extension _ProxyLinkTunnel on ProxyLink {
  String get secret => switch (this) {
    ProxyLinkVLESS(:final result) => result.uuid,
    ProxyLinkShadowsocks(:final result) => result.password,
    ProxyLinkTrojan(:final result) => result.password,
    ProxyLinkVMess(:final result) => result.uuid,
  };

  SecretKind get secretKind => switch (this) {
    ProxyLinkVLESS() || ProxyLinkVMess() => SecretKind.uuid,
    ProxyLinkShadowsocks() || ProxyLinkTrojan() => SecretKind.password,
  };

  String get secretLabel => switch (this) {
    ProxyLinkVLESS() || ProxyLinkVMess() => 'UUID',
    ProxyLinkShadowsocks() || ProxyLinkTrojan() => 'password',
  };

  bool matches(TunnelKind kind) => switch ((this, kind)) {
    (ProxyLinkVLESS(), TunnelKindVLESS()) => true,
    (ProxyLinkShadowsocks(), TunnelKindShadowsocks()) => true,
    (ProxyLinkTrojan(), TunnelKindTrojan()) => true,
    (ProxyLinkVMess(), TunnelKindVMess()) => true,
    _ => false,
  };
}
