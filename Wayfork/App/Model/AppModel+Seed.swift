import Foundation
import WayforkCore

// Developer seeding: on launch, import every profile under the directory named by the
// `WayforkSeedDirectory` default (scripts/dev-seed.sh) that the store does not have yet.

extension AppModel {
    static let seedDirectoryDefaultsKey = "WayforkSeedDirectory"

    /// Imports `*.ovpn` and `vless://` lines from `*.txt` under the seed directory, skipping
    /// profiles already present (same sanitized OpenVPN body / same VLESS metadata).
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
        for url in files where url.pathExtension.lowercased() == "txt" {
            added += seedVLESSLines(url)
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

    private func seedVLESSLines(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var added = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("vless://") else { continue }
            guard let slot = store.nextFreeSlot() else { break }
            do {
                let result = try VLESSURIParser.parse(line)
                if store.tunnels.contains(where: { $0.kind.vless == result.meta }) { continue }
                let tunnel = Tunnel(
                    name: uniqueName(result.name.isEmpty ? result.meta.server : result.name),
                    slot: slot, kind: .vless(result.meta))
                try secrets.write(result.uuid, for: .uuid(tunnel.id))
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
