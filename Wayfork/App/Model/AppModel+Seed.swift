import Foundation
import WayforkCore

// Developer seeding: on launch, import every profile under the directory named by the
// `WayforkSeedDirectory` default (scripts/dev-seed.sh) that the store does not have yet.

extension AppModel {
    static let seedDirectoryDefaultsKey = "WayforkSeedDirectory"

    /// Imports VPN configs and proxy links under the seed directory, skipping duplicates.
    /// Silent: problems go to the log, nothing is shown. No-op without the default.
    func seedFromDirectory() {
        guard !persistenceDisabled,
            let path = UserDefaults.standard.string(forKey: AppModel.seedDirectoryDefaultsKey),
            !path.isEmpty
        else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else {
            logs.app(.warning, "seed directory not readable: \(path)")
            return
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            files.append(url)
        }
        files.sort { $0.path < $1.path }
        var added = 0
        for url in files where url.pathExtension.lowercased() == "ovpn" {
            if seedOpenVPN(url) { added += 1 }
        }
        for url in files where url.pathExtension.lowercased() == "conf" {
            if seedWireGuard(url) { added += 1 }
        }
        for url in files where url.pathExtension.lowercased() == "txt" {
            added += seedLinkLines(url)
        }
        if added > 0 {
            logs.app(.info, "seeded \(added) new tunnels from \(path)")
        }
    }

    private func seedOpenVPN(_ url: URL) -> Bool {
        guard let slot = store.nextFreeSlot() else { return false }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = try OpenVPNConfigParser.parse(
                text, baseDirectory: url.deletingLastPathComponent())
            if store.tunnels.contains(where: {
                $0.kind.openVPN?.configHash == result.meta.configHash
            }) {
                return false
            }
            let tunnel = Tunnel(
                name: uniqueName(url.deletingPathExtension().lastPathComponent), slot: slot,
                kind: .openVPN(result.meta))
            try secrets.write(result.sanitizedConfig, for: .ovpn(tunnel.id))
            if let credentials = result.credentials {
                try secrets.writeCredentials(credentials, for: tunnel.id)
            }
            update { $0.tunnels.append(tunnel) }
            return true
        } catch {
            logs.app(.warning, "seed: skipped \(url.lastPathComponent): \(error)")
            return false
        }
    }

    private func seedWireGuard(_ url: URL) -> Bool {
        guard let slot = store.nextFreeSlot() else { return false }
        do {
            let result = try WireGuardConfParser.parse(
                String(contentsOf: url, encoding: .utf8))
            if store.tunnels.contains(where: { $0.kind.wireGuard == result.meta }) {
                return false
            }
            let tunnel = Tunnel(
                name: uniqueName(url.deletingPathExtension().lastPathComponent), slot: slot,
                kind: .wireGuard(result.meta))
            try secrets.write(result.privateKey, for: .privateKey(tunnel.id))
            if let presharedKey = result.presharedKey {
                try secrets.write(presharedKey, for: .presharedKey(tunnel.id))
            }
            update { $0.tunnels.append(tunnel) }
            return true
        } catch {
            logs.app(.warning, "seed: skipped \(url.lastPathComponent): \(error)")
            return false
        }
    }

    private func seedLinkLines(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var added = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard
                ["vless://", "ss://", "trojan://", "vmess://"].contains(where: {
                    line.lowercased().hasPrefix($0)
                })
            else { continue }
            guard let slot = store.nextFreeSlot() else { break }
            do {
                let link = try ProxyLinkParser.parse(line)
                let values: (TunnelKind, String, String, SecretKeyKind)
                switch link {
                case .vless(let result):
                    values = (.vless(result.meta), result.name, result.uuid, .uuid)
                case .shadowsocks(let result):
                    values = (.shadowsocks(result.meta), result.name, result.password, .password)
                case .trojan(let result):
                    values = (.trojan(result.meta), result.name, result.password, .password)
                case .vmess(let result):
                    values = (.vmess(result.meta), result.name, result.uuid, .uuid)
                }
                if store.tunnels.contains(where: { $0.kind == values.0 }) { continue }
                let server = values.0.serverHosts.first ?? "Tunnel"
                let tunnel = Tunnel(
                    name: uniqueName(values.1.isEmpty ? server : values.1), slot: slot,
                    kind: values.0)
                let key: SecretKey =
                    values.3 == .uuid ? .uuid(tunnel.id) : .password(tunnel.id)
                try secrets.write(values.2, for: key)
                update { $0.tunnels.append(tunnel) }
                added += 1
            } catch {
                let name = line.split(separator: "#").last.map(String.init) ?? "?"
                logs.app(
                    .warning,
                    "seed: skipped \(name.removingPercentEncoding ?? name) from \(url.lastPathComponent): \(error)"
                )
            }
        }
        return added
    }
}

private enum SecretKeyKind {
    case uuid
    case password
}
