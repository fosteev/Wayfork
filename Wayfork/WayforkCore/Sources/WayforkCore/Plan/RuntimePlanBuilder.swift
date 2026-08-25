import Foundation

/// Secrets needed to turn a `Store` into a `RuntimePlan`, keyed by tunnel id.
public struct PlanSecrets: Sendable, Equatable {
    public var vlessUUIDs: [UUID: String]
    public var openVPNConfigs: [UUID: String]
    public var credentials: [UUID: Credentials]
    public var keyPassphrases: [UUID: String]

    public init(
        vlessUUIDs: [UUID: String] = [:],
        openVPNConfigs: [UUID: String] = [:],
        credentials: [UUID: Credentials] = [:],
        keyPassphrases: [UUID: String] = [:]
    ) {
        self.vlessUUIDs = vlessUUIDs
        self.openVPNConfigs = openVPNConfigs
        self.credentials = credentials
        self.keyPassphrases = keyPassphrases
    }

    /// Loads every secret the enabled tunnels of `store` need.
    public static func load(for store: Store, from secretStore: any SecretStore) throws
        -> PlanSecrets
    {
        var secrets = PlanSecrets()
        for tunnel in store.tunnels where tunnel.isEnabled {
            switch tunnel.kind {
            case .openVPN(let meta):
                if let body = try secretStore.read(.ovpn(tunnel.id)) {
                    secrets.openVPNConfigs[tunnel.id] = body
                }
                if meta.needsCredentials, let json = try secretStore.read(.credentials(tunnel.id)),
                    let credentials = try? JSONCoding.decoder.decode(
                        Credentials.self, from: Data(json.utf8))
                {
                    secrets.credentials[tunnel.id] = credentials
                }
                if meta.needsKeyPassphrase,
                    let passphrase = try secretStore.read(.keyPassphrase(tunnel.id))
                {
                    secrets.keyPassphrases[tunnel.id] = passphrase
                }
            case .vless:
                if let uuid = try secretStore.read(.uuid(tunnel.id)) {
                    secrets.vlessUUIDs[tunnel.id] = uuid
                }
            }
        }
        return secrets
    }
}

/// Why an enabled tunnel was left out of the plan.
public enum PlanWarning: Sendable, Equatable, Hashable {
    /// The OpenVPN config body or the VLESS UUID is missing from Keychain (e.g. imported
    /// without secrets). The UI flags the tunnel as needing its secret re-attached.
    case missingSecret(tunnelID: UUID)
}

public struct RuntimePlanBuildResult: Sendable, Equatable {
    public var plan: RuntimePlan
    public var warnings: [PlanWarning]
    /// Tunnels that are part of the plan, in store order.
    public var routedTunnels: [Tunnel]
}

/// Store + secrets → desired runtime state (docs/design/00-architecture.md, "Runtime plan").
public enum RuntimePlanBuilder {
    public static func openVPNBinaryPath(bundlePath: String) -> String {
        bundlePath + "/Contents/Resources/bin/openvpn"
    }

    public static func build(store: Store, secrets: PlanSecrets, bundlePath: String)
        -> RuntimePlanBuildResult
    {
        var warnings: [PlanWarning] = []
        var openVPN: [OpenVPNRuntime] = []
        var effectiveStore = store

        // OpenVPN tunnels without a config body cannot run: treat them as disabled so the
        // sing-box config does not reference an interface that will never come up.
        for index in effectiveStore.tunnels.indices {
            let tunnel = effectiveStore.tunnels[index]
            guard tunnel.isEnabled else { continue }
            switch tunnel.kind {
            case .openVPN:
                guard let config = secrets.openVPNConfigs[tunnel.id],
                    let interface = tunnel.interfaceName
                else {
                    warnings.append(.missingSecret(tunnelID: tunnel.id))
                    effectiveStore.tunnels[index].isEnabled = false
                    continue
                }
                openVPN.append(
                    OpenVPNRuntime(
                        id: tunnel.id.uuidString.lowercased(),
                        interface: interface,
                        config: config,
                        credentials: secrets.credentials[tunnel.id],
                        keyPassphrase: secrets.keyPassphrases[tunnel.id]))
            case .vless:
                if secrets.vlessUUIDs[tunnel.id] == nil {
                    warnings.append(.missingSecret(tunnelID: tunnel.id))
                    effectiveStore.tunnels[index].isEnabled = false
                }
            }
        }

        let generated = SingBoxConfigGenerator.generate(
            SingBoxConfigGenerator.Input(
                store: effectiveStore,
                vlessUUIDs: secrets.vlessUUIDs,
                openVPNBinaryPath: openVPNBinaryPath(bundlePath: bundlePath)))
        let plan = RuntimePlan(
            singBox: SingBoxPlan(config: generated.config, ruleSets: generated.ruleSets),
            openVPN: openVPN,
            autoReconnect: store.settings.autoReconnect,
            logLevel: store.settings.logLevel)
        return RuntimePlanBuildResult(
            plan: plan, warnings: warnings, routedTunnels: generated.routedTunnels)
    }
}
