import AppKit
import SwiftUI
import WayforkCore

/// The *Local proxy* row of an expanded tunnel or group (F17, docs/design/02-ux.md,
/// "Variant C" › Settings › Tunnels): switch, `127.0.0.1:‹port›` with the port editable
/// on click, Copy, and a one-line hint.
struct LocalProxyRow: View {
    @Environment(AppModel.self) private var model
    let exitID: UUID
    let exitName: String

    @State private var editingPort = false
    @State private var portText = ""
    @State private var portError: String?
    @FocusState private var portFocused: Bool

    private var proxy: LocalProxy? { model.store.localProxy(ofExit: exitID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Toggle(
                    "Local proxy",
                    isOn: Binding(
                        get: { proxy?.isEnabled ?? false },
                        set: { model.setLocalProxy(exitID: exitID, enabled: $0) })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                if let proxy, proxy.isEnabled {
                    address(proxy)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(proxy.copyText, forType: .string)
                    }
                    .controlSize(.small)
                    .help("Copies \(proxy.copyText)")
                } else {
                    Text("Off").foregroundStyle(.secondary)
                }
            }
            Text(hint.text)
                .font(.system(size: 11))
                .foregroundStyle(hint.isError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `127.0.0.1:` + the port in bold; a click turns the port into a field.
    @ViewBuilder
    private func address(_ proxy: LocalProxy) -> some View {
        HStack(spacing: 0) {
            Text("\(LocalProxy.listenAddress):")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            if editingPort {
                TextField("Port", text: $portText)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .focused($portFocused)
                    .onSubmit(commitPort)
                    .onExitCommand { editingPort = false }
                    .invalidOutline(portError != nil)
                    .onAppear { portFocused = true }
                    .onChange(of: portFocused) { _, focused in
                        if !focused, editingPort { commitPort() }
                    }
            } else {
                Text(String(proxy.port))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        portText = String(proxy.port)
                        portError = nil
                        editingPort = true
                    }
                    .help("Click to change the port")
            }
        }
    }

    private var hint: (text: String, isError: Bool) {
        if let portError { return (portError, true) }
        guard let proxy, proxy.isEnabled else {
            return (LocalProxyText.offHint(exitName: exitName), false)
        }
        if model.isLocalProxyPortTaken(exitID: exitID) {
            return (LocalProxyText.portTaken(proxy.port), true)
        }
        return (LocalProxyText.onHint(exitName: exitName), false)
    }

    private func commitPort() {
        guard editingPort else { return }
        if portText == String(proxy?.port ?? 0) {
            editingPort = false
            portError = nil
            return
        }
        if let message = model.setLocalProxyPort(exitID: exitID, portText) {
            portError = message
        } else {
            portError = nil
            editingPort = false
        }
    }
}
