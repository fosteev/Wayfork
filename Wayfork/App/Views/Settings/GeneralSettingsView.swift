import AppKit
import SwiftUI
import WayforkCore

/// Settings › General (docs/design/02-ux.md, "General").
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var customDNS = ""
    @State private var dnsError: String?
    @State private var retentionDays = 7
    @State private var exportSheet = false
    @State private var diagnosticsSheet = false
    @State private var importDocument: ExportDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageTitle(text: "General").padding(.horizontal, 20).padding(.top, 20)
            Form {
                Section("Startup") {
                    Toggle("Launch Wayfork at login", isOn: setting(\.launchAtLogin))
                    Toggle("Connect on launch", isOn: setting(\.connectOnLaunch))
                }
                Section("Reliability") {
                    Toggle("Reconnect tunnels automatically", isOn: setting(\.autoReconnect))
                    Toggle("Notify when a tunnel fails", isOn: setting(\.notifyOnTunnelFailure))
                }
                Section("DNS") {
                    Toggle(
                        "Use Wayfork as the system resolver while On",
                        isOn: setting(\.overrideSystemDNS))
                    Picker("Direct traffic resolver", selection: dnsMode) {
                        Text("System").tag(0)
                        Text("Custom").tag(1)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    if case .custom = model.settings.directDNS {
                        LabeledContent("Resolvers") {
                            VStack(alignment: .trailing, spacing: 2) {
                                TextField("1.1.1.1, 9.9.9.9", text: $customDNS)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                    .onSubmit(commitDNS)
                                    .invalidOutline(dnsError != nil)
                                if let dnsError {
                                    Text(dnsError).font(.system(size: 11)).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                Section("Logs") {
                    Picker("Level", selection: setting(\.logLevel)) {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Text(level.rawValue.capitalized).tag(level)
                        }
                    }
                    .frame(maxWidth: 260)
                    if model.settings.logLevel == .debug {
                        Text("Debug logs may include hostnames.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    LabeledContent("Keep logs for") {
                        HStack(spacing: 6) {
                            TextField("7", value: $retentionDays, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .onSubmit(commitRetention)
                            Stepper("days", value: $retentionDays, in: 1...365)
                                .onChange(of: retentionDays) { commitRetention() }
                            Button("Open Logs Folder") {
                                try? FileManager.default.createDirectory(
                                    at: LogCenter.directory, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(LogCenter.directory)
                            }
                        }
                    }
                }
                Section("Helper & About") {
                    helperRow
                    LabeledContent {
                        Button("Export Diagnostics…") { diagnosticsSheet = true }
                    } label: {
                        Text("Wayfork \(model.appVersion)")
                        Text(binaryVersions).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Section("Backup") {
                    LabeledContent("Tunnels and rules") {
                        HStack {
                            Button("Export…") { exportSheet = true }
                            Button("Import…") {
                                Task { importDocument = await model.pickImportDocument() }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            retentionDays = model.settings.logRetentionDays
            if case .custom(let servers) = model.settings.directDNS {
                customDNS = servers.joined(separator: ", ")
            }
            model.refreshHelperState()
        }
        .sheet(isPresented: $exportSheet) { ExportSheet() }
        .sheet(isPresented: $diagnosticsSheet) { DiagnosticsSheet() }
        .sheet(item: $importDocument) { document in ImportSheet(document: document) }
    }

    private var helperRow: some View {
        LabeledContent {
            switch model.helperState {
            case .enabled:
                Button("Reinstall") { Task { await model.reinstallHelper() } }
            case .requiresApproval:
                Button("Open System Settings…") { HelperInstaller.openLoginItems() }
            case .notInstalled, .notFound:
                Button("Install Helper") { Task { await model.installHelper() } }
                    .buttonStyle(.borderedProminent)
            }
        } label: {
            HStack(spacing: 6) {
                StatusGlyphView(glyph: helperGlyph)
                Text(helperText)
                if let info = model.daemonInfo, model.helperState == .enabled {
                    Text("· v\(info.version)").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var helperGlyph: StatusGlyph {
        switch model.helperState {
        case .enabled: .up
        case .requiresApproval: .transitioning
        case .notInstalled, .notFound: .failed
        }
    }

    private var helperText: String {
        switch model.helperState {
        case .enabled: "Helper installed"
        case .requiresApproval: "Needs approval in System Settings"
        case .notInstalled: "Helper not installed"
        case .notFound: "Helper not found — reinstall the app"
        }
    }

    private var binaryVersions: String {
        guard let info = model.daemonInfo else { return "helper not connected" }
        let singBox = info.singBoxVersion.isEmpty ? "sing-box ?" : "sing-box \(info.singBoxVersion)"
        let openVPN = info.openVPNVersion.isEmpty ? "OpenVPN ?" : "OpenVPN \(info.openVPNVersion)"
        return "\(singBox) · \(openVPN)"
    }

    private var dnsMode: Binding<Int> {
        Binding(
            get: {
                if case .custom = model.settings.directDNS { return 1 }
                return 0
            },
            set: { mode in
                if mode == 0 {
                    dnsError = nil
                    model.updateSettings { $0.directDNS = .system }
                } else {
                    let servers = parseServers()
                    model.updateSettings { $0.directDNS = .custom(servers: servers) }
                }
            })
    }

    private func setting<T>(_ keyPath: WritableKeyPath<WayforkSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    private func parseServers() -> [String] {
        customDNS.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func commitDNS() {
        let servers = parseServers()
        guard !servers.isEmpty, servers.allSatisfy(isIPAddress) else {
            dnsError = servers.isEmpty ? "Enter at least one resolver address" : "Not an IP address"
            return
        }
        dnsError = nil
        model.updateSettings { $0.directDNS = .custom(servers: servers) }
    }

    private func commitRetention() {
        let days = max(1, min(365, retentionDays))
        retentionDays = days
        guard days != model.settings.logRetentionDays else { return }
        model.updateSettings { $0.logRetentionDays = days }
    }
}

private func isIPAddress(_ text: String) -> Bool {
    var v4 = in_addr()
    var v6 = in6_addr()
    return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
}

extension ExportDocument: @retroactive Identifiable {
    public var id: Date { exportedAt }
}

/// Export tunnels and rules (docs/design/01-data-model.md, "Import / export").
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var includeSecrets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export tunnels and rules").fontWeight(.semibold)
            Text(
                "\(StatusText.count(model.store.tunnels.count, "tunnel")), \(StatusText.count(model.store.rules.count, "rule")) and settings go to wayfork-export.json."
            )
            .foregroundStyle(.secondary)
            Toggle("Include secrets (keys, passwords, UUIDs)", isOn: $includeSecrets)
            if includeSecrets {
                Text(
                    "The file will contain private keys and passwords in plain text. Keep it private."
                )
                .font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    dismiss()
                    Task { await model.exportStore(includeSecrets: includeSecrets) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Import summary with Replace all / Merge.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let document: ExportDocument

    var body: some View {
        let preview = StoreImporter.preview(document)
        VStack(alignment: .leading, spacing: 12) {
            Text("Import tunnels and rules").fontWeight(.semibold)
            Text(
                "\(StatusText.count(preview.tunnels, "tunnel")), \(StatusText.count(preview.rules, "rule")); secrets \(preview.includesSecrets ? "included for \(preview.tunnelsWithSecrets)" : "not included")."
            )
            .foregroundStyle(.secondary)
            if !preview.includesSecrets {
                Text(
                    "Imported OpenVPN tunnels need their config re-attached and VLESS tunnels their URL before they can run."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(
                "Merge adds new items and updates existing ones by id. Replace all discards the current tunnels, rules and settings."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace all") {
                    dismiss()
                    if Alerts.confirm(
                        title: "Replace everything?",
                        message:
                            "Current tunnels, rules and settings will be replaced by the file's.",
                        destructive: "Replace")
                    {
                        model.performImport(document, mode: .replace)
                    }
                }
                Button("Merge") {
                    dismiss()
                    model.performImport(document, mode: .merge)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Export Diagnostics options (docs/design/06-logging.md).
struct DiagnosticsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var includeServerAddresses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Diagnostics").fontWeight(.semibold)
            Text(
                "A zip with logs, a sanitized configuration and system information for bug reports. Secrets are removed; server addresses are replaced by placeholders unless you include them."
            )
            .foregroundStyle(.secondary)
            Toggle("Include server addresses", isOn: $includeServerAddresses)
            Text("Log lines are copied as they are and may mention hostnames.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    dismiss()
                    Task {
                        await model.exportDiagnostics(
                            includeServerAddresses: includeServerAddresses)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
