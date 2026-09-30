import Combine
import Foundation

/// How close a window is to its limit, by remaining quota.
enum UsageAlertLevel: Int, Comparable, Sendable {
    case ok, low, critical, exhausted

    static let lowThreshold = 20
    static let criticalThreshold = 10

    init(remainingPercent remaining: Int) {
        if remaining <= 0 {
            self = .exhausted
        } else if remaining <= Self.criticalThreshold {
            self = .critical
        } else if remaining <= Self.lowThreshold {
            self = .low
        } else {
            self = .ok
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct UsageAlert: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Remaining quota fell to 20 %, 10 % or 0 %.
        case level(UsageAlertLevel)
        /// A window that had run low started a new period.
        case reset
    }

    let provider: ProviderID
    let window: UsageWindow
    let kind: Kind

    var identifier: String { "usage.\(provider.rawValue).\(window.id)" }
}

/// Decides when to alert from successive official readings. It only alerts
/// on a change it saw happen: never on the first reading of a window, and
/// never from stale data, so launching the app or waking the Mac is quiet.
struct UsageAlertPolicy {
    private struct Seen {
        let level: UsageAlertLevel
        let resetsAt: Date?
        let usedPercent: Int
    }

    private var seen: [String: Seen] = [:]

    mutating func alerts(for snapshots: [UsageSnapshot]) -> [UsageAlert] {
        var alerts: [UsageAlert] = []
        for snapshot in snapshots where snapshot.freshness == .fresh {
            for window in snapshot.windows {
                let key = "\(snapshot.id.rawValue)|\(window.id)"
                let level = UsageAlertLevel(remainingPercent: window.remainingPercent)
                let previous = seen[key]
                seen[key] = Seen(level: level, resetsAt: window.resetsAt, usedPercent: window.usedPercent)
                guard let previous else { continue }

                if Self.startedNewPeriod(previous: previous, window: window) {
                    if previous.level >= .low, level < .low {
                        alerts.append(UsageAlert(provider: snapshot.id, window: window, kind: .reset))
                    }
                } else if level > previous.level, level >= .low {
                    alerts.append(UsageAlert(provider: snapshot.id, window: window, kind: .level(level)))
                }
            }
        }
        return alerts
    }

    /// Reset times move later when a new period starts (sub-second jitter
    /// between readings is ignored); without them, a large drop in usage is
    /// the only sign.
    private static func startedNewPeriod(previous: Seen, window: UsageWindow) -> Bool {
        if let before = previous.resetsAt, let after = window.resetsAt {
            return after.timeIntervalSince(before) > 60
        }
        return previous.usedPercent - window.usedPercent >= 50
    }
}

/// Watches the store and posts the policy's alerts when the user has
/// alerts turned on.
@MainActor
final class UsageAlertMonitor {
    private let model: AppModel
    private let preferences: AppPreferences
    private let notifier: any UsageNotifying
    private let clock: any UsageClock
    private var policy = UsageAlertPolicy()
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel, preferences: AppPreferences, notifier: any UsageNotifying, clock: any UsageClock) {
        self.model = model
        self.preferences = preferences
        self.notifier = notifier
        self.clock = clock
    }

    func start() {
        model.$providers
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots in
                MainActor.assumeIsolated { self?.evaluate(snapshots) }
            }
            .store(in: &subscriptions)
        preferences.$usageAlerts
            .removeDuplicates()
            .sink { [notifier] enabled in
                if enabled { Task { _ = await notifier.requestAuthorization() } }
            }
            .store(in: &subscriptions)
    }

    func stop() {
        subscriptions.removeAll()
    }

    /// The policy always tracks readings, so turning alerts on later does
    /// not replay old crossings.
    func evaluate(_ snapshots: [UsageSnapshot]) {
        let alerts = policy.alerts(for: snapshots)
        guard preferences.usageAlerts else { return }
        for alert in alerts {
            let message = Self.message(for: alert, now: clock.now(), preferences: preferences)
            let notifier = notifier
            Task { await notifier.post(id: alert.identifier, title: message.title, body: message.body) }
        }
    }

    static func message(for alert: UsageAlert, now: Date, preferences: AppPreferences) -> (title: String, body: String) {
        let title = "\(alert.provider.displayName) · " + CodexEdgeText.windowTitle(alert.window, preferences: preferences)
        let remaining = alert.window.remainingPercent
        let reset = CodexEdgeText.resetLabel(alert.window.resetsAt, now: now, preferences: preferences)
        switch alert.kind {
        case .level(.exhausted):
            return (title, preferences.text("Limit reached. \(reset).", "Límite alcanzado. \(reset)."))
        case .level:
            return (title, preferences.text("\(remaining)% left. \(reset).", "Te queda \(remaining) %. \(reset)."))
        case .reset:
            return (title, preferences.text("Reset: \(remaining)% available again.", "Se reinició: vuelves a tener \(remaining) % disponible."))
        }
    }
}
