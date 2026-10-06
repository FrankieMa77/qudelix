import Foundation
@preconcurrency import UserNotifications

@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()

    nonisolated static func canPost(bundleIdentifier: String?, bundleURL: URL) -> Bool {
        bundleIdentifier != nil && bundleURL.pathExtension == "app"
    }

    static let canNotify = canPost(bundleIdentifier: Bundle.main.bundleIdentifier,
                                   bundleURL: Bundle.main.bundleURL)

    nonisolated static let maxIdentifierLength = 64
    nonisolated static let maxTitleLength = 120
    nonisolated static let maxBodyLength = 160

    nonisolated static func identifier(_ prefix: String, _ raw: String = "") -> String {
        String((prefix + SafeText.scrubbed(raw, limit: maxIdentifierLength))
            .prefix(maxIdentifierLength))
    }

    private var delegateInstalled = false

    func post(id: String, title: String, body: String) {
        guard Self.canNotify else { return }
        let title = SafeText.scrubbed(title, limit: Self.maxTitleLength)
        let body = SafeText.scrubbed(body, limit: Self.maxBodyLength)
        let id = String(id.prefix(Self.maxIdentifierLength))
        let center = UNUserNotificationCenter.current()
        if !delegateInstalled {
            delegateInstalled = true
            center.delegate = self
        }
        let fire = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content,
                                             trigger: nil))
        }
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { fire() }
                }
            } else {
                fire()
            }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
