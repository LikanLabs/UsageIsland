import Foundation
import XCTest
@testable import UsageIslandPrototype

@MainActor
final class CodexEdgeTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testWindowTitlesNameCommonDurations() throws {
        let preferences = try makePreferences(.english)
        XCTAssertEqual(CodexEdgeText.windowTitle(300, preferences: preferences), "Session")
        XCTAssertEqual(CodexEdgeText.windowTitle(10_080, preferences: preferences), "Week")
        XCTAssertEqual(CodexEdgeText.windowTitle(1_440, preferences: preferences), "1 day")
        XCTAssertEqual(CodexEdgeText.windowTitle(4_320, preferences: preferences), "3 days")
        XCTAssertEqual(CodexEdgeText.windowTitle(120, preferences: preferences), "2 h")
        XCTAssertEqual(CodexEdgeText.windowTitle(45, preferences: preferences), "45 min")
        preferences.language = .spanish
        XCTAssertEqual(CodexEdgeText.windowTitle(4_320, preferences: preferences), "3 días")
    }

    func testPillNamesItsSingleLimit() throws {
        let preferences = try makePreferences(.spanish)
        XCTAssertEqual(CodexEdgeText.pillPeriod(300, preferences: preferences), "5 horas")
        XCTAssertEqual(CodexEdgeText.pillPeriod(10_080, preferences: preferences), "semanal")
        preferences.language = .english
        XCTAssertEqual(CodexEdgeText.pillPeriod(300, preferences: preferences), "5 hours")
        XCTAssertEqual(CodexEdgeText.pillPeriod(10_080, preferences: preferences), "weekly")
    }

    func testPillPrefersTheFiveHourLimitAndFallsBackToWeekly() throws {
        let weeklyOnly = try CodexUsageMapper.mapRateLimits(
            .object(["rateLimits": .object(["primary": .object(["windowDurationMins": .integer(10_080), "usedPercent": .integer(3), "resetsAt": .null])])]),
            capturedAt: now
        )
        XCTAssertEqual(weeklyOnly.preferredWindow.durationMinutes, 10_080)
        let both = try CodexUsageMapper.mapRateLimits(
            .object(["rateLimits": .object([
                "primary": .object(["windowDurationMins": .integer(10_080), "usedPercent": .integer(3), "resetsAt": .null]),
                "secondary": .object(["windowDurationMins": .integer(300), "usedPercent": .integer(9), "resetsAt": .null]),
            ])]),
            capturedAt: now
        )
        XCTAssertEqual(both.preferredWindow.durationMinutes, 300)
    }

    func testScopedWindowsAreNamedByTheirScope() throws {
        let preferences = try makePreferences(.english)
        let scoped = try UsageWindow(durationMinutes: 10_080, usedPercent: 1, resetsAt: nil, scope: "Fable")
        XCTAssertEqual(CodexEdgeText.windowTitle(scoped, preferences: preferences), "Fable week")
        preferences.language = .spanish
        XCTAssertEqual(CodexEdgeText.windowTitle(scoped, preferences: preferences), "Semana Fable")
        let plain = try UsageWindow(durationMinutes: 10_080, usedPercent: 1, resetsAt: nil)
        XCTAssertEqual(CodexEdgeText.windowTitle(plain, preferences: preferences), "Semana")
    }

    func testPlansWithoutSessionAreDetected() throws {
        let weeklyOnly = try UsageSnapshot(
            provider: .codex,
            preferredWindow: UsageWindow(durationMinutes: 10_080, usedPercent: 0, resetsAt: nil),
            additionalWindows: [], weeklySpend: nil, freshness: .fresh, isActivelyUsed: false, capturedAt: now
        )
        XCTAssertFalse(CodexUsageDetailView.hasSession(weeklyOnly))
        XCTAssertEqual(CodexEdgeLayout.gaugeRows(weeklyOnly).map { $0.map { $0?.id } }, [[nil, "10080|"]])
    }

    func testExtraLimitGroupsGetTheirOwnRows() throws {
        let windows = [
            try UsageWindow(durationMinutes: 10_080, usedPercent: 0, resetsAt: nil),
            try UsageWindow(durationMinutes: 300, usedPercent: 1, resetsAt: nil, scope: "Spark"),
            try UsageWindow(durationMinutes: 10_080, usedPercent: 1, resetsAt: nil, scope: "Spark"),
        ]
        let snapshot = try UsageSnapshot(
            provider: .codex, preferredWindow: windows[0], additionalWindows: Array(windows.dropFirst()),
            weeklySpend: nil, freshness: .fresh, isActivelyUsed: false, capturedAt: now
        )
        XCTAssertEqual(CodexEdgeLayout.gaugeRows(snapshot).map { $0.map { $0?.id } },
                       [[nil, "10080|"], ["300|Spark", "10080|Spark"]])

        let claudeLike = try UsageSnapshot(
            provider: .claude,
            preferredWindow: UsageWindow(durationMinutes: 300, usedPercent: 1, resetsAt: nil),
            additionalWindows: [
                UsageWindow(durationMinutes: 10_080, usedPercent: 1, resetsAt: nil),
                UsageWindow(durationMinutes: 10_080, usedPercent: 1, resetsAt: nil, scope: "Fable"),
            ],
            weeklySpend: nil, freshness: .fresh, isActivelyUsed: false, capturedAt: now
        )
        XCTAssertEqual(CodexEdgeLayout.gaugeRows(claudeLike).count, 1, "three limits fit in one row")
    }

    func testResetLabelsCoverEveryRange() throws {
        let preferences = try makePreferences(.english)
        XCTAssertEqual(CodexEdgeText.resetLabel(nil, now: now, preferences: preferences), "Reset unavailable")
        XCTAssertEqual(CodexEdgeText.resetLabel(now, now: now, preferences: preferences), "Reset pending")
        XCTAssertEqual(
            CodexEdgeText.resetLabel(now.addingTimeInterval(-60), now: now, preferences: preferences),
            "Reset pending"
        )
        XCTAssertEqual(
            CodexEdgeText.resetLabel(now.addingTimeInterval(59 * 60), now: now, preferences: preferences),
            "Resets in 59 min"
        )
        XCTAssertEqual(
            CodexEdgeText.resetLabel(now.addingTimeInterval(61 * 60), now: now, preferences: preferences),
            "Resets in 1h 1m"
        )
    }

    func testWeeklyResetIncludesDayOfMonth() throws {
        let preferences = try makePreferences(.english)
        let reset = now.addingTimeInterval(7 * 86_400 - 3_600)
        let day = Calendar.current.component(.day, from: reset)
        let label = CodexEdgeText.resetLabel(reset, now: now, preferences: preferences)
        XCTAssertTrue(label.hasPrefix("Resets "))
        XCTAssertTrue(label.contains(String(day)), label)
    }

    func testDatesFollowTheDisplayedLanguage() throws {
        let preferences = try makePreferences(.spanish)
        XCTAssertEqual(preferences.locale.language.languageCode?.identifier, "es")
        preferences.language = .english
        XCTAssertEqual(preferences.locale.language.languageCode?.identifier, "en")
    }

    func testWindowReportsResetOnceItsResetTimePasses() throws {
        let window = try UsageWindow(durationMinutes: 300, usedPercent: 80, resetsAt: now)
        XCTAssertFalse(window.hasReset(at: now.addingTimeInterval(-1)))
        XCTAssertTrue(window.hasReset(at: now))
        let unknown = try UsageWindow(durationMinutes: 300, usedPercent: 80, resetsAt: nil)
        XCTAssertFalse(unknown.hasReset(at: now))
    }

    private func makePreferences(_ language: AppLanguage) throws -> AppPreferences {
        let suite = "UsageIsland.text.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.language = language
        return preferences
    }
}
