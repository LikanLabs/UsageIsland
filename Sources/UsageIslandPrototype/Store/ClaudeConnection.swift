import Combine
import Foundation

/// Connect/disconnect state for the Claude Code status line bridge, and the
/// watcher that refreshes Claude usage as soon as the bridge writes.
@MainActor
final class ClaudeConnection: ObservableObject {
    @Published private(set) var status: ClaudeBridgeStatus
    @Published private(set) var lastError: ClaudeSettingsError?

    private let installer: ClaudeSettingsInstaller
    private let model: AppModel
    private let recordURL: URL
    private var watcher: DirectoryChangeWatcher?

    init(installer: ClaudeSettingsInstaller, model: AppModel, recordURL: URL = ClaudeStatuslineBridge.defaultRecordURL) {
        self.installer = installer
        self.model = model
        self.recordURL = recordURL
        status = installer.status()
        watcher = DirectoryChangeWatcher(directory: recordURL.deletingLastPathComponent()) { [weak model] in
            Task { await model?.refreshUsage(for: .claude) }
        }
    }

    func start() {
        installer.repairIfNeeded()
        reloadStatus()
        watcher?.start()
    }

    func stop() {
        watcher?.stop()
    }

    func connect() {
        do {
            try installer.install()
            lastError = nil
        } catch {
            lastError = error
        }
        reloadStatus()
    }

    func disconnect() {
        do {
            try installer.uninstall()
            lastError = nil
            // Without the bridge the stored reading would only age; forget it.
            try? FileManager.default.removeItem(at: recordURL)
            model.clearUsage(for: .claude)
        } catch {
            lastError = error
        }
        reloadStatus()
    }

    func reloadStatus() {
        let current = installer.status()
        if current != status { status = current }
    }
}
