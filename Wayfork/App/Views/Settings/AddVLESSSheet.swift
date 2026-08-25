import AppKit
import SwiftUI
import WayforkCore

/// "Add VLESS Tunnel" sheet with live parse preview (docs/design/02-ux.md).
struct AddVLESSSheet: View {
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

    @State private var uri = ""
    @State private var parsed: VLESSImportResult?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .add ? "Add VLESS Tunnel" : "Replace VLESS URL").fontWeight(.semibold)
            TextField("vless://…", text: $uri)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .invalidOutline(error != nil)
                .onSubmit(commit)
            if let parsed {
                preview(parsed)
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
        .onAppear {
            if uri.isEmpty, let clipboard = NSPasteboard.general.string(forType: .string),
                clipboard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    .hasPrefix("vless://")
            {
                uri = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                parse()
            }
        }
        .onChange(of: uri) { parse() }
    }

    private func preview(_ result: VLESSImportResult) -> some View {
        let meta = result.meta
        var security = meta.security.rawValue.uppercased()
        if let sni = meta.sni { security += " · SNI \(sni)" }
        if let fingerprint = meta.fingerprint { security += " · fingerprint \(fingerprint)" }
        var transport: String
        switch meta.transport {
        case .tcp: transport = "tcp"
        case .ws(let path, let host):
            transport = "ws \(path)"
            if let host { transport += " · host \(host)" }
        case .grpc(let serviceName): transport = "gRPC \(serviceName)"
        }
        if let flow = meta.flow { transport += " · flow \(flow)" }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6)
        {
            previewRow("Name", result.name.isEmpty ? meta.server : result.name)
            previewRow("Server", "\(meta.server):\(meta.port)")
            previewRow("Security", security)
            previewRow("Transport", transport)
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

    private func parse() {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parsed = nil
            error = nil
            return
        }
        do {
            parsed = try VLESSURIParser.parse(trimmed)
            error = nil
        } catch VLESSImportError.invalid(let reason) {
            parsed = nil
            error = "Not a valid vless:// URL: \(reason)"
        } catch VLESSImportError.unsupported(let reason) {
            parsed = nil
            error =
                reason.lowercased().contains("not supported")
                ? reason : "\(reason) is not supported yet."
        } catch {
            parsed = nil
            self.error = "\(error)"
        }
    }

    private func commit() {
        guard let parsed else { return }
        switch mode {
        case .add: model.addVLESS(parsed)
        case .replace(let id): model.replaceVLESS(tunnelID: id, with: parsed)
        }
        dismiss()
    }
}
