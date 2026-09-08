import AppKit
import SwiftUI
import WayforkCore

/// Adds or replaces a supported proxy sharing link with a live parse preview.
struct AddLinkSheet: View {
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
    @State private var parsed: ProxyLink?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .add ? "Add Tunnel from Link" : "Replace Link")
                .fontWeight(.semibold)
            TextField("vless:// ss:// trojan:// vmess://", text: $uri)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .invalidOutline(error != nil)
                .onSubmit(commit)
            if let parsed { preview(parsed) }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .add ? "Add" : "Replace", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil || error != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if uri.isEmpty, let clipboard = NSPasteboard.general.string(forType: .string) {
                let value = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                if supportedScheme(value) {
                    uri = value
                    parse()
                }
            }
        }
        .onChange(of: uri) { parse() }
    }

    private func preview(_ link: ProxyLink) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            previewRow("Kind", kindName(link))
            previewRow("Name", linkName(link))
            previewRow("Server", server(link))
            switch link {
            case .shadowsocks(let result):
                previewRow("Method", result.meta.method)
            case .vless(let result):
                previewRow(
                    "Security",
                    security(
                        result.meta.security, sni: result.meta.sni,
                        fingerprint: result.meta.fingerprint))
                previewRow("Transport", transport(result.meta.transport, flow: result.meta.flow))
            case .trojan(let result):
                previewRow(
                    "Security",
                    security(
                        result.meta.security, sni: result.meta.sni,
                        fingerprint: result.meta.fingerprint))
                previewRow("Transport", transport(result.meta.transport))
            case .vmess(let result):
                previewRow(
                    "Security",
                    security(
                        result.meta.tlsSecurity, sni: result.meta.sni,
                        fingerprint: result.meta.fingerprint))
                previewRow("Transport", transport(result.meta.transport))
            }
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
            let link = try ProxyLinkParser.parse(trimmed)
            if let mismatch = replacementMismatch(link) {
                parsed = link
                error = mismatch
            } else {
                parsed = link
                error = nil
            }
        } catch ProxyLinkError.invalid(let reason) {
            parsed = nil
            error = "Not a valid \(schemeName(trimmed)) link: \(reason)"
        } catch ProxyLinkError.unsupported(let reason) {
            parsed = nil
            error = "Not a valid \(schemeName(trimmed)) link: \(reason)"
        } catch {
            parsed = nil
            self.error = "\(error)"
        }
    }

    private func commit() {
        guard let parsed, error == nil else { return }
        switch mode {
        case .add: model.addLink(parsed)
        case .replace(let id): model.replaceLink(tunnelID: id, with: parsed)
        }
        dismiss()
    }

    private func replacementMismatch(_ link: ProxyLink) -> String? {
        guard case .replace(let id) = mode, let tunnel = model.store.tunnel(id: id) else {
            return nil
        }
        let linkKind = kindName(link)
        let tunnelKind = StatusText.typeBadge(tunnel.kind)
        guard linkKind != tunnelKind else { return nil }
        return "That link is a \(linkKind) link; this tunnel is \(tunnelKind)."
    }

    private func kindName(_ link: ProxyLink) -> String {
        switch link {
        case .vless: "VLESS"
        case .shadowsocks: "Shadowsocks"
        case .trojan: "Trojan"
        case .vmess: "VMess"
        }
    }

    private func linkName(_ link: ProxyLink) -> String {
        switch link {
        case .vless(let result): result.name.isEmpty ? result.meta.server : result.name
        case .shadowsocks(let result): result.name.isEmpty ? result.meta.server : result.name
        case .trojan(let result): result.name.isEmpty ? result.meta.server : result.name
        case .vmess(let result): result.name.isEmpty ? result.meta.server : result.name
        }
    }

    private func server(_ link: ProxyLink) -> String {
        switch link {
        case .vless(let result): "\(result.meta.server):\(result.meta.port)"
        case .shadowsocks(let result): "\(result.meta.server):\(result.meta.port)"
        case .trojan(let result): "\(result.meta.server):\(result.meta.port)"
        case .vmess(let result): "\(result.meta.server):\(result.meta.port)"
        }
    }

    private func security(_ value: TLSSecurity, sni: String?, fingerprint: String?) -> String {
        var result = value.rawValue.uppercased()
        if let sni { result += " · SNI \(sni)" }
        if let fingerprint { result += " · fingerprint \(fingerprint)" }
        return result
    }

    private func transport(_ value: ProxyTransport, flow: String? = nil) -> String {
        var result: String
        switch value {
        case .tcp: result = "tcp"
        case .ws(let path, let host):
            result = "ws \(path)"
            if let host { result += " · host \(host)" }
        case .grpc(let serviceName): result = "gRPC \(serviceName)"
        }
        if let flow { result += " · flow \(flow)" }
        return result
    }

    private func supportedScheme(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return ["vless://", "ss://", "trojan://", "vmess://"].contains {
            lowercased.hasPrefix($0)
        }
    }

    private func schemeName(_ value: String) -> String {
        guard let end = value.range(of: "://") else { return "proxy" }
        return String(value[..<end.upperBound]).lowercased()
    }
}
