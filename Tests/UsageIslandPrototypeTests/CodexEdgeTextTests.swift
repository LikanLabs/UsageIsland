import Foundation
import XCTest
@testable import UsageIslandPrototype

@MainActor
final class CodexEdgeTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testWindowTitlesNameCommonDurations() throws {
        let preferences = try makePreferences(.english)
        XCTAssertEqual(CodexEdgeText.windowTitle(300, preferences: preferences), "Session")
        XCTAssertEqual(CodexEdgeText.windowTitle(10_080, preferences: preferences), "This week")
        XCTAssertEqual(CodexEdgeText.windowTitle(1_440, preferences: preferences), "1 day")
        XCTAssertEqual(CodexEdgeText.windowTitle(4_320, preferences: preferences), "3 days")
        XCTAssertEqual(CodexEdgeText.windowTitle(120, preferences: preferences), "2 h")
        XCTAssertEqual(CodexEdgeText.windowTitle(45, preferences: preferences), "45 min")
        preferences.language = .spanish
        XCTAssertEqual(CodexEdgeText.windowTitle(4_320, preferences: preferences), "3 días")
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
