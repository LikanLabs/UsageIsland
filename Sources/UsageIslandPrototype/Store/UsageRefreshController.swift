import AppKit
import CoreGraphics
import Combine

/// Owns polling and power lifecycle independently of the UI's visibility.
///
/// - System sleep suspends polling and marks readings stale; wake refreshes.
/// - A locked screen or sleeping displays skip polls (nobody can see the
///   pill). Each poll checks the real state, so a missed notification can
///   never leave polling paused; unlocking or waking refreshes right away.
/// - Low Power Mode stretches the interval.
@MainActor
final class UsageRefreshController {
    static let lowPowerMultiplier = 3

    private let model: AppModel
    private let notifications: NotificationCenter
    private let distributedNotifications: NotificationCenter
    private let powerNotifications: NotificationCenter
    private let interval: Duration
    private let isLowPowerMode: @MainActor () -> Bool
    private let isScreenLocked: @MainActor () -> Bool
    private let areDisplaysAsleep: @MainActor () -> Bool
    private var task: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var running = false
    private var sleeping = false

    init(model: AppModel,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributedNotifications: NotificationCenter = DistributedNotificationCenter.default(),
         powerNotifications: NotificationCenter = .default,
         interval: Duration = .seconds(60),
         isLowPowerMode: @escaping @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         isScreenLocked: @escaping @MainActor () -> Bool = UsageRefreshController.systemScreenIsLocked,
         areDisplaysAsleep: @escaping @MainActor () -> Bool = { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }) {
        self.model = model
        self.notifications = notifications
        self.distributedNotifications = distributedNotifications
        self.powerNotifications = powerNotifications
        self.interval = interval
        self.isLowPowerMode = isLowPowerMode
        self.isScreenLocked = isScreenLocked
        self.areDisplaysAsleep = areDisplaysAsleep
    }

    /// The login session's own lock flag, read fresh on every check.
    static func systemScreenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    /// Seconds between polls right now.
    var currentInterval: Duration {
        isLowPowerMode() ? interval * Self.lowPowerMultiplier : interval
    }

    var isPaused: Bool { sleeping || isScreenLocked() || areDisplaysAsleep() }

    func start() {
        guard !running else { return }
        running = true
        observe(notifications, NSWorkspace.willSleepNotification) { $0.suspend() }
        observe(notifications, NSWorkspace.didWakeNotification) { $0.resume() }
        // Locking or display sleep needs no handling: polls check the real
        // state. Coming back refreshes at once.
        observe(notifications, NSWorkspace.screensDidWakeNotification) { $0.refreshSoon() }
        observe(distributedNotifications, Self.screenUnlocked) { $0.refreshSoon() }
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
        schedule(refreshImmediately: true)
    }

    func stop() {
        running = false
        sleeping = false
        task?.cancel()
        task = nil
        subscriptions.removeAll()
    }

    private func refreshSoon() {
        guard running, !sleeping else { return }
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
