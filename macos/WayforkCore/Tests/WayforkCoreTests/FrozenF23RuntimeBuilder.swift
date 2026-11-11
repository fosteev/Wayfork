// Frozen pre-F24 runtime builder, including secret filtering before validation.
import Foundation

@testable import WayforkCore

enum FrozenF23RuntimeBuilder {
    public static func openVPNBinaryPath(bundlePath: String) -> String {
        bundlePath + "/Contents/Resources/bin/openvpn"
    }

    public static func xrayBinaryPath(bundlePath: String) -> String {
        bundlePath + "/Contents/Resources/bin/xray"
    }

    /// The bundled block list (F18); the daemon derives the same path from its own bundle
    /// and accepts no other (trust rule 3).
    public static func blockListPath(bundlePath: String) -> String {
        bundlePath + "/Contents/Resources/rulesets/block-ads.srs"
    }

    /// `resolvedServerAddresses`: IPv4 addresses of OpenVPN and WireGuard server hosts from
    /// `HostResolver.resolveIPv4(HostResolver.serverHosts(in: store))`; empty when the
    /// caller could not resolve (the servers are then matched by name only).
    /// `systemDNSServers`: `SystemDNS.Snapshot.routable(override:)`, routed into the TUN by
    /// the generator. `networkResolvers`: `Snapshot.networkServers`, named as `dns-direct`.
    /// `blockListAvailable`: whether `blockListPath(bundlePath:)` exists in this build; with
    /// the switch on and no list the plan carries no block rules (`blocklist.missing`).
    public static func build(
        store: Store, secrets: PlanSecrets, bundlePath: String,
        resolvedServerAddresses: [String: [String]] = [:], systemDNSServers: [String] = [],
        networkResolvers: [String] = [], blockListAvailable: Bool = false
    ) -> RuntimePlanBuildResult {
        var warnings: [PlanWarning] = []
        var openVPN: [OpenVPNRuntime] = []
        var xray: [XrayRuntime] = []
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
            case .vless(let meta):
                guard let uuid = secrets.vlessUUIDs[tunnel.id] else {
                    warnings.append(.missingSecret(tunnelID: tunnel.id))
                    effectiveStore.tunnels[index].isEnabled = false
                    continue
                }
                // XHTTP: sing-box dials a loopback SOCKS port; this process answers it.
                if let port = tunnel.xrayPort,
                    let config = XrayConfigGenerator.generate(meta: meta, uuid: uuid, port: port)
                {
                    xray.append(
                        XrayRuntime(
                            id: tunnel.id.uuidString.lowercased(), port: port, config: config))
                }
            case .wireGuard:
                if secrets.wireGuardKeys[tunnel.id] == nil {
                    warnings.append(.missingSecret(tunnelID: tunnel.id))
                    effectiveStore.tunnels[index].isEnabled = false
                }
            case .shadowsocks, .trojan:
                if secrets.passwords[tunnel.id] == nil {
                    warnings.append(.missingSecret(tunnelID: tunnel.id))
                    effectiveStore.tunnels[index].isEnabled = false
                }
            case .vmess:
                if secrets.vmessUUIDs[tunnel.id] == nil {
                    warnings.append(.missingSecret(tunnelID: tunnel.id))
                    effectiveStore.tunnels[index].isEnabled = false
                }
            }
        }

        let generated = FrozenF23Generator.generate(
            FrozenF23Generator.Input(
                store: effectiveStore,
                vlessUUIDs: secrets.vlessUUIDs,
                wireGuardKeys: secrets.wireGuardKeys,
                passwords: secrets.passwords,
                vmessUUIDs: secrets.vmessUUIDs,
                openVPNBinaryPath: openVPNBinaryPath(bundlePath: bundlePath),
                xrayBinaryPath: xrayBinaryPath(bundlePath: bundlePath),
                resolvedServerAddresses: resolvedServerAddresses,
                systemDNSServers: systemDNSServers,
                networkResolvers: networkResolvers,
                blockListPath: blockListAvailable ? blockListPath(bundlePath: bundlePath) : nil))
        let plan = RuntimePlan(
            singBox: SingBoxPlan(config: generated.config, ruleSets: generated.ruleSets),
            openVPN: openVPN,
            xray: xray,
            autoReconnect: store.settings.autoReconnect,
            logLevel: store.settings.logLevel,
            overrideSystemDNS: store.settings.overrideSystemDNS)
        return RuntimePlanBuildResult(
            plan: plan, warnings: warnings, routedTunnels: generated.routedTunnels)
    }
}
