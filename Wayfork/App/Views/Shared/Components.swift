import SwiftUI
import WayforkCore

/// Green filled / grey hollow / orange half / red cross (docs/design/02-ux.md).
struct StatusGlyphView: View {
    let glyph: StatusGlyph
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            switch glyph {
            case .up:
                Circle().fill(Color.green)
            case .idle:
                Circle().stroke(Color.secondary.opacity(0.7), lineWidth: 1.2)
                    .padding(0.6)
            case .transitioning:
                Circle().stroke(Color.orange, lineWidth: 1.2).padding(0.6)
                HalfCircle().fill(Color.orange)
            case .failed:
                Circle().fill(Color.red)
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundStyle(.white)
            case .group:
                RoundedRectangle(cornerRadius: size * 0.25).fill(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch glyph {
        case .up: "connected"
        case .idle: "inactive"
        case .transitioning: "connecting"
        case .failed: "failed"
        case .group: "group"
        }
    }
}

private struct HalfCircle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(
            center: center, radius: rect.width / 2, startAngle: .degrees(-90),
            endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// `OpenVPN` / `VLESS` pill.
struct TypeBadge: View {
    let kind: TunnelKind

    var body: some View {
        Text(StatusText.typeBadge(kind))
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .foregroundStyle(.secondary)
    }
}

/// Accent marker for the tunnel handling sites without an explicit rule.
struct AccentBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Color.accentColor)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
    }
}

/// Small rounded chip for counts and warnings (`3 rules`, `shadowed`).
struct Chip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill((tint ?? Color.secondary).opacity(0.14)))
            .foregroundStyle(tint ?? Color.secondary)
    }
}

/// White (or dark) box with a hairline border used for grouped lists.
struct GroupBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Section title of a Settings page.
struct PageTitle: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 20, weight: .bold))
    }
}

extension View {
    /// Red focus ring used for invalid input.
    func invalidOutline(_ invalid: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.red, lineWidth: 1)
                .opacity(invalid ? 1 : 0)
        )
    }
}

/// `62 ms` in the band colour, or the red words when the tunnel is unreachable; `—` in
/// tertiary while no probe has answered yet (F14, docs/design/02-ux.md, "Variant C").
struct LatencyLabel: View {
    let sample: LatencySample?

    var body: some View {
        Group {
            if let sample, sample.unreachable {
                Text("Not reachable").fontWeight(.semibold).foregroundStyle(.red)
            } else if let sample, let milliseconds = sample.milliseconds {
                (Text("\(milliseconds)").fontWeight(.medium) + Text(" ms").font(.system(size: 10)))
                    .foregroundStyle(bandColor(LatencyBand(milliseconds: milliseconds)))
                    .monospacedDigit()
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .help(
            sample.map(LatencyFormat.tooltip)
                ?? "Measured through the tunnel every \(Int(LatencyProbe.interval)) s")
    }
}

/// Last 2 minutes of probes, 64 × 24 pt, newest at the right edge; failed probes leave a
/// dashed baseline segment (F14).
struct SparklineView: View {
    let sample: LatencySample
    nonisolated static let size = CGSize(width: 64, height: 24)
    /// Values above this are drawn at the top edge.
    nonisolated static let ceiling = 400.0

    var body: some View {
        let points = sample.history
        let latest = sample.milliseconds ?? points.compactMap { $0 }.last ?? 0
        let color = sample.unreachable ? Color.red : bandColor(LatencyBand(milliseconds: latest))
        Canvas { context, size in
            let slots = max(LatencyProbe.historyLength, 2)
            let step = size.width / CGFloat(slots - 1)
            let offset = slots - points.count
            let baseline = size.height - 2
            func point(_ index: Int, _ value: Int) -> CGPoint {
                let share = min(Double(value), Self.ceiling) / Self.ceiling
                return CGPoint(
                    x: CGFloat(index + offset) * step,
                    y: baseline - CGFloat(share) * (size.height - 4))
            }
            var line = Path()
            var gaps = Path()
            var open = false
            for (index, value) in points.enumerated() {
                if let value {
                    let p = point(index, value)
                    if open { line.addLine(to: p) } else { line.move(to: p) }
                    open = true
                } else {
                    open = false
                    let x = CGFloat(index + offset) * step
                    gaps.move(to: CGPoint(x: x, y: baseline))
                    gaps.addLine(to: CGPoint(x: min(x + step, size.width), y: baseline))
                }
            }
            context.stroke(
                line, with: .color(color),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            context.stroke(
                gaps, with: .color(.secondary.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            if let last = points.last, let value = last {
                let p = point(points.count - 1, value)
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)),
                    with: .color(color))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// One member line under a group card or in the expanded group (F16): dot, name, the
/// `✓ in use` / `skipped — …` note, latency right-aligned.
struct GroupMemberRowView: View {
    let row: GroupMemberRow
    var showsLatency = true

    var body: some View {
        HStack(spacing: 6) {
            StatusGlyphView(glyph: row.glyph, size: 8)
            Text(row.tunnel.name).lineLimit(1)
            if !row.note.isEmpty {
                Text(row.note)
                    .foregroundStyle(row.isActive ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if showsLatency {
                LatencyLabel(sample: row.latency).font(.system(size: 11))
            }
        }
        .font(.system(size: 11))
    }
}

/// Text colours for the latency bands: darker than the status dots so they read on white,
/// lighter in dark mode (the prototype's `--okt` / `--warnt` / `--badt`).
func bandColor(_ band: LatencyBand) -> Color {
    Color(
        nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch band {
            case .good:
                return dark
                    ? NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
                    : NSColor(red: 0.12, green: 0.56, blue: 0.24, alpha: 1)
            case .fair:
                return dark
                    ? NSColor(red: 1.0, green: 0.70, blue: 0.25, alpha: 1)
                    : NSColor(red: 0.66, green: 0.35, blue: 0.0, alpha: 1)
            case .poor:
                return dark
                    ? NSColor(red: 1.0, green: 0.41, blue: 0.38, alpha: 1)
                    : NSColor(red: 0.82, green: 0.20, blue: 0.17, alpha: 1)
            }
        })
}
