import AppKit
import Combine

/// Owns polling and power lifecycle independently of the UI's visibility.
///
/// - System sleep suspends polling and marks readings stale; wake refreshes.
/// - A locked screen or sleeping displays only pause polling (nobody can see
///   the pill); unlocking or waking the displays refreshes right away.
/// - Low Power Mode stretches the interval.
@MainActor
final class UsageRefreshController {
    private enum Pause: Hashable {
        case locked
        case displaysAsleep
    }

    static let lowPowerMultiplier = 3

    private let model: AppModel
    private let notifications: NotificationCenter
    private let distributedNotifications: NotificationCenter
    private let powerNotifications: NotificationCenter
    private let interval: Duration
    private let isLowPowerMode: @MainActor () -> Bool
    private var task: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var running = false
    private var sleeping = false
    private var pauses: Set<Pause> = []

    init(model: AppModel,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributedNotifications: NotificationCenter = DistributedNotificationCenter.default(),
         powerNotifications: NotificationCenter = .default,
         interval: Duration = .seconds(60),
         isLowPowerMode: @escaping @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }) {
        self.model = model
        self.notifications = notifications
        self.distributedNotifications = distributedNotifications
        self.powerNotifications = powerNotifications
        self.interval = interval
        self.isLowPowerMode = isLowPowerMode
    }

    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    /// Seconds between polls right now.
    var currentInterval: Duration {
        isLowPowerMode() ? interval * Self.lowPowerMultiplier : interval
    }

    var isPaused: Bool { sleeping || !pauses.isEmpty }

    func start() {
        guard !running else { return }
        running = true
        observe(notifications, NSWorkspace.willSleepNotification) { $0.suspend() }
        observe(notifications, NSWorkspace.didWakeNotification) { $0.resume() }
        observe(notifications, NSWorkspace.screensDidSleepNotification) { $0.pause(.displaysAsleep) }
        observe(notifications, NSWorkspace.screensDidWakeNotification) { $0.unpause(.displaysAsleep) }
        observe(distributedNotifications, Self.screenLocked) { $0.pause(.locked) }
        observe(distributedNotifications, Self.screenUnlocked) { $0.unpause(.locked) }
        // A new power state takes effect from the next wait.
        observe(powerNotifications, Notification.Name.NSProcessInfoPowerStateDidChange) { $0.reschedule() }
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
        // Displays are awake after a system wake even if their own wake
        // notification was missed; a still-locked screen stays paused.
        pauses.remove(.displaysAsleep)
        if pauses.isEmpty { schedule(refreshImmediately: true) }
    }

    func stop() {
        running = false
        sleeping = false
        pauses.removeAll()
        task?.cancel()
        task = nil
        subscriptions.removeAll()
    }

    private func pause(_ reason: Pause) {
        guard running, pauses.insert(reason).inserted else { return }
        task?.cancel()
        task = nil
    }

    private func unpause(_ reason: Pause) {
        guard running, pauses.remove(reason) != nil, !isPaused else { return }
        schedule(refreshImmediately: true)
    }

    private func reschedule() {
        guard running, !isPaused else { return }
        schedule(refreshImmediately: false)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (UsageRefreshController) -> Void) {
        center.publisher(for: name)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            }
            .store(in: &subscriptions)
    }

    private func schedule(refreshImmediately: Bool) {
        task?.cancel()
        task = Task { [weak self] in
            if refreshImmediately { await self?.refreshIfNeeded() }
            while !Task.isCancelled {
                guard let wait = self?.currentInterval else { return }
                do { try await Task.sleep(for: wait) } catch { return }
                await self?.refreshIfNeeded()
            }
        }
    }

    private func refreshIfNeeded() async {
        guard running, !isPaused, !Task.isCancelled,
              !model.connectionStates.values.contains(.connecting) else { return }
        await model.refreshUsage()
    }
}
