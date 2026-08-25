import SwiftUI
import WayforkCore

@main
struct WayforkApp: App {
    var body: some Scene {
        MenuBarExtra("Wayfork", systemImage: "arrow.triangle.branch") {
            PlaceholderView()
        }
        .menuBarExtraStyle(.window)
    }
}

/// M0 placeholder; replaced by the popover dashboard in M3.
struct PlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wayfork \(WayforkCore.version)")
                .font(.headline)
            Text("Scaffolding build — nothing is wired up yet.")
                .foregroundStyle(.secondary)
            Button("Quit Wayfork") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280)
    }
}
