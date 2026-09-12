import AppKit
import Foundation
import UniformTypeIdentifiers
import WayforkCore

// Tunnel management (F1): import, edit, enable/disable, delete.

extension AppModel {
    static let ovpnType = UTType(filenameExtension: "ovpn") ?? .data
    static let wireGuardType = UTType(filenameExtension: "conf") ?? .data

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
            guard let index = store.tunnels.firstIndex(where: { $0.id == tunnelID }) else {
                return
            }
            switch store.tunnels[index].kind {
            case .openVPN(var meta):
                meta.dns = dns
                store.tunnels[index].kind = .openVPN(meta)
            case .wireGuard(var meta):
                meta.dns = dns
                store.tunnels[index].kind = .wireGuard(meta)
            case .vless, .shadowsocks, .trojan, .vmess:
                return
            }
        }
    }

    // MARK: - WireGuard

    func importWireGuardFromPicker() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AppModel.wireGuardType, .text, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a WireGuard config (.conf)"
        NSApp.activate(ignoringOtherApps: true)
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await importWireGuard(from: url)
    }

    func importWireGuard(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            Alerts.show(title: "Cannot read file", message: error.localizedDescription)
            return
        }
        do {
            let result = try WireGuardConfParser.parse(text)
            addWireGuard(result, name: url.deletingPathExtension().lastPathComponent)
        } catch WireGuardImportError.invalid(let reason) {
            Alerts.show(
                title: "Invalid config", message: "Not a valid WireGuard config: \(reason)")
        } catch WireGuardImportError.unsupported(let reason) {
            Alerts.show(
                title: "Invalid config", message: "Not a valid WireGuard config: \(reason)")
        } catch {
            Alerts.show(
                title: "Invalid config", message: "Not a valid WireGuard config: \(error)")
        }
    }

    func addWireGuard(_ result: WireGuardImportResult, name rawName: String) {
        guard let slot = store.nextFreeSlot() else {
            Alerts.show(
                title: "Tunnel limit reached",
                message: "Wayfork supports up to \(Tunnel.maxSlots) tunnels.")
            return
        }
        let name = uniqueName(rawName.isEmpty ? result.name : rawName)
        let tunnel = Tunnel(name: name, slot: slot, kind: .wireGuard(result.meta))
        do {
            try secrets.write(result.privateKey, for: .privateKey(tunnel.id))
            if let presharedKey = result.presharedKey {
                try secrets.write(presharedKey, for: .presharedKey(tunnel.id))
            }
        } catch {
            Alerts.show(title: "Keychain error", message: "Cannot store the keys: \(error)")
            return
        }
        update { $0.tunnels.append(tunnel) }
        logs.app(.info, "added WireGuard tunnel \(name)")
        settingsSection = .tunnels
        expandedTunnelID = tunnel.id
    }

    func replaceWireGuardConfig(tunnelID: UUID, with result: WireGuardImportResult) {
        guard let index = store.tunnels.firstIndex(where: { $0.id == tunnelID }),
            case .wireGuard(let old) = store.tunnels[index].kind
        else { return }
        var meta = result.meta
        meta.dns = old.dns
        do {
            try secrets.write(result.privateKey, for: .privateKey(tunnelID))
            if let presharedKey = result.presharedKey {
                try secrets.write(presharedKey, for: .presharedKey(tunnelID))
            } else {
                try secrets.delete(.presharedKey(tunnelID))
            }
        } catch {
            Alerts.show(title: "Keychain error", message: "Cannot store the keys: \(error)")
            return
        }
        update { $0.tunnels[index].kind = .wireGuard(meta) }
        secretsChanged()
        logs.app(.info, "replaced config of \(store.tunnels[index].name)")
    }

    // MARK: - Proxy links

    func addLink(_ link: ProxyLink) {
        guard let slot = store.nextFreeSlot() else {
            Alerts.show(
                title: "Tunnel limit reached",
                message: "Wayfork supports up to \(Tunnel.maxSlots) tunnels.")
            return
        }
        let name = uniqueName(link.name.isEmpty ? link.server : link.name)
        let tunnel = Tunnel(name: name, slot: slot, kind: link.tunnelKind)
        do {
            try secrets.write(link.secret, for: link.secretKey(tunnel.id))
        } catch {
            Alerts.show(
                title: "Keychain error", message: "Cannot store the \(link.secretName): \(error)")
            return
        }
        update { $0.tunnels.append(tunnel) }
        logs.app(.info, "added \(link.kindName) tunnel \(name)")
        settingsSection = .tunnels
        expandedTunnelID = tunnel.id
    }

    /// Adds every link of a subscription in one store update (docs/design/04-tunnels.md,
    /// "Subscriptions"). Stops at the first Keychain failure, keeping what was written.
    /// `host` is all the log ever sees of the subscription URL.
    func addLinks(_ links: [ProxyLink], from host: String) {
        var added: [Tunnel] = []
        var takenNames: Set<String> = []
        var failure: String?
        for link in links {
            guard let slot = store.nextFreeSlot(excluding: added.map(\.slot)) else {
                failure = "Wayfork supports up to \(Tunnel.maxSlots) tunnels."
                break
            }
            let name = uniqueName(link.name.isEmpty ? link.server : link.name, taken: takenNames)
            let tunnel = Tunnel(name: name, slot: slot, kind: link.tunnelKind)
            do {
                try secrets.write(link.secret, for: link.secretKey(tunnel.id))
            } catch {
                failure = "Cannot store the \(link.secretName): \(error)"
                break
            }
            added.append(tunnel)
            takenNames.insert(name.lowercased())
        }
        update { $0.tunnels.append(contentsOf: added) }
        logs.app(.info, "added \(StatusText.count(added.count, "tunnel")) from \(host)")
        if let failure {
            Alerts.show(
                title: "Subscription import stopped",
                message: "\(StatusText.count(added.count, "tunnel")) added. \(failure)")
        }
        if let first = added.first {
            settingsSection = .tunnels
            expandedTunnelID = first.id
        }
    }

    func replaceLink(tunnelID: UUID, with link: ProxyLink) {
        guard let index = store.tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
        // Identity by case, not by the badge text: this guard is what keeps a pasted link
        // from overwriting a tunnel of another kind, so it must not depend on a label.
        guard link.matches(store.tunnels[index].kind) else {
            Alerts.show(
                title: "Wrong link kind",
                message: "That link is a \(link.kindName) link; this tunnel is "
                    + "\(StatusText.typeBadge(store.tunnels[index].kind)).")
            return
        }
        do {
            try secrets.write(link.secret, for: link.secretKey(tunnelID))
        } catch {
            Alerts.show(
                title: "Keychain error", message: "Cannot store the \(link.secretName): \(error)")
            return
        }
        update { $0.tunnels[index].kind = link.tunnelKind }
        secretsChanged()
        logs.app(.info, "replaced link of \(store.tunnels[index].name)")
    }

    func linkURI(for tunnel: Tunnel) -> String? {
        switch tunnel.kind {
        case .vless(let meta):
            guard let uuid = (try? secrets.read(.uuid(tunnel.id))) ?? nil else { return nil }
            return VLESSURIParser.uri(meta: meta, uuid: uuid, name: tunnel.name)
        case .shadowsocks(let meta):
            guard let password = (try? secrets.read(.password(tunnel.id))) ?? nil else {
                return nil
            }
            return ProxyLinkParser.uri(meta: meta, password: password, name: tunnel.name)
        case .trojan(let meta):
            guard let password = (try? secrets.read(.password(tunnel.id))) ?? nil else {
                return nil
            }
            return ProxyLinkParser.uri(meta: meta, password: password, name: tunnel.name)
        case .vmess(let meta):
            guard let uuid = (try? secrets.read(.uuid(tunnel.id))) ?? nil else { return nil }
            return ProxyLinkParser.uri(meta: meta, uuid: uuid, name: tunnel.name)
        case .openVPN, .wireGuard:
            return nil
        }
    }

    func maskedLinkURI(for tunnel: Tunnel) -> String {
        switch tunnel.kind {
        case .vless(let meta):
            VLESSURIParser.uri(meta: meta, uuid: "••••••••", name: tunnel.name)
        case .shadowsocks(let meta):
            ProxyLinkParser.uri(meta: meta, password: "••••••••", name: tunnel.name)
        case .trojan(let meta):
            ProxyLinkParser.uri(meta: meta, password: "••••••••", name: tunnel.name)
        case .vmess(let meta):
            ProxyLinkParser.uri(meta: meta, uuid: "••••••••", name: tunnel.name)
        case .openVPN, .wireGuard:
            ""
        }
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
            if store.defaultTunnelID == tunnelID { store.defaultTunnelID = nil }
        }
        try? secrets.deleteAll(for: tunnelID)
        if expandedTunnelID == tunnelID { expandedTunnelID = nil }
        logs.app(.info, "deleted tunnel \(tunnel.name)")
    }

    /// `taken` holds lowercased names claimed earlier in the same batch, before they reach
    /// the store.
    func uniqueName(_ base: String, taken: Set<String> = []) -> String {
        var candidate = String(
            base.trimmingCharacters(in: .whitespacesAndNewlines).prefix(
                Tunnel.nameMaxLength))
        if candidate.isEmpty { candidate = "Tunnel" }
        let available = { (name: String) in
            self.store.isNameAvailable(name) && !taken.contains(name.lowercased())
        }
        guard !available(candidate) else { return candidate }
        var n = 2
        while true {
            let suffix = " (\(n))"
            let trimmed = String(candidate.prefix(Tunnel.nameMaxLength - suffix.count))
            let attempt = trimmed + suffix
            if available(attempt) { return attempt }
            n += 1
        }
    }
}

extension ProxyLink {
    fileprivate var kindName: String { StatusText.typeBadge(tunnelKind) }

    /// Whether this link could replace a tunnel of that kind.
    fileprivate func matches(_ kind: TunnelKind) -> Bool {
        switch (self, kind) {
        case (.vless, .vless), (.shadowsocks, .shadowsocks), (.trojan, .trojan),
            (.vmess, .vmess):
            true
        default:
            false
        }
    }

    fileprivate var secret: String {
        switch self {
        case .vless(let result): result.uuid
        case .shadowsocks(let result): result.password
        case .trojan(let result): result.password
        case .vmess(let result): result.uuid
        }
    }

    fileprivate var secretName: String {
        switch self {
        case .vless, .vmess: "UUID"
        case .shadowsocks, .trojan: "password"
        }
    }

    fileprivate func secretKey(_ tunnelID: UUID) -> SecretKey {
        switch self {
        case .vless, .vmess: .uuid(tunnelID)
        case .shadowsocks, .trojan: .password(tunnelID)
        }
    }
}
