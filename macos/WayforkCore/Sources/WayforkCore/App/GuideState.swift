import Foundation

/// A step of the first-run guide (F22, docs/design/02-ux.md "First-run guide"), in rail
/// order.
public enum GuideStep: String, Codable, Sendable, Hashable, CaseIterable {
    case welcome
    case helper
    case addVPN
    case sites
    case turnOn
    case tryIt

    /// Rail order comparison.
    public func isAfter(_ other: GuideStep) -> Bool {
        let order = Self.allCases
        return order.firstIndex(of: self)! > order.firstIndex(of: other)!
    }
}

/// How the guide window was last left.
public enum GuideOutcome: String, Codable, Sendable, Hashable {
    case finished
    case skipped
}

/// One tip of the popover's Getting started card.
public enum GuideCardItem: String, Codable, Sendable, Hashable, CaseIterable {
    case popoverRule
    case cantReach
    case appRule
}

/// This Mac's first-run guide progress (F22). Not part of `Store`: it is UI progress, not
/// configuration (docs/design/01-data-model.md, "Persistence") — stored separately under
/// `UserDefaults` key `WayforkGuideState`, JSON-encoded, by the app's `GuideStore`.
public struct GuideState: Codable, Sendable, Hashable {
    /// Set when the guide window closes on *Done* or *Skip guide*; nil while it has never
    /// run to either end (including "never opened").
    public var outcome: GuideOutcome?
    /// The step the window was on when it was closed without an outcome (not a skip).
    public var stoppedAt: GuideStep?
    public var cardActive: Bool
    public var cardDismissed: Bool
    public var cardDone: Set<GuideCardItem>

    public init(
        outcome: GuideOutcome? = nil, stoppedAt: GuideStep? = nil, cardActive: Bool = false,
        cardDismissed: Bool = false, cardDone: Set<GuideCardItem> = []
    ) {
        self.outcome = outcome
        self.stoppedAt = stoppedAt
        self.cardActive = cardActive
        self.cardDismissed = cardDismissed
        self.cardDone = cardDone
    }

    /// Opens by itself at launch: no tunnels yet, and the guide has never finished or been
    /// skipped. Upgrading users with tunnels never see it (docs/design/02-ux.md, "Window
    /// and trigger").
    public func shouldAutoOpen(tunnelCount: Int) -> Bool {
        tunnelCount == 0 && outcome == nil
    }

    /// The Getting started card shows while active, not dismissed, and not every item is
    /// done yet.
    public var showsCard: Bool {
        cardActive && !cardDismissed && cardDone.count < GuideCardItem.allCases.count
    }

    /// The step to resume at from the No-tunnels popover; nil once the guide ran to an
    /// outcome (finished or skipped).
    public var resumeStep: GuideStep? {
        outcome == nil ? stoppedAt : nil
    }
}
