import AppKit
import Foundation
import UserNotifications

/// Posts local notifications. Nothing leaves the Mac.
protocol UsageNotifying: Sendable {
    func requestAuthorization() async -> Bool
    /// True when the user turned notifications off for this app.
    func isDenied() async -> Bool
    func post(id: String, title: String, body: String) async
}

/// `UNUserNotificationCenter` needs a real app bundle; outside one (for
/// example `swift run`) every call is a no-op.
final class SystemUsageNotifier: NSObject, UsageNotifying, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isDenied() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    func post(id: String, title: String, body: String) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // One identifier per window: a newer alert replaces the older one.
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Show banners even while the usage panel has focus.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
