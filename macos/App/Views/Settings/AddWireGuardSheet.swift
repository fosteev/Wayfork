import AppKit
import SwiftUI
import WayforkCore

/// Adds or replaces a WireGuard config from a file or pasted wg-quick text.
struct AddWireGuardSheet: View {
    enum Mode: Identifiable, Hashable {
        case add
        case replace(UUID)

        var id: String {
            switch self {
            case .add: "add"
            case .replace(let id): id.uuidString
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var config = ""
    @State private var fileName = ""
    @State private var parsed: WireGuardImportResult?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .add ? "Add WireGuard Tunnel" : "Replace Config")
                .fontWeight(.semibold)
            Button("Choose File…") { Task { await chooseFile() } }
            TextEditor(text: $config)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(error == nil ? Color.secondary.opacity(0.35) : Color.red))
            if let parsed {
                preview(parsed)
                if let warning = allowedIPsWarning(parsed.meta) {
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .add ? "Add" : "Replace", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: config) { parse() }
    }

    private func preview(_ result: WireGuardImportResult) -> some View {
        let meta = result.meta
        let peer = meta.peers.first
        return Grid(
            alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6
        ) {
            previewRow("Name", fileName.isEmpty ? result.name : fileName)
            previewRow("Address", meta.addresses.joined(separator: ", "))
            previewRow("Peer", peer.map { "\($0.host):\($0.port)" } ?? "—")
            previewRow(
                "DNS",
                meta.discoveredDNS.isEmpty
                    ? "Automatic" : meta.discoveredDNS.joined(separator: ", "))
            previewRow("MTU", meta.mtu.map(String.init) ?? "Automatic")
        }
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GroupBackground())
    }

    private func previewRow(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }

    private func chooseFile() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AppModel.wireGuardType, .text, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a WireGuard config (.conf)"
        NSApp.activate(ignoringOtherApps: true)
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            fileName = url.deletingPathExtension().lastPathComponent
            config = text
            parse()
        } catch {
            parsed = nil
            self.error = "Cannot read file: \(error.localizedDescription)"
        }
    }

    private func parse() {
        guard !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsed = nil
            error = nil
            fileName = ""
            return
        }
        do {
            parsed = try WireGuardConfParser.parse(config)
            error = nil
        } catch WireGuardImportError.invalid(let reason) {
            parsed = nil
            error = "Not a valid WireGuard config: \(reason)"
        } catch WireGuardImportError.unsupported(let reason) {
            parsed = nil
            error = "Not a valid WireGuard config: \(reason)"
        } catch {
            parsed = nil
            self.error = "Not a valid WireGuard config: \(error)"
        }
    }

    private func commit() {
        guard let parsed else { return }
        switch mode {
        case .add:
            model.addWireGuard(parsed, name: fileName.isEmpty ? parsed.name : fileName)
        case .replace(let id):
            model.replaceWireGuardConfig(tunnelID: id, with: parsed)
        }
        dismiss()
    }
}

func allowedIPsWarning(_ meta: WireGuardMeta) -> String? {
    guard let peer = meta.peers.first else { return nil }
    let prefixes = peer.allowedIPs.compactMap(IPv4Prefix.init)
    guard !IPv4Prefix("0.0.0.0/0")!.subtracting(all: prefixes).isEmpty else { return nil }
    return
        "Routes only \(peer.allowedIPs.joined(separator: ", ")) — traffic sent elsewhere through this tunnel is dropped by the peer"
}
