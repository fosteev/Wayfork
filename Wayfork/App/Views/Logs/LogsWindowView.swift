import AppKit
import SwiftUI
import WayforkCore

/// Logs window (docs/design/06-logging.md, "Logs window").
struct LogsWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedSources: Set<String> = []
    @State private var level: LogLevel = .debug
    @State private var search = ""
    @State private var follow = true

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private struct Row: Identifiable {
        let id: Int
        let line: LogLine
    }

    private var sources: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for fixed in [LogCenter.appSource, "daemon", "sing-box"] {
            ordered.append(fixed)
            seen.insert(fixed)
        }
        for tunnel in model.store.tunnels where tunnel.kind.isOpenVPN {
            let source = "openvpn:\(tunnel.id.uuidString.lowercased())"
            ordered.append(source)
            seen.insert(source)
        }
        for line in model.logs.lines where !seen.contains(line.source) {
            seen.insert(line.source)
            ordered.append(line.source)
        }
        return ordered
    }

    private var rows: [Row] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [Row] = []
        result.reserveCapacity(model.logs.lines.count)
        for (index, line) in model.logs.lines.enumerated() {
            guard line.level <= level else { continue }
            if !selectedSources.isEmpty, !selectedSources.contains(line.source) { continue }
            if !needle.isEmpty, !line.message.lowercased().contains(needle),
                !displayName(line.source).lowercased().contains(needle)
            {
                continue
            }
            result.append(Row(id: index, line: line))
        }
        return result
    }

    var body: some View {
        let rows = rows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        LogRowView(
                            time: LogsWindowView.timeFormatter.string(from: row.line.ts),
                            source: displayName(row.line.source), line: row.line
                        )
                        .id(row.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: rows.last?.id) { _, last in
                if follow, let last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: follow) { _, on in
                if on, let last = rows.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onAppear {
                if let preselected = model.logsPreselectedSource {
                    selectedSources = [preselected]
                    model.logsPreselectedSource = nil
                }
                if let last = rows.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: model.logsPreselectedSource) { _, preselected in
                if let preselected {
                    selectedSources = [preselected]
                    model.logsPreselectedSource = nil
                }
            }
        }
        .frame(minWidth: 640, minHeight: 300)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                sourceMenu
                Picker("Level", selection: $level) {
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .frame(width: 110)
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("Follow", isOn: $follow).toggleStyle(.button)
                Button("Clear") { model.logs.clear() }
                Button("Copy") { copyVisible(rows) }
            }
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button("All sources") { selectedSources = [] }
            Divider()
            ForEach(sources, id: \.self) { source in
                Toggle(
                    displayName(source),
                    isOn: Binding(
                        get: { selectedSources.contains(source) },
                        set: { on in
                            if on {
                                selectedSources.insert(source)
                            } else {
                                selectedSources.remove(source)
                            }
                        }))
            }
        } label: {
            Text(sourceMenuTitle)
        }
        .frame(width: 150)
    }

    private var sourceMenuTitle: String {
        switch selectedSources.count {
        case 0: "All sources"
        case 1: displayName(selectedSources.first ?? "")
        default: "\(selectedSources.count) sources"
        }
    }

    /// `openvpn:<id>` → `openvpn:<name>`.
    private func displayName(_ source: String) -> String {
        guard source.hasPrefix("openvpn:"), let id = UUID(uuidString: String(source.dropFirst(8))),
            let tunnel = model.store.tunnel(id: id)
        else { return source }
        return "openvpn:\(tunnel.name)"
    }

    private func copyVisible(_ rows: [Row]) {
        let text = rows.map { row in
            "\(LogsWindowView.timeFormatter.string(from: row.line.ts))  \(displayName(row.line.source))  \(row.line.level.rawValue.uppercased())  \(row.line.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LogRowView: View {
    let time: String
    let source: String
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time).foregroundStyle(.tertiary)
            Text(source).frame(width: 120, alignment: .leading).lineLimit(1)
            Text(levelLabel).foregroundStyle(levelColor).frame(width: 46, alignment: .leading)
            Text(line.message).textSelection(.enabled)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
    }

    private var levelLabel: String {
        switch line.level {
        case .warning: "WARN"
        default: line.level.rawValue.uppercased()
        }
    }

    private var levelColor: Color {
        switch line.level {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        case .debug: .secondary
        }
    }
}
