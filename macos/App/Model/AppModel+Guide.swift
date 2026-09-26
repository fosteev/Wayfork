import Foundation
import WayforkCore

// First-run guide (F22, docs/design/02-ux.md "First-run guide"): the window, its state and
// the Getting started card that follows it in the popover.

extension AppModel {
    /// Opens by itself at launch when there are no tunnels and the guide has never run to
    /// an outcome. Called from `AppDelegate` after `bootstrap()`.
    func autoOpenGuideIfNeeded() {
        // A store written by a newer Wayfork loads as empty: that is not a first run.
        guard !persistenceDisabled,
            guideState.shouldAutoOpen(tunnelCount: store.tunnels.count)
        else { return }
        openGuide()
    }

    /// Opens the guide window. `step` nil resumes where it was left (or step 1 for a first
    /// run); General › *Welcome guide* passes `.welcome` explicitly to always restart at 1.
    /// Opening it while it is already open just brings it to the front.
    func openGuide(at step: GuideStep? = nil) {
        if let open = guideWindowController {
            // Already on screen: to the front, on the step it shows.
            open.show(startAt: guideCurrentStep)
            return
        }
        let controller = GuideWindowController(model: self)
        guideWindowController = controller
        var start = step ?? guideState.resumeStep ?? .welcome
        // Steps after Add a VPN need the tunnel that step added, which only lives in the
        // closed window; without tunnels, resume at Add a VPN instead.
        if store.tunnels.isEmpty, start.isAfter(.addVPN) { start = .addVPN }
        guideCurrentStep = start
        controller.show(startAt: start)
    }

    /// The guide view calls this as the user moves between steps, so a window closed from
    /// the titlebar (not Skip guide, not Done) records the right `stoppedAt`.
    func guideStepChanged(_ step: GuideStep) {
        guideCurrentStep = step
    }

    /// *Done* (step 6) or *Skip this step*: the guide ran its course.
    func finishGuide() {
        guideState.outcome = .finished
        guideState.cardActive = true
        persistGuideState()
        guideWindowController?.close()
    }

    /// *Skip guide* (steps 1–5): final, unlike closing the window.
    func skipGuide() {
        guideState.outcome = .skipped
        persistGuideState()
        guideWindowController?.close()
    }

    /// The window closed without an outcome (titlebar close, ⌘W): not a skip — records the
    /// step so the No-tunnels popover can offer to resume there.
    func recordGuideWindowClosed() {
        guideWindowController = nil
        guard guideState.outcome == nil else { return }
        guideState.stoppedAt = guideCurrentStep
        persistGuideState()
    }

    /// General › *Welcome guide* › *Show*.
    func replayGuide() {
        openGuide(at: .welcome)
    }

    /// General › *Getting started card* › *Show*: activates it and clears the ticks.
    func replayGettingStartedCard() {
        guideState.cardActive = true
        guideState.cardDismissed = false
        guideState.cardDone = []
        persistGuideState()
    }

    /// × on the card: gone for good.
    func dismissGuideCard() {
        guideState.cardDismissed = true
        persistGuideState()
    }

    /// Ticks one Getting started item the first time it happens. Called from the popover
    /// views themselves (quick add, Recent *Route via*, the Can't reach pane, an app rule
    /// save) — never from the shared model functions they call, which the guide also calls
    /// while walking steps 3–4 and must not tick early.
    func tickGuideCard(_ item: GuideCardItem) {
        guard guideState.cardDone.insert(item).inserted else { return }
        persistGuideState()
    }

    private func persistGuideState() {
        guideStore.save(guideState)
    }
}
