import Foundation
import UserNotifications

/// User notifications for permanent failures (docs/design/02-ux.md, "Notifications").
@MainActor
final class Notifier {
    private var authorizationRequested = false
    private let available =
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"

    func post(id: String, title: String, body: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let deliver = {
            center.add(request) { _ in }
        }
        if authorizationRequested {
            deliver()
        } else {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { deliver() }
            }
        }
    }
}
