import AppKit
import SwiftUI
import WayforkCore

/// *Connections by exit* (F20, docs/design/06-logging.md, "Logs window › Connections
/// view"): one row per exit — every tunnel, every group, *Not via any tunnel*, and a
/// dimmed *Blocked by your list* row — with how many connections went through it since
/// Turn On (or the last *Reset*), how many were reached, how many failed, and the fail
/// rate. Clicking a row expands the F19 rows that went through that exit.
struct ExitsView: View {
    @Environment(AppModel.self) private var model
    @Binding var window: AppModel.ExitsWindow
    @State private var expandedID: String?

    var body: some View {
        let rows = model.exitRows(window: window)
        VStack(spacing: 0) {
            header(rowCount: rows.count)
            Divider()
            if rows.isEmpty {
                Text(ExitsText.empty(since: model.exitsSince))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        columns
                        ForEach(rows) { row in
                            Divider()
                            ExitRowView(
                                row: row, isExpanded: expandedID == row.id,
                                toggle: { toggle(row) })
                            if expandedID == row.id {
                                expandedSection(for: row)
                            }
                        }
                        Divider()
                        totalRow(model.exitsTotals(window: window))
                    }
                }
                if model.exitsNeedNormalLogLevel {
                    Divider()
                    Text(ExitsText.problemsHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 4, leading: 12, bottom: 6, trailing: 12))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func header(rowCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
            Text(ExitsText.header).fontWeight(.semibold)
            Text(ExitsText.hint(since: model.exitsSince))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Picker("", selection: $window) {
                ForEach(AppModel.ExitsWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .labelsHidden()
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .background(Color.primary.opacity(0.03))
    }

    private var columns: some View {
        HStack(spacing: 8) {
            Text("Exit").frame(width: 190, alignment: .leading)
            Text("Connections").frame(width: 86, alignment: .trailing)
            Text("Reached").frame(width: 70, alignment: .trailing)
            Text("Failed").frame(width: 60, alignment: .trailing)
            Text("Fail rate").frame(width: 120, alignment: .leading)
            Text("Last failure").frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 14)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
        .background(Color.primary.opacity(0.02))
    }

    private func totalRow(_ totals: AppModel.ExitsTotals) -> some View {
        HStack(spacing: 8) {
            Text(ExitsText.totalLabel).fontWeight(.semibold).frame(width: 190, alignment: .leading)
            Text("\(totals.connections)").frame(width: 86, alignment: .trailing)
            Text("\(totals.reached)").frame(width: 70, alignment: .trailing)
            Text("\(totals.failed)").fontWeight(.medium).frame(width: 60, alignment: .trailing)
            Text(totals.rate.map(ExitsText.rate) ?? "—").frame(width: 120, alignment: .leading)
            Spacer(minLength: 14)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .background(Color.primary.opacity(0.03))
    }

    private func expandedSection(for row: AppModel.ExitRow) -> some View {
        let hosts = model.failedHosts(forExit: row.id)
        return VStack(spacing: 0) {
            ForEach(hosts) { host in
                Divider()
                FailedRowView(row: host, isSelected: false, select: {})
            }
        }
        .padding(.leading, 12)
        .background(Color.primary.opacity(0.02))
    }

    private func toggle(_ row: AppModel.ExitRow) {
        guard row.kind != .blocked else { return }
        expandedID = expandedID == row.id ? nil : row.id
    }
}

/// One exit row: name (+ badge, + `using <member>` for a group), the three counts, the
/// fail-rate bar, the last failure, a chevron that expands the F19 rows.
private struct ExitRowView: View {
    let row: AppModel.ExitRow
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(row.name).lineLimit(1)
                if row.isDefault {
                    Text("Default")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                }
                if let usingMember = row.usingMember {
                    Text(ExitsText.using(usingMember))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 190, alignment: .leading)
            Text(row.connections.map(String.init) ?? "—")
                .frame(width: 86, alignment: .trailing)
            Text(row.reached.map(String.init) ?? "—")
                .frame(width: 70, alignment: .trailing)
            Text("\(row.failed)")
                .fontWeight(row.failed > 0 ? .medium : .regular)
                .foregroundStyle(row.failed > 0 ? Color.red : Color.secondary)
                .frame(width: 60, alignment: .trailing)
            rateCell.frame(width: 120, alignment: .leading)
            Text(row.lastFailureText ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(
                    row.lastFailureText == nil
                        ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.kind != .blocked {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            } else {
                Spacer(minLength: 14).frame(width: 14)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
        .frame(minHeight: 28)
        .opacity(row.kind == .blocked ? 0.65 : 1)
        .background(isExpanded ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var dotColor: Color {
        switch row.kind {
        case .blocked: .secondary
        case .direct: .secondary
        default: row.failed > 0 ? .red : .green
        }
    }

    @ViewBuilder
    private var rateCell: some View {
        if row.kind == .blocked {
            Text(ExitsText.notCountedAsFailures).font(.system(size: 11)).foregroundStyle(.tertiary)
        } else if let rate = row.rate {
            HStack(spacing: 6) {
                GeometryReader { proxy in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(barColor(rate))
                                .frame(width: rate > 0 ? max(2, proxy.size.width * rate) : 0)
                        }
                }
                .frame(height: 5)
                Text(ExitsText.rate(rate)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func barColor(_ rate: Double) -> Color {
        switch ExitsText.rateClass(rate) {
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        }
    }
}
