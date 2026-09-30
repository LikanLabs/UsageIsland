import Foundation
import ServiceManagement

enum LoginItemState: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user must allow it in System Settings.
    case requiresApproval
    /// Not running from an app bundle (for example `swift run`).
    case unavailable
}

/// Opening at login through the system's login items (`SMAppService`).
protocol LoginItemControlling: Sendable {
    func state() -> LoginItemState
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

struct SystemLoginItem: LoginItemControlling {
    /// Login items need a real app bundle.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func state() -> LoginItemState {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isBundled else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
