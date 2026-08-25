import AppKit
import Foundation
import UniformTypeIdentifiers
import WayforkCore

// Tunnel management (F1): import, edit, enable/disable, delete.

extension AppModel {
    static let ovpnType = UTType(filenameExtension: "ovpn") ?? .data

    // MARK: - OpenVPN

    /// Presents the file picker and imports the chosen profile.
    func importOpenVPNFromPicker() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AppModel.ovpnType, .text, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an OpenVPN profile (.ovpn)"
        NSApp.activate(ignoringOtherApps: true)
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await importOpenVPN(from: url)
    }

    func importOpenVPN(from url: URL) async {
        guard let result = await parseOpenVPN(at: url) else { return }
        guard let slot = store.nextFreeSlot() else {
            Alerts.show(
                title: "Tunnel limit reached",
                message: "Wayfork supports up to \(Tunnel.maxSlots) tunnels.")
            return
        }
        let name = uniqueName(url.deletingPathExtension().lastPathComponent)
        let tunnel = Tunnel(name: name, slot: slot, kind: .openVPN(result.meta))
        do {
            try secrets.write(result.sanitizedConfig, for: .ovpn(tunnel.id))
            if let credentials = result.credentials {
                try secrets.writeCredentials(credentials, for: tunnel.id)
            }
        } catch {
            Alerts.show(title: "Keychain error", message: "Cannot store the config: \(error)")
            return
        }
        update { $0.tunnels.append(tunnel) }
        logs.app(
            .info,
            "imported OpenVPN tunnel \(name)"
                + (result.strippedDirectives.isEmpty
                    ? "" : " (stripped: \(result.strippedDirectives.joined(separator: ", ")))"))
        settingsSection = .tunnels
        expandedTunnelID = tunnel.id
        if result.meta.needsCredentials, result.credentials == nil {
            pendingFocus = .username
        } else if result.meta.needsKeyPassphrase {
            pendingFocus = .keyPassphrase
        }
    }

    func replaceOpenVPNConfigFromPicker(tunnelID: UUID) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AppModel.ovpnType, .text, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the replacement OpenVPN profile"
        NSApp.activate(ignoringOtherApps: true)
        guard await panel.begin() == .OK, let url = panel.url else { return }
        guard let result = await parseOpenVPN(at: url),
            let index = store.tunnels.firstIndex(where: { $0.id == tunnelID }),
            case .openVPN(let old) = store.tunnels[index].kind
        else { return }
        var meta = result.meta
        meta.dns = old.dns
        do {
            try secrets.write(result.sanitizedConfig, for: .ovpn(tunnelID))
            if let credentials = result.credentials {
                try secrets.writeCredentials(credentials, for: tunnelID)
            }
        } catch {
            Alerts.show(title: "Keychain error", message: "Cannot store the config: \(error)")
            return
        }
        update { $0.tunnels[index].kind = .openVPN(meta) }
        secretsChanged()
        logs.app(.info, "replaced config of \(store.tunnels[index].name)")
    }

    /// Parses a profile, asking for the folder with referenced files when they are missing
    /// (`import.ovpn.missingFiles`).
    private func parseOpenVPN(at url: URL) async -> OpenVPNImportResult? {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            Alerts.show(title: "Cannot read file", message: error.localizedDescription)
            return nil
        }
        var base = url.deletingLastPathComponent()
        while true {
            do {
                return try OpenVPNConfigParser.parse(text, baseDirectory: base)
            } catch OpenVPNImportError.missingFiles(let names) {
                let choice = Alerts.show(
                    title: "Referenced files not found",
                    message:
                        "\(names.joined(separator: ", ")) referenced but not found next to the .ovpn. Choose the folder that contains them.",
                    buttons: ["Choose Folder…", "Cancel"])
                guard choice == 0 else { return nil }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.message = "Choose the folder with \(names.joined(separator: ", "))"
                guard await panel.begin() == .OK, let folder = panel.url else { return nil }
                base = folder
            } catch OpenVPNImportError.unsupported(let what) {
                Alerts.show(title: "Unsupported config", message: "\(what) is not supported.")
                return nil
            } catch OpenVPNImportError.noRemote {
                Alerts.show(
                    title: "Invalid config", message: "The profile has no `remote` directive.")
                return nil
            } catch OpenVPNImportError.malformed(let line, let reason) {
                Alerts.show(title: "Invalid config", message: "Line \(line): \(reason)")
                return nil
            } catch {
                Alerts.show(title: "Invalid config", message: "\(error)")
                return nil
            }
        }
    }

    func credentials(for tunnelID: UUID) -> Credentials? {
        (try? secrets.readCredentials(for: tunnelID)) ?? nil
    }

    func setCredentials(tunnelID: UUID, username: String, password: String) {
        do {
            if username.isEmpty && password.isEmpty {
                try secrets.delete(.credentials(tunnelID))
            } else {
                try secrets.writeCredentials(
                    Credentials(username: username, password: password), for: tunnelID)
            }
            secretsChanged()
        } catch {
            Alerts.show(title: "Keychain error", message: "\(error)")
        }
    }

    func keyPassphrase(for tunnelID: UUID) -> String? {
        (try? secrets.read(.keyPassphrase(tunnelID))) ?? nil
    }

    func setKeyPassphrase(tunnelID: UUID, passphrase: String) {
        do {
            if passphrase.isEmpty {
                try secrets.delete(.keyPassphrase(tunnelID))
            } else {
                try secrets.write(passphrase, for: .keyPassphrase(tunnelID))
            }
            secretsChanged()
        } catch {
            Alerts.show(title: "Keychain error", message: "\(error)")
        }
    }

    func setDNS(tunnelID: UUID, dns: TunnelDNS) {
        update { store in
            guard let index = store.tunnels.firstIndex(where: { $0.id == tunnelID }),
                case .openVPN(var meta) = store.tunnels[index].kind
            else { return }
            meta.dns = dns
            store.tunnels[index].kind = .openVPN(meta)
        }
    }

    // MARK: - VLESS

    /// Adds a tunnel from an already validated `vless://` URI.
    func addVLESS(_ result: VLESSImportResult) {
        guard let slot = store.nextFreeSlot() else {
            Alerts.show(
                title: "Tunnel limit reached",
                message: "Wayfork supports up to \(Tunnel.maxSlots) tunnels.")
            return
        }
        let name = uniqueName(result.name.isEmpty ? result.meta.server : result.name)
        let tunnel = Tunnel(name: name, slot: slot, kind: .vless(result.meta))
        do {
            try secrets.write(result.uuid, for: .uuid(tunnel.id))
        } catch {
            Alerts.show(title: "Keychain error", message: "Cannot store the UUID: \(error)")
            return
        }
        update { $0.tunnels.append(tunnel) }
        logs.app(.info, "added VLESS tunnel \(name)")
        settingsSection = .tunnels
        expandedTunnelID = tunnel.id
    }

    func replaceVLESS(tunnelID: UUID, with result: VLESSImportResult) {
        guard let index = store.tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
        do {
            try secrets.write(result.uuid, for: .uuid(tunnelID))
        } catch {
            Alerts.show(title: "Keychain error", message: "Cannot store the UUID: \(error)")
            return
        }
        update { $0.tunnels[index].kind = .vless(result.meta) }
        secretsChanged()
        logs.app(.info, "replaced URL of \(store.tunnels[index].name)")
    }

    /// Full `vless://` URI with the UUID from Keychain (for Copy); nil when it is missing.
    func vlessURI(for tunnel: Tunnel) -> String? {
        guard let meta = tunnel.kind.vless, let uuid = (try? secrets.read(.uuid(tunnel.id))) ?? nil
        else { return nil }
        return VLESSURIParser.uri(meta: meta, uuid: uuid, name: tunnel.name)
    }

    /// The URI with the UUID masked, for display.
    func maskedVLESSURI(for tunnel: Tunnel) -> String {
        guard let meta = tunnel.kind.vless else { return "" }
        return VLESSURIParser.uri(meta: meta, uuid: "••••••••", name: tunnel.name)
    }

    // MARK: - Common

    /// Returns an error message, or nil when the rename went through.
    @discardableResult
    func rename(tunnelID: UUID, to rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Name can't be empty" }
        guard name.count <= Tunnel.nameMaxLength else {
            return "Name is limited to \(Tunnel.nameMaxLength) characters"
        }
        guard store.isNameAvailable(name, excluding: tunnelID) else {
            return "Another tunnel is already called \(name)"
        }
        update { store in
            guard let index = store.tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
            store.tunnels[index].name = name
        }
        return nil
    }

    func setEnabled(tunnelID: UUID, _ enabled: Bool) {
        update { store in
            guard let index = store.tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
            store.tunnels[index].isEnabled = enabled
        }
    }

    /// Asks for confirmation when rules are attached, then removes the tunnel, its rules and
    /// its Keychain items.
    func deleteTunnel(_ tunnelID: UUID) {
        guard let tunnel = store.tunnel(id: tunnelID) else { return }
        let rules = ruleCount(for: tunnelID)
        let message =
            rules > 0
            ? "Delete \(tunnel.name) and its \(StatusText.count(rules, "rule"))? The rules go with it."
            : "Delete \(tunnel.name)?"
        guard Alerts.confirm(title: "Delete tunnel", message: message, destructive: "Delete")
        else { return }
        update { store in
            store.tunnels.removeAll { $0.id == tunnelID }
            store.rules.removeAll { $0.tunnelID == tunnelID }
        }
        try? secrets.deleteAll(for: tunnelID)
        if expandedTunnelID == tunnelID { expandedTunnelID = nil }
        logs.app(.info, "deleted tunnel \(tunnel.name)")
    }

    func uniqueName(_ base: String) -> String {
        var candidate = String(
            base.trimmingCharacters(in: .whitespacesAndNewlines).prefix(
                Tunnel.nameMaxLength))
        if candidate.isEmpty { candidate = "Tunnel" }
        guard !store.isNameAvailable(candidate) else { return candidate }
        var n = 2
        while true {
            let suffix = " (\(n))"
            let trimmed = String(candidate.prefix(Tunnel.nameMaxLength - suffix.count))
            let attempt = trimmed + suffix
            if store.isNameAvailable(attempt) { return attempt }
            n += 1
        }
    }
}
