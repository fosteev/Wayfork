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
