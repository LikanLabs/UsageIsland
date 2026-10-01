import Foundation

/// "Will it last?" for one window, extrapolated from the official readings
/// of the last half hour. Always presented as an estimate; it is never used
/// as a quota figure.
struct UsageForecast: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// At the recent pace the window runs out before it resets.
        case runsOut(at: Date)
        /// At the recent pace there is enough left until the reset.
        case lastsUntilReset
    }

    let window: UsageWindow
    let outcome: Outcome
}

/// Keeps recent official readings per window and projects them forward.
///
/// Percentages move in whole points, so a projection needs at least
/// `minimumRise` points over at least `minimumSpan`, and a rise within
/// `activeWithin`: someone who stopped working gets no forecast instead of
/// a stale one.
struct UsageForecaster {
    static let lookback: TimeInterval = 30 * 60
    static let minimumSpan: TimeInterval = 5 * 60
    static let minimumRise = 2
    static let activeWithin: TimeInterval = 10 * 60

    private struct Sample {
        let time: Date
        let used: Int
    }

    private struct History {
        var resetsAt: Date?
        var samples: [Sample] = []
        var lastRise: Date?
    }

    private var histories: [String: History] = [:]

    mutating func record(_ snapshot: UsageSnapshot) {
        guard snapshot.freshness == .fresh else { return }
        let time = snapshot.capturedAt
        for window in snapshot.windows {
            let key = Self.key(snapshot.id, window)
            var history = histories[key] ?? History(resetsAt: window.resetsAt)
            // A new period starts from scratch.
            if let before = history.resetsAt, let after = window.resetsAt, after.timeIntervalSince(before) > 60 {
                history = History(resetsAt: window.resetsAt)
            } else if let last = history.samples.last, window.usedPercent < last.used {
                history = History(resetsAt: window.resetsAt)
            }
            history.resetsAt = window.resetsAt
            if let last = history.samples.last {
                guard time > last.time else { continue }
                if window.usedPercent > last.used { history.lastRise = time }
            }
            history.samples.append(Sample(time: time, used: window.usedPercent))
            history.samples.removeAll { time.timeIntervalSince($0.time) > Self.lookback }
            histories[key] = history
        }
    }

    func forecast(for window: UsageWindow, of provider: ProviderID, now: Date) -> UsageForecast? {
        guard let history = histories[Self.key(provider, window)],
              let first = history.samples.first, let last = history.samples.last,
              let lastRise = history.lastRise, now.timeIntervalSince(lastRise) <= Self.activeWithin else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        let rise = last.used - first.used
        guard span >= Self.minimumSpan, rise >= Self.minimumRise, last.used < 100 else { return nil }

        let perSecond = Double(rise) / span
        let runsOutAt = last.time.addingTimeInterval(Double(100 - last.used) / perSecond)
        if let resetsAt = window.resetsAt, runsOutAt >= resetsAt {
            return UsageForecast(window: window, outcome: .lastsUntilReset)
        }
        return UsageForecast(window: window, outcome: .runsOut(at: runsOutAt))
    }

    /// The forecast worth one line in a card: the window that runs out
    /// first, or else reassurance for the window the pill shows.
    func headline(for snapshot: UsageSnapshot, now: Date) -> UsageForecast? {
        let forecasts = snapshot.windows.compactMap { forecast(for: $0, of: snapshot.id, now: now) }
        let soonest = forecasts.compactMap { forecast -> (UsageForecast, Date)? in
            if case .runsOut(let date) = forecast.outcome { return (forecast, date) }
            return nil
        }.min { $0.1 < $1.1 }?.0
        return soonest ?? forecasts.first { $0.window.id == snapshot.preferredWindow.id }
    }

    private static func key(_ provider: ProviderID, _ window: UsageWindow) -> String {
        "\(provider.rawValue)|\(window.id)"
    }
}
