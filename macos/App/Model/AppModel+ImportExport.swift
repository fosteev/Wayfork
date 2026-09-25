import AppKit
import Foundation
import UniformTypeIdentifiers
import WayforkCore

// Import / export of `wayfork-export.json` (F7, docs/design/01-data-model.md).

extension AppModel {
    static let exportFileName = "wayfork-export.json"

    /// Save panel + export. `includeSecrets` comes from the sheet checkbox.
    func exportStore(includeSecrets: Bool) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AppModel.exportFileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            let document = try StoreExporter.document(
                store: store, secretStore: secrets, includeSecrets: includeSecrets)
            try document.encode().write(to: url, options: .atomic)
            if includeSecrets {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            logs.app(
                .info,
                "exported \(document.tunnels.count) tunnels, \(document.rules.count) rules"
                    + (includeSecrets ? " with secrets" : ""))
        } catch {
            logs.app(.error, "export failed: \(error)")
            Alerts.show(title: "Export failed", message: error.localizedDescription)
        }
    }

    /// Open panel → document; nil when cancelled or invalid (an alert was shown).
    func pickImportDocument() async -> ExportDocument? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a wayfork-export.json"
        NSApp.activate(ignoringOtherApps: true)
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        do {
            return try ExportDocument.decode(try Data(contentsOf: url))
        } catch ExportDocument.Error.unknownFormat(let format) {
            Alerts.show(
                title: "Not a Wayfork export",
                message: "The file's format is \"\(format)\", expected \"wayfork-export\".")
        } catch ExportDocument.Error.newerVersion(let version) {
            Alerts.show(
                title: "Export from a newer Wayfork",
                message: "The file uses export format version \(version); update Wayfork.")
        } catch {
            Alerts.show(title: "Cannot import", message: error.localizedDescription)
        }
        return nil
    }

    func performImport(_ document: ExportDocument, mode: ImportMode) {
        let outcome = StoreImporter.apply(document, to: store, mode: mode)
        var keychainErrors = 0
        for (key, value) in outcome.secrets {
            do {
                try secrets.write(value, for: key)
            } catch {
                keychainErrors += 1
                logs.app(.error, "cannot store imported secret \(key.account): \(error)")
            }
        }
        update { $0 = outcome.store }
        if mode == .replace {
            try? secrets.removeOrphans(keeping: store)
            recomputeMissingSecrets()
            do {
                try HelperInstaller.setLaunchAtLogin(store.settings.launchAtLogin)
            } catch {
                logs.app(.warning, "launch at login: \(error.localizedDescription)")
            }
        }
        for warning in outcome.warnings {
            logs.app(.warning, "import: \(warning)")
        }
        logs.app(
            .info,
            "import (\(mode)): +\(outcome.tunnelsAdded)/~\(outcome.tunnelsUpdated) tunnels, +\(outcome.rulesAdded)/~\(outcome.rulesUpdated) rules, \(outcome.rulesSkipped) skipped"
        )
        if !outcome.warnings.isEmpty || keychainErrors > 0 {
            var lines = outcome.warnings
            if keychainErrors > 0 { lines.append("\(keychainErrors) secrets could not be stored.") }
            Alerts.show(
                title: "Import finished with warnings",
                message: lines.prefix(12).joined(separator: "\n"))
        }
    }
}
