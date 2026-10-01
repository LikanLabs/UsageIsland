import Foundation
import XCTest
@testable import UsageIslandPrototype

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func reading(
    _ provider: ProviderID = .claude,
    session: Int,
    week: Int? = nil,
    at minutes: Double,
    sessionResets: Date = t0.addingTimeInterval(3 * 3_600),
    freshness: DataFreshness = .fresh
) throws -> UsageSnapshot {
    var additional: [UsageWindow] = []
    if let week {
        additional.append(try UsageWindow(durationMinutes: 10_080, usedPercent: week, resetsAt: t0.addingTimeInterval(5 * 86_400)))
    }
    return try UsageSnapshot(
        provider: provider,
        preferredWindow: UsageWindow(durationMinutes: 300, usedPercent: session, resetsAt: sessionResets),
        additionalWindows: additional,
        weeklySpend: nil,
        freshness: freshness,
        isActivelyUsed: false,
        capturedAt: t0.addingTimeInterval(minutes * 60)
    )
}

final class UsageForecasterTests: XCTestCase {
    func testSteadyUseProjectsWhenItRunsOut() throws {
        var forecaster = UsageForecaster()
        for (minute, used) in [(0.0, 40), (5, 42), (10, 44)] {
            forecaster.record(try reading(session: used, at: minute))
        }
        let latest = try reading(session: 44, at: 10)
        // 4 points in 10 minutes: 56 left last 140 minutes, before the 3 h reset.
        let forecast = forecaster.headline(for: latest, now: t0.addingTimeInterval(10 * 60))
        XCTAssertEqual(forecast?.outcome, .runsOut(at: t0.addingTimeInterval((10 + 140) * 60)))
        XCTAssertEqual(forecast?.window.durationMinutes, 300)
    }

    func testEnoughLeftUntilTheReset() throws {
        var forecaster = UsageForecaster()
        let resets = t0.addingTimeInterval(60 * 60)
        for (minute, used) in [(0.0, 40), (10, 42)] {
            forecaster.record(try reading(session: used, at: minute, sessionResets: resets))
        }
        let forecast = forecaster.headline(for: try reading(session: 42, at: 10, sessionResets: resets), now: t0.addingTimeInterval(10 * 60))
        XCTAssertEqual(forecast?.outcome, .lastsUntilReset)
    }

    func testTooLittleDataOrTooSmallARiseGivesNoForecast() throws {
        var short = UsageForecaster()
        short.record(try reading(session: 40, at: 0))
        short.record(try reading(session: 45, at: 3))
        XCTAssertNil(short.headline(for: try reading(session: 45, at: 3), now: t0.addingTimeInterval(180)), "under 5 minutes")

        var flat = UsageForecaster()
        flat.record(try reading(session: 40, at: 0))
        flat.record(try reading(session: 41, at: 10))
        XCTAssertNil(flat.headline(for: try reading(session: 41, at: 10), now: t0.addingTimeInterval(600)), "a single point is noise")
    }

    func testStoppingWorkClearsTheForecast() throws {
        var forecaster = UsageForecaster()
        for (minute, used) in [(0.0, 40), (5, 44), (8, 46), (15, 46), (20, 46)] {
            forecaster.record(try reading(session: used, at: minute))
        }
        XCTAssertNotNil(forecaster.headline(for: try reading(session: 46, at: 15), now: t0.addingTimeInterval(15 * 60)))
        XCTAssertNil(forecaster.headline(for: try reading(session: 46, at: 20), now: t0.addingTimeInterval(19 * 60)),
                     "no rise in the last 10 minutes")
    }

    func testANewPeriodStartsOver() throws {
        var forecaster = UsageForecaster()
        forecaster.record(try reading(session: 80, at: 0))
        forecaster.record(try reading(session: 90, at: 10))
        let next = t0.addingTimeInterval(8 * 3_600)
        forecaster.record(try reading(session: 1, at: 12, sessionResets: next))
        XCTAssertNil(forecaster.headline(for: try reading(session: 1, at: 12, sessionResets: next), now: t0.addingTimeInterval(12 * 60)))
    }

    func testStaleReadingsAreIgnored() throws {
        var forecaster = UsageForecaster()
        forecaster.record(try reading(session: 40, at: 0))
        forecaster.record(try reading(session: 60, at: 10, freshness: .stale))
        XCTAssertNil(forecaster.headline(for: try reading(session: 40, at: 0), now: t0.addingTimeInterval(600)))
    }

    func testTheWindowThatRunsOutFirstIsTheHeadline() throws {
        var forecaster = UsageForecaster()
        // The session has room until its reset; the week is nearly spent.
        let resets = t0.addingTimeInterval(30 * 60)
        for (minute, session, week) in [(0.0, 10, 90), (10, 12, 95)] {
            forecaster.record(try reading(session: session, week: week, at: minute, sessionResets: resets))
        }
        let forecast = forecaster.headline(for: try reading(session: 12, week: 95, at: 10, sessionResets: resets),
                                           now: t0.addingTimeInterval(600))
        XCTAssertEqual(forecast?.window.durationMinutes, 10_080)
        XCTAssertEqual(forecast?.outcome, .runsOut(at: t0.addingTimeInterval((10 + 10) * 60)))
    }
}

@MainActor
final class ModelForecastTests: XCTestCase {
    func testModelForecastsFromItsOwnRefreshes() async throws {
        let clock = ForecastClock(t0)
        let provider = SequenceProvider()
        let model = try AppModel(providerAdapters: [provider], clock: clock, initialSnapshots: [])
        for (minute, used) in [(0.0, 50), (5, 53), (10, 56)] {
            clock.current = t0.addingTimeInterval(minute * 60)
            await provider.set(try reading(.codex, session: used, at: minute))
            await model.refreshUsage()
        }
        guard case .runsOut? = model.forecast(for: .codex)?.outcome else {
            return XCTFail("expected a run-out forecast")
        }
        XCTAssertNil(model.forecast(for: .claude))
    }
}

private final class ForecastClock: UsageClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var current: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func now() -> Date { current }
}

private actor SequenceProvider: UsageProvider {
    nonisolated let id: ProviderID = .codex
    private var next: UsageSnapshot?
    func set(_ snapshot: UsageSnapshot) { next = snapshot }
    func fetchUsage() async throws -> UsageSnapshot {
        guard let next else { throw CodexUsageError.rateLimitsUnavailable }
        return next
    }
}
