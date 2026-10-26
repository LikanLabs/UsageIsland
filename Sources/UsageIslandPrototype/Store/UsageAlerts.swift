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
        /// A window started a new period well before its scheduled reset,
        /// whatever its level.
        case earlyReset
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
                    if Self.resetEarly(previous: previous, window: window, observedAt: snapshot.capturedAt) {
                        alerts.append(UsageAlert(provider: snapshot.id, window: window, kind: .earlyReset))
                    } else if previous.level >= .low, level < .low {
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

    /// How far ahead of the scheduled reset, and how much quota it must give
    /// back, for a new period to count as an early reset.
    static let earlyResetLead: TimeInterval = 600
    static let earlyResetMinimumGain = 15

    /// Providers sometimes reset limits ahead of schedule (Codex announced
    /// dozens of resets in 2026). In fresh readings that is a new period that
    /// began clearly before the old reset time and gave back a real share.
    private static func resetEarly(previous: Seen, window: UsageWindow, observedAt: Date) -> Bool {
        guard let scheduled = previous.resetsAt else { return false }
        return observedAt < scheduled.addingTimeInterval(-earlyResetLead)
            && previous.usedPercent - window.usedPercent >= earlyResetMinimumGain
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
        // Ask for permission once alerts are on and the welcome page is
        // done, whichever comes last: alerts start on, so a welcome page
        // closed without "Get started" must still lead to the request,
        // or every alert would be dropped with no sign in the settings.
        preferences.$usageAlerts
            .combineLatest(preferences.$hasCompletedOnboarding) { $0 && $1 }
            .removeDuplicates()
            .sink { [weak self] shouldAsk in
                MainActor.assumeIsolated {
                    guard let self, shouldAsk else { return }
                    let notifier = self.notifier
                    Task { _ = await notifier.requestAuthorization() }
                }
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
            let others = snapshots.filter { $0.provider != alert.provider }
            let message = Self.message(for: alert, now: clock.now(), preferences: preferences, others: others)
            let notifier = notifier
            Task { await notifier.post(id: alert.identifier, title: message.title, body: message.body) }
        }
    }

    /// `others` are the other providers' readings: when a limit that stops
    /// all work runs out, the body says how much the other tool has left.
    static func message(for alert: UsageAlert, now: Date, preferences: AppPreferences,
                        others: [UsageSnapshot] = []) -> (title: String, body: String) {
        let title = "\(alert.provider.displayName) · " + CodexEdgeText.windowTitle(alert.window, preferences: preferences)
        let remaining = alert.window.remainingPercent
        let reset = CodexEdgeText.resetLabel(alert.window.resetsAt, now: now, preferences: preferences)
        switch alert.kind {
        case .level(.exhausted):
            let body = preferences.text("Limit reached. \(reset).", "Límite alcanzado. \(reset).")
            guard alert.window.scope == nil,
                  let other = others.lazy.compactMap({ alternative($0, now: now, preferences: preferences) }).first
            else { return (title, body) }
            return (title, body + " " + other)
        case .level:
            return (title, preferences.text("\(remaining)% left. \(reset).", "Te queda \(remaining) %. \(reset)."))
        case .reset:
            return (title, preferences.text("Reset: \(remaining)% available again.", "Se reinició: vuelves a tener \(remaining) % disponible."))
        case .earlyReset:
            return (title, preferences.text("Reset ahead of schedule: \(remaining)% available again.",
                                            "Se reinició antes de tiempo: vuelves a tener \(remaining) % disponible."))
        }
    }

    /// "Claude has 72% of its 5-hour limit left.", from a fresh reading
    /// whose own limit is not used up.
    static func alternative(_ snapshot: UsageSnapshot, now: Date, preferences: AppPreferences) -> String? {
        let window = snapshot.pillWindow(at: now)
        guard snapshot.freshness == .fresh, !window.hasReset(at: now), window.remainingPercent > 0 else { return nil }
        let name = snapshot.provider.displayName
        let left = window.remainingPercent
        switch window.durationMinutes {
        case 300:
            return preferences.text("\(name) has \(left)% of its 5-hour limit left.",
                                    "A \(name) le queda \(left) % de su límite de 5 horas.")
        case 10_080:
            return preferences.text("\(name) has \(left)% of its weekly limit left.",
                                    "A \(name) le queda \(left) % de su límite semanal.")
        default:
            return preferences.text("\(name) has \(left)% of its limit left.",
                                    "A \(name) le queda \(left) % de su límite.")
        }
    }
}
