import SwiftUI
import WayforkCore

@main
struct WayforkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .onAppear { model.windowOpener = { id in openWindow(id: id) } }
        } label: {
            Image(model.menuBarIconName)
                .help(model.summary)
        }
        .menuBarExtraStyle(.window)

        Window("Wayfork Settings", id: AppModel.settingsWindowID) {
            SettingsView()
                .environment(model)
                .onAppear { model.windowOpener = { id in openWindow(id: id) } }
        }
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)

        Window("Logs", id: AppModel.logsWindowID) {
            LogsWindowView()
                .environment(model)
                .onAppear { model.windowOpener = { id in openWindow(id: id) } }
        }
        .defaultSize(width: 900, height: 500)
        .windowResizability(.contentMinSize)
    }
}
