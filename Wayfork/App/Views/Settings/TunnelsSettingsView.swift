import AppKit
import SwiftUI
import WayforkCore

/// Settings › Tunnels: rows that expand in place (docs/design/02-ux.md, "Tunnels").
struct TunnelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var vlessSheet: AddVLESSSheet.Mode?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PageTitle(text: "Tunnels")
                Spacer()
                Menu {
                    Button("Import OpenVPN Config…") {
                        Task { await model.importOpenVPNFromPicker() }
                    }
                    Button("Add VLESS from URL…") { vlessSheet = .add }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .fixedSize()
            }
            if model.store.tunnels.isEmpty {
                Text(
                    "No tunnels yet. Import an OpenVPN config or add a VLESS URL with + Add, or drop a .ovpn file here."
                )
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.store.tunnels.enumerated()), id: \.element.id) {
                            index, tunnel in
                            if index > 0 { Divider() }
                            TunnelRowView(tunnel: tunnel)
                            if model.expandedTunnelID == tunnel.id {
                                if tunnel.kind.isOpenVPN {
                                    OpenVPNDetailView(tunnel: tunnel)
                                } else {
                                    VLESSDetailView(
                                        tunnel: tunnel,
                                        replace: { vlessSheet = .replace(tunnel.id) })
                                }
                            }
                        }
                    }
                    .background(GroupBackground())
                }
            }
        }
        .padding(20)
        .sheet(item: $vlessSheet) { mode in
            AddVLESSSheet(mode: mode)
        }
    }
}

/// Header row of a tunnel: glyph, name, badge, summary, enabled toggle, chevron.
struct TunnelRowView: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel

    var body: some View {
        let summary = model.rowSummary(for: tunnel)
        let expanded = model.expandedTunnelID == tunnel.id
        HStack(spacing: 10) {
            StatusGlyphView(glyph: summary.glyph)
            Text(tunnel.name).fontWeight(.semibold).lineLimit(1)
                .frame(minWidth: 70, alignment: .leading)
            TypeBadge(kind: tunnel.kind)
            Text(summary.text)
                .font(.system(size: 12))
                .foregroundStyle(summary.isError ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { tunnel.isEnabled },
                    set: { model.setEnabled(tunnelID: tunnel.id, $0) })
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                model.expandedTunnelID = expanded ? nil : tunnel.id
            }
        }
    }
}

/// Expanded OpenVPN tunnel: name, credentials, DNS, config, footer.
struct OpenVPNDetailView: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel

    @State private var name = ""
    @State private var nameError: String?
    @State private var username = ""
    @State private var password = ""
    @State private var passphrase = ""
    @State private var dnsMode = 0
    @State private var customDNS = ""
    @State private var dnsError: String?
    @FocusState private var focus: AppModel.TunnelField?

    private var meta: OpenVPNMeta {
        tunnel.kind.openVPN
            ?? OpenVPNMeta(
                remotes: [], needsCredentials: false, needsKeyPassphrase: false, configHash: "")
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label("Name")
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($focus, equals: .name)
                        .onSubmit(commitName)
                        .invalidOutline(nameError != nil)
                    if let nameError {
                        Text(nameError).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
            }
            if meta.needsCredentials {
                GridRow {
                    label("Username")
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($focus, equals: .username)
                        .onSubmit(commitCredentials)
                }
                GridRow {
                    label("Password")
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($focus, equals: .password)
                        .onSubmit(commitCredentials)
                }
            }
            if meta.needsKeyPassphrase {
                GridRow {
                    label("Key passphrase")
                    SecureField("Passphrase", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($focus, equals: .keyPassphrase)
                        .onSubmit(commitPassphrase)
                }
            }
            GridRow {
                label("DNS")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) {
                        Picker("DNS", selection: $dnsMode) {
                            Text(automaticLabel).tag(0)
                            Text("Custom").tag(1)
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                        TextField("10.8.0.1", text: $customDNS)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .disabled(dnsMode != 1)
                            .focused($focus, equals: .config)
                            .onSubmit(commitDNS)
                            .invalidOutline(dnsError != nil)
                    }
                    if let dnsError {
                        Text(dnsError).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
            }
            GridRow {
                label("Config")
                HStack(spacing: 8) {
                    Text("\(tunnel.createdAt.formatted(date: .abbreviated, time: .omitted)) · ")
                        .foregroundStyle(.secondary)
                        + Text(shortHash).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Replace…") {
                        Task { await model.replaceOpenVPNConfigFromPicker(tunnelID: tunnel.id) }
                    }
                    .controlSize(.small)
                }
            }
            GridRow {
                Text("")
                DefaultTunnelToggle(tunnel: tunnel)
            }
            GridRow {
                Text("")
                HStack(spacing: 8) {
                    rulesLink
                    Spacer()
                    Button("Reconnect") { model.reconnect(tunnel.id) }
                        .controlSize(.small)
                        .disabled(!model.globalState.isRunning || !tunnel.isEnabled)
                    Button("Delete…") { model.deleteTunnel(tunnel.id) }
                        .controlSize(.small)
                        .foregroundStyle(.red)
                }
            }
        }
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .onAppear(perform: load)
        .onChange(of: model.pendingFocus, initial: true) { _, pending in
            guard let pending, model.expandedTunnelID == tunnel.id else { return }
            focus = pending == .config ? nil : pending
            model.pendingFocus = nil
        }
        .onChange(of: focus) { old, _ in
            switch old {
            case .name: commitName()
            case .username, .password: commitCredentials()
            case .keyPassphrase: commitPassphrase()
            case .config: commitDNS()
            default: break
            }
        }
        .onChange(of: dnsMode) { _, mode in
            if mode == 0 {
                dnsError = nil
                model.setDNS(tunnelID: tunnel.id, dns: .auto)
            } else {
                commitDNS()
            }
        }
    }

    private var rulesLink: some View {
        HStack(spacing: 6) {
            Text(StatusText.count(model.ruleCount(for: tunnel.id), "rule"))
                .foregroundStyle(.secondary)
            Button("Show") { model.settingsSection = .rules }
                .buttonStyle(.link)
        }
    }

    private var automaticLabel: String {
        let discovered = model.discoveredDNS(for: tunnel)
        return discovered.isEmpty
            ? "Automatic" : "Automatic (\(discovered.joined(separator: ", ")))"
    }

    private var shortHash: String {
        let hash = meta.configHash
        guard hash.count > 8 else { return hash }
        return "\(hash.prefix(4))…\(hash.suffix(4))"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func load() {
        name = tunnel.name
        if let credentials = model.credentials(for: tunnel.id) {
            username = credentials.username
            password = credentials.password
        }
        passphrase = model.keyPassphrase(for: tunnel.id) ?? ""
        switch meta.dns {
        case .auto:
            dnsMode = 0
        case .custom(let servers):
            dnsMode = 1
            customDNS = servers.joined(separator: ", ")
        }
    }

    private func commitName() {
        guard name != tunnel.name else { return }
        nameError = model.rename(tunnelID: tunnel.id, to: name)
    }

    private func commitCredentials() {
        let stored = model.credentials(for: tunnel.id)
        guard stored?.username != username || stored?.password != password else { return }
        model.setCredentials(tunnelID: tunnel.id, username: username, password: password)
    }

    private func commitPassphrase() {
        guard (model.keyPassphrase(for: tunnel.id) ?? "") != passphrase else { return }
        model.setKeyPassphrase(tunnelID: tunnel.id, passphrase: passphrase)
    }

    private func commitDNS() {
        guard dnsMode == 1 else { return }
        let servers = customDNS.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !servers.isEmpty, servers.allSatisfy(isIPAddress) else {
            dnsError = servers.isEmpty ? "Enter at least one resolver address" : "Not an IP address"
            return
        }
        dnsError = nil
        if meta.dns != .custom(servers: servers) {
            model.setDNS(tunnelID: tunnel.id, dns: .custom(servers: servers))
        }
    }
}

/// Expanded VLESS tunnel: name, masked URL, footer.
struct VLESSDetailView: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel
    let replace: () -> Void

    @State private var name = ""
    @State private var nameError: String?
    @FocusState private var focus: AppModel.TunnelField?

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label("Name")
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($focus, equals: .name)
                        .onSubmit(commitName)
                        .invalidOutline(nameError != nil)
                    if let nameError {
                        Text(nameError).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
            }
            GridRow {
                label("URL")
                HStack(spacing: 8) {
                    Text(model.maskedVLESSURI(for: tunnel))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Copy") {
                        if let uri = model.vlessURI(for: tunnel) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(uri, forType: .string)
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.missingSecrets.contains(tunnel.id))
                    Button("Replace URL…", action: replace).controlSize(.small)
                }
            }
            GridRow {
                Text("")
                DefaultTunnelToggle(tunnel: tunnel)
            }
            GridRow {
                Text("")
                HStack(spacing: 8) {
                    Text(StatusText.count(model.ruleCount(for: tunnel.id), "rule"))
                        .foregroundStyle(.secondary)
                    Button("Show") { model.settingsSection = .rules }.buttonStyle(.link)
                    Spacer()
                    Button("Delete…") { model.deleteTunnel(tunnel.id) }
                        .controlSize(.small)
                        .foregroundStyle(.red)
                }
            }
        }
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .onAppear { name = tunnel.name }
        .onChange(of: model.pendingFocus, initial: true) { _, pending in
            guard let pending, model.expandedTunnelID == tunnel.id else { return }
            if pending == .url { replace() } else { focus = pending }
            model.pendingFocus = nil
        }
        .onChange(of: focus) { old, _ in
            if old == .name { commitName() }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func commitName() {
        guard name != tunnel.name else { return }
        nameError = model.rename(tunnelID: tunnel.id, to: name)
    }
}

private func isIPAddress(_ text: String) -> Bool {
    var v4 = in_addr()
    var v6 = in6_addr()
    return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
}

/// "Route everything else through this tunnel" (F8): only one tunnel can be the default;
/// turning it on here moves it from whichever tunnel had it.
private struct DefaultTunnelToggle: View {
    @Environment(AppModel.self) private var model
    let tunnel: Tunnel

    var body: some View {
        let hint = model.defaultTunnelHint(for: tunnel)
        VStack(alignment: .leading, spacing: 2) {
            Toggle(
                "Route everything else through this tunnel",
                isOn: Binding(
                    get: { model.isDefaultTunnel(tunnel.id) },
                    set: { model.setDefaultTunnel($0 ? tunnel.id : nil) })
            )
            .toggleStyle(.checkbox)
            Text(hint.text)
                .font(.system(size: 11))
                .foregroundStyle(hint.isWarning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
