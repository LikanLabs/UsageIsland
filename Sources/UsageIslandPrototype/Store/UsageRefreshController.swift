import AppKit
import Combine

/// Owns polling and power lifecycle independently of the UI's visibility.
@MainActor
final class UsageRefreshController {
    private let model: AppModel
    private let notifications: NotificationCenter
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var running = false
    private var sleeping = false

    init(model: AppModel,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         interval: Duration = .seconds(60)) {
        self.model = model
        self.notifications = notifications
        self.interval = interval
    }

    func start() {
        guard !running else { return }
        running = true
        notifications.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.suspend() }
            .store(in: &subscriptions)
        notifications.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resume() }
            .store(in: &subscriptions)
        schedule(refreshImmediately: false)
    }

    func suspend() {
        guard running else { return }
        sleeping = true
        task?.cancel()
        task = nil
        model.suspendRefresh()
    }

    func resume() {
        guard running, sleeping else { return }
        sleeping = false
        schedule(refreshImmediately: true)
    }

    func stop() {
        running = false
        sleeping = false
        task?.cancel()
        task = nil
        subscriptions.removeAll()
    }

    private func schedule(refreshImmediately: Bool) {
        task?.cancel()
        task = Task { [weak self, interval] in
            if refreshImmediately { await self?.refreshIfNeeded() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard self != nil else { return }
                await self?.refreshIfNeeded()
            }
        }
    }

    private func refreshIfNeeded() async {
        guard running, !sleeping, !Task.isCancelled,
              !model.connectionStates.values.contains(.connecting) else { return }
        await model.refreshUsage()
    }
}
