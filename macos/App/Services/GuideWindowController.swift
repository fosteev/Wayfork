import AppKit
import SwiftUI
import WayforkCore

/// Owns the first-run guide's window (docs/design/02-ux.md, "Window and trigger"): a plain
/// `NSWindow` hosting `GuideView`, not a SwiftUI `Window` scene — those open through
/// `openWindow`, which is only reachable once a scene has appeared, and at launch none has.
@MainActor
final class GuideWindowController: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the window, creating it the first time; brings an already-open window to the
    /// front instead of moving it to `step`.
    func show(startAt step: GuideStep) {
        guard let model else { return }
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: GuideView(startStep: step).environment(model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set up Wayfork"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 600, height: 410))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Called by `AppModel` after `finishGuide()` / `skipGuide()` set the outcome, so the
    /// window goes away without `windowWillClose` recording a bogus `stoppedAt`.
    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model?.recordGuideWindowClosed()
    }
}
