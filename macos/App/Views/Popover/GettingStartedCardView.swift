import SwiftUI
import WayforkCore

/// The Getting started card (F22, docs/design/02-ux.md "Getting started card"): on top of
/// the popover after the guide finishes. Three tips, each ticked by doing it once from the
/// call sites in `AppModel+Guide.swift`'s doc comment; × dismisses it for good.
struct GettingStartedCardView: View {
    @Environment(AppModel.self) private var model

    private static let items: [GuideCardItem] = [.popoverRule, .cantReach, .appRule]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Getting started")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(Self.items, id: \.self) { item in
                        Capsule()
                            .fill(
                                model.guideState.cardDone.contains(item)
                                    ? Color.accentColor : Color.secondary.opacity(0.25)
                            )
                            .frame(width: 16, height: 3)
                    }
                }
                Spacer()
                Button {
                    model.dismissGuideCard()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
            ForEach(Self.items, id: \.self) { item in
                row(for: item)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func row(for item: GuideCardItem) -> some View {
        let done = model.guideState.cardDone.contains(item)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.accentColor : Color.secondary.opacity(0.4))
                .font(.system(size: 12))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(item)).font(.system(size: 12, weight: .medium))
                if !done {
                    Text(subtitle(item)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !done, let label = showMeLabel(item) {
                Button(label, action: showMeAction(item)).buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    private func title(_ item: GuideCardItem) -> String {
        switch item {
        case .popoverRule: return "Add a site from here"
        case .cantReach: return "When a site won't open"
        case .appRule: return "Send a whole app through \(defaultOrFirstTunnelName)"
        }
    }

    private func subtitle(_ item: GuideCardItem) -> String {
        switch item {
        case .popoverRule:
            return "Type it below, or pick one from Recent once you've browsed a bit."
        case .cantReach:
            return "Logs › Can't reach lists it with the likely fix."
        case .appRule:
            return "Settings › Rules › Add app — for apps that use many addresses."
        }
    }

    private func showMeLabel(_ item: GuideCardItem) -> String? {
        item == .popoverRule ? nil : "Show me"
    }

    private func showMeAction(_ item: GuideCardItem) -> () -> Void {
        switch item {
        case .popoverRule: return {}
        case .cantReach: return { model.openLogs() }
        case .appRule: return { model.openSettings(section: .rules) }
        }
    }

    private var defaultOrFirstTunnelName: String {
        model.effectiveDefaultTunnel?.name ?? model.store.tunnels.first?.name ?? "a tunnel"
    }
}
