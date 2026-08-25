import SwiftUI
import UniformTypeIdentifiers
import WayforkCore

/// "Wayfork Settings": sidebar with Tunnels · Rules · General (docs/design/02-ux.md).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppModel.SettingsSection.allCases, selection: $model.settingsSection) { section in
                Label(section.title, systemImage: icon(for: section)).tag(section)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Group {
                switch model.settingsSection {
                case .tunnels: TunnelsSettingsView()
                case .rules: RulesSettingsView()
                case .general: GeneralSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 700, minHeight: 460)
        .dropDestination(for: URL.self) { urls, _ in
            let profiles = urls.filter { $0.pathExtension.lowercased() == "ovpn" }
            guard !profiles.isEmpty else { return false }
            Task {
                for url in profiles {
                    await model.importOpenVPN(from: url)
                }
            }
            return true
        }
    }

    private func icon(for section: AppModel.SettingsSection) -> String {
        switch section {
        case .tunnels: "network"
        case .rules: "arrow.triangle.branch"
        case .general: "gearshape"
        }
    }
}
