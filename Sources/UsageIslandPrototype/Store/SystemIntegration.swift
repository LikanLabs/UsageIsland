import Combine
import Foundation

/// System-level settings shown in the panel: opening at login and whether
/// macOS lets the app post notifications.
@MainActor
final class SystemIntegration: ObservableObject {
    @Published private(set) var loginItem: LoginItemState
    @Published private(set) var notificationsDenied = false

    private let login: any LoginItemControlling
    private let notifier: any UsageNotifying

    init(login: any LoginItemControlling, notifier: any UsageNotifying) {
        self.login = login
        self.notifier = notifier
        loginItem = login.state()
    }

    var opensAtLogin: Bool {
        loginItem == .enabled || loginItem == .requiresApproval
    }

    func setOpensAtLogin(_ enabled: Bool) {
        try? login.setEnabled(enabled)
        loginItem = login.state()
    }

    func openLoginItemsSettings() {
        login.openSystemSettings()
    }

    func openNotificationSettings() {
        SystemUsageNotifier.openSystemSettings()
    }

    /// Re-read both states, for example when settings appear: the user may
    /// have changed them in System Settings meanwhile.
    func refresh() {
        loginItem = login.state()
        let notifier = notifier
        Task { [weak self] in
            let denied = await notifier.isDenied()
            self?.notificationsDenied = denied
        }
    }
}
