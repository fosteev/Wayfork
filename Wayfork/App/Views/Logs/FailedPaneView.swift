import AppKit
import SwiftUI
import WayforkCore

/// *Can't reach* (F19, docs/design/06-logging.md, "Logs window"): one row per site + app
/// that could not be reached; clicking a row filters the log to that host.
struct FailedPaneView: View {
    @Environment(AppModel.self) private var model
    @Binding var search: String
    @Binding var level: LogLevel
    @State private var selectedID: String?

    var body: some View {
        let rows = model.failedHosts
        let appsUnknown =
            !rows.isEmpty && rows.allSatisfy { $0.processPath == nil }
            && model.settings.logLevel != .info && model.settings.logLevel != .debug
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(rows.isEmpty ? Color.secondary : Color.red)
                Text("Can't reach").fontWeight(.semibold)
                Text(
                    rows.isEmpty
                        ? FailedText.empty(since: model.failedSince)
                        : FailedText.header(
                            count: rows.count, since: model.failedSince, appsUnknown: appsUnknown)
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer()
                if !rows.isEmpty {
                    Button("Clear") { for row in rows { model.hideFailed(row) } }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .background(Color.primary.opacity(0.03))
            if !rows.isEmpty {
                Divider()
                columns
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            Divider()
                            FailedRowView(
                                row: row, isSelected: selectedID == row.id,
                                select: { select(row) })
                        }
                    }
                }
                .frame(maxHeight: 132)
            }
            if let selectedID, let row = rows.first(where: { $0.id == selectedID }) {
                Divider()
                HStack(spacing: 6) {
                    Text(
                        FailedText.showing(
                            host: row.host, tries: row.count, reason: model.failedReason(row),
                            via: model.failedVia(row))
                    )
                    .lineLimit(1)
                    Spacer()
                    Button("Show all lines") {
                        self.selectedID = nil
                        search = ""
                    }
                    .buttonStyle(.link)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
        }
        .background(GroupBackground())
        .onChange(of: search) { _, text in
            // Typing something else in the search field ends the row's filter.
            if let selectedID, let row = rows.first(where: { $0.id == selectedID }),
                text != row.host
            {
                self.selectedID = nil
            }
        }
    }

    private var columns: some View {
        HStack(spacing: 8) {
            Text("Site").frame(width: FailedRowView.siteWidth, alignment: .leading)
            Text("App").frame(width: FailedRowView.appWidth, alignment: .leading)
            Text("Tried").frame(width: FailedRowView.triesWidth, alignment: .leading)
            Text("Why").frame(width: FailedRowView.whyWidth, alignment: .leading)
            Text("Via").frame(width: FailedRowView.viaWidth, alignment: .leading)
            Text("Last")
            Spacer()
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
        .background(Color.primary.opacity(0.02))
    }

    private func select(_ row: FailedHost) {
        selectedID = row.id
        search = row.host
        level = .debug
    }
}

/// One pane row: app icon, site, app, tries, why, via, last; actions on hover.
private struct FailedRowView: View {
    @Environment(AppModel.self) private var model
    let row: FailedHost
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false

    static let siteWidth: CGFloat = 220
    static let appWidth: CGFloat = 80
    static let triesWidth: CGFloat = 40
    static let whyWidth: CGFloat = 130
    static let viaWidth: CGFloat = 60

    var body: some View {
        let process = AppModel.recentProcess(row.processPath)
        let reason = model.failedReason(row)
        let isError = row.reason != .blocked
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: process.icon).resizable().frame(width: 16, height: 16)
                    .opacity(row.processPath == nil ? 0.35 : 1)
                Text(row.host).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: Self.siteWidth, alignment: .leading)
            Text(process.name).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: Self.appWidth, alignment: .leading)
            Text(FailedText.tries(row.count)).fontWeight(.medium).monospacedDigit()
                .frame(width: Self.triesWidth, alignment: .leading)
            Text(reason)
                .foregroundStyle(isError ? Color.red : Color.primary)
                .lineLimit(1)
                .frame(width: Self.whyWidth, alignment: .leading)
                .help(FailedText.detail(row.reason) ?? reason)
            Text(model.failedVia(row)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: Self.viaWidth, alignment: .leading)
            Text(FailedText.lastSeen(row.lastSeen, now: model.traffic?.sampledAt ?? Date()))
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 4)
            if hovering || isSelected {
                actions
            }
        }
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 8))
        .frame(minHeight: 26)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var actions: some View {
        if row.reason == .blocked {
            Button("Never block") { model.neverBlockFailed(row) }
                .buttonStyle(.link).font(.system(size: 11))
        } else if model.canRouteFailed(row) {
            Menu {
                Text("Route \(RulePattern.registrableDomain(of: row.host)) and subdomains via…")
                ForEach(model.recentTargets, id: \.self) { target in
                    Button(model.targetName(target)) { model.routeFailed(row, via: target) }
                }
            } label: {
                Text("Route via")
            }
            .controlSize(.small)
            .fixedSize()
        }
        Button {
            model.hideFailed(row)
        } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help("Hide until the next Turn On")
    }
}
