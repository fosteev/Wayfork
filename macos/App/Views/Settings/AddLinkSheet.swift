import AppKit
import SwiftUI
import WayforkCore

/// Adds or replaces a supported proxy sharing link with a live parse preview. The same
/// field takes a subscription URL, which is fetched on request into a checklist of servers
/// (docs/design/02-ux.md, "Add from link sheet").
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

    /// What the sheet is doing with a pasted subscription URL.
    private enum Subscription {
        case fetching(host: String)
        case loaded(host: String, entries: [SubscriptionEntry], checked: Set<Int>)
    }

    @State private var uri = ""
    @State private var parsed: ProxyLink?
    @State private var error: String?
    @State private var subscription: Subscription?
    @State private var fetchTask: Task<Void, Never>?

    private var isSubscriptionURL: Bool { mode == .add && SubscriptionDecoder.isURL(uri) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                if case .loaded(let host, let entries, _) = subscription {
                    Text("\(host) · \(summary(entries))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            TextField("vless:// ss:// trojan:// vmess:// or a subscription https://", text: $uri)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .invalidOutline(error != nil)
                .onSubmit(submit)
                .disabled(subscription != nil)
            if let parsed { preview(parsed) }
            switch subscription {
            case .fetching(let host):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching \(host)…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .loaded(_, let entries, let checked):
                checklist(entries, checked: checked)
            case nil:
                EmptyView()
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                if case .loaded(_, _, let checked) = subscription {
                    Text(slotsFooter(checked.count)).font(.system(size: 11))
                        .foregroundStyle(
                            checked.count > model.store.freeSlotCount ? .red : .secondary)
                }
                Spacer()
                Button("Cancel") {
                    fetchTask?.cancel()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                if subscription == nil && isSubscriptionURL {
                    Button("Fetch", action: fetch)
                        .keyboardShortcut(.defaultAction)
                        .disabled(error != nil)
                } else if case .loaded(_, _, let checked) = subscription {
                    Button(addTitle(checked.count), action: commitSubscription)
                        .keyboardShortcut(.defaultAction)
                        .disabled(checked.isEmpty || checked.count > model.store.freeSlotCount)
                } else {
                    Button(mode == .add ? "Add" : "Replace", action: commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(parsed == nil || error != nil || subscription != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { fetchTask?.cancel() }
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

    private var title: String {
        switch (mode, subscription) {
        case (.replace, _): "Replace Link"
        case (.add, .some): "Add Tunnels from Subscription"
        case (.add, nil): "Add Tunnel from Link"
        }
    }

    // MARK: - Subscription

    private func checklist(_ entries: [SubscriptionEntry], checked: Set<Int>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    switch entry {
                    case .link(let link, _, _):
                        let duplicate = model.store.tunnels.contains { $0.kind == link.tunnelKind }
                        Toggle(
                            isOn: Binding(
                                get: { checked.contains(index) },
                                set: { on in setChecked(index, on) })
                        ) {
                            HStack(spacing: 8) {
                                Text(linkName(link)).lineLimit(1).frame(
                                    width: 120, alignment: .leading)
                                Text(kindName(link)).foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                Text(server(link)).lineLimit(1).truncationMode(.middle)
                                Text(detail(link)).foregroundStyle(.secondary).lineLimit(1)
                                if duplicate {
                                    Spacer()
                                    Text("already added").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    case .skipped(let line, let reason):
                        HStack(spacing: 8) {
                            Text("line \(line)").frame(width: 120, alignment: .leading)
                            Text(reason).lineLimit(1).truncationMode(.tail)
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
        .background(GroupBackground())
    }

    private func setChecked(_ index: Int, _ on: Bool) {
        guard case .loaded(let host, let entries, var checked) = subscription else { return }
        if on { checked.insert(index) } else { checked.remove(index) }
        subscription = .loaded(host: host, entries: entries, checked: checked)
    }

    private func fetch() {
        guard mode == .add, subscription == nil, error == nil else { return }
        let text = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let host = url.host else {
            error = "Not a valid URL."
            return
        }
        subscription = .fetching(host: host)
        fetchTask = Task {
            do {
                let body = try await SubscriptionFetcher.fetch(url)
                let entries = try SubscriptionDecoder.decode(body)
                guard !Task.isCancelled else { return }
                // Servers already in the store start unchecked; everything else is wanted.
                var checked: Set<Int> = []
                for (index, entry) in entries.enumerated() {
                    if case .link(let link, _, _) = entry,
                        !model.store.tunnels.contains(where: { $0.kind == link.tunnelKind })
                    {
                        checked.insert(index)
                    }
                }
                subscription = .loaded(host: host, entries: entries, checked: checked)
                if entries.isEmpty { error = "The subscription has no links." }
            } catch {
                guard !Task.isCancelled else { return }
                subscription = nil
                self.error = "Cannot load the subscription: \(reason(error))"
            }
        }
    }

    private func commitSubscription() {
        guard case .loaded(let host, let entries, let checked) = subscription else { return }
        let links = entries.enumerated().compactMap { index, entry -> ProxyLink? in
            guard checked.contains(index), case .link(let link, _, _) = entry else { return nil }
            return link
        }
        guard !links.isEmpty, links.count <= model.store.freeSlotCount else { return }
        model.addLinks(links, from: host)
        dismiss()
    }

    private func submit() {
        if subscription == nil && isSubscriptionURL { fetch() } else { commit() }
    }

    private func summary(_ entries: [SubscriptionEntry]) -> String {
        let links = entries.filter { if case .link = $0 { true } else { false } }.count
        let skipped = entries.count - links
        var result = StatusText.count(links, "server")
        if skipped > 0 { result += ", \(skipped) skipped" }
        return result
    }

    private func slotsFooter(_ checkedCount: Int) -> String {
        let free = model.store.freeSlotCount
        return checkedCount > free
            ? "only \(StatusText.count(free, "slot")) free"
            : "\(checkedCount) of \(StatusText.count(free, "free slot"))"
    }

    private func addTitle(_ checkedCount: Int) -> String {
        checkedCount == 0 ? "Add" : "Add \(StatusText.count(checkedCount, "tunnel"))"
    }

    private func detail(_ link: ProxyLink) -> String {
        switch link {
        case .shadowsocks(let result): result.meta.method
        case .vless(let result): result.meta.security.rawValue.uppercased()
        case .trojan(let result): result.meta.security.rawValue.uppercased()
        case .vmess(let result): result.meta.tlsSecurity.rawValue.uppercased()
        }
    }

    private func reason(_ error: Error) -> String {
        switch error {
        case ProxyLinkError.invalid(let reason), ProxyLinkError.unsupported(let reason): reason
        default: "\(error)"
        }
    }

    // MARK: - Single link

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
        fetchTask?.cancel()
        subscription = nil
        guard !trimmed.isEmpty else {
            parsed = nil
            error = nil
            return
        }
        if SubscriptionDecoder.isURL(trimmed) {
            parsed = nil
            if mode != .add {
                error = "Paste a single link; subscriptions add new tunnels."
            } else if !trimmed.lowercased().hasPrefix("https://") {
                error = "Subscriptions must use https."
            } else {
                error = nil
            }
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
        guard let parsed, error == nil, subscription == nil else { return }
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
        return ["vless://", "ss://", "trojan://", "vmess://", "https://"].contains {
            lowercased.hasPrefix($0)
        }
    }

    private func schemeName(_ value: String) -> String {
        guard let end = value.range(of: "://") else { return "proxy" }
        return String(value[..<end.upperBound]).lowercased()
    }
}
