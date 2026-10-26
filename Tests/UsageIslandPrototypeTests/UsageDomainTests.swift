import Foundation
import XCTest

@testable import UsageIslandPrototype

final class UsageDomainTests: XCTestCase {
    private let resetDate = Date(timeIntervalSince1970: 12_345)

    func testWindowPreservesDurationResetAndCanonicalPercentages() throws {
        let belowRange = try UsageWindow(
            durationMinutes: 15,
            usedPercent: -1,
            resetsAt: resetDate
        )
        let aboveRange = try UsageWindow(
            durationMinutes: 300,
            usedPercent: 101,
            resetsAt: nil
        )
        let remaining = try UsageWindow(
            durationMinutes: 10_080,
            remainingPercent: 72,
            resetsAt: resetDate
        )

        XCTAssertEqual(belowRange.durationMinutes, 15)
        XCTAssertEqual(belowRange.usedPercent, 0)
        XCTAssertEqual(belowRange.remainingPercent, 100)
        XCTAssertEqual(belowRange.resetsAt, resetDate)
        XCTAssertEqual(aboveRange.usedPercent, 100)
        XCTAssertEqual(aboveRange.remainingPercent, 0)
        XCTAssertNil(aboveRange.resetsAt)
        XCTAssertEqual(remaining.usedPercent, 28)
        XCTAssertEqual(remaining.remainingPercent, 72)
    }

    func testZeroAndNegativeDurationsReturnTypedErrors() {
        for duration in [0, -1] {
            XCTAssertThrowsError(
                try UsageWindow(
                    durationMinutes: duration,
                    usedPercent: 20,
                    resetsAt: nil
                )
            ) {
                XCTAssertEqual(
                    $0 as? UsageDomainError,
                    .invalidWindowDuration(duration)
                )
            }
        }
    }

    func testPreferredWindowIsRequiredAndAdditionalWindowsAreOptional() throws {
        let preferred = try window(duration: 15, used: 30)
        let snapshot = try makeSnapshot(preferred: preferred)

        XCTAssertEqual(snapshot.preferredWindow, preferred)
        XCTAssertTrue(snapshot.additionalWindows.isEmpty)
        XCTAssertEqual(snapshot.windows, [preferred])
    }

    func testWindowsContainsPreferredThenAdditionalWindows() throws {
        let preferred = try window(duration: 300, used: 20)
        let weekly = try window(duration: 10_080, used: 40)
        let future = try window(duration: 15, used: 60)
        let snapshot = try makeSnapshot(
            preferred: preferred,
            additional: [weekly, future]
        )

        XCTAssertEqual(snapshot.windows, [preferred, weekly, future])
    }

    func testDuplicateDurationsReturnTypedErrorWithoutSnapshot() throws {
        let preferred = try window(duration: 300, used: 20)
        let duplicate = try window(duration: 300, used: 40)

        XCTAssertThrowsError(
            try makeSnapshot(preferred: preferred, additional: [duplicate])
        ) {
            XCTAssertEqual(
                $0 as? UsageDomainError,
                .duplicateWindowDuration(300)
            )
        }
    }

    func testShortAndWeeklyAccessorsAreDerivedByDuration() throws {
        let weekly = try window(duration: 10_080, used: 40)
        let short = try window(duration: 300, used: 20)
        let snapshot = try makeSnapshot(
            preferred: weekly,
            additional: [short]
        )

        XCTAssertEqual(snapshot.shortWindow, short)
        XCTAssertEqual(snapshot.weeklyWindow, weekly)
    }

    func testWeeklyOnlySnapshotHasNoShortWindow() throws {
        let weekly = try window(duration: 10_080, used: 48)
        let snapshot = try makeSnapshot(preferred: weekly)

        XCTAssertNil(snapshot.shortWindow)
        XCTAssertEqual(snapshot.weeklyWindow, weekly)
        XCTAssertEqual(snapshot.weeklyUsedPercent, 48)
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 52)
    }

    func testShortOnlySnapshotHasNoWeeklyWindow() throws {
        let short = try window(duration: 300, used: 25)
        let snapshot = try makeSnapshot(preferred: short)

        XCTAssertEqual(snapshot.shortWindow, short)
        XCTAssertNil(snapshot.weeklyWindow)
        XCTAssertNil(snapshot.weeklyUsedPercent)
        XCTAssertNil(snapshot.weeklyRemainingPercent)
    }

    func testWeeklyPercentagesUseCanonicalWindowClamp() throws {
        let belowRange = try makeSnapshot(
            preferred: window(duration: 10_080, used: -20)
        )
        let aboveRange = try makeSnapshot(
            preferred: window(duration: 10_080, used: 120)
        )

        XCTAssertEqual(belowRange.weeklyUsedPercent, 0)
        XCTAssertEqual(belowRange.weeklyRemainingPercent, 100)
        XCTAssertEqual(aboveRange.weeklyUsedPercent, 100)
        XCTAssertEqual(aboveRange.weeklyRemainingPercent, 0)
    }

    func testPriorityScoreUsesPreferredWindowInsteadOfShortAccessor() throws {
        let preferredWeekly = try window(duration: 10_080, used: 90)
        let nonCriticalShort = try window(duration: 300, used: 0)
        let snapshot = try makeSnapshot(
            preferred: preferredWeekly,
            additional: [nonCriticalShort]
        )

        XCTAssertEqual(snapshot.priorityScore, 1_090)
    }

    func testPillShowsTheSessionUnlessTheWeekIsNearlyUsedUp() throws {
        let later = resetDate.addingTimeInterval(86_400)
        // Less left in the week alone does not take over: the budgets differ in size.
        var snapshot = try makeSnapshot(preferred: window(duration: 300, used: 60, reset: later),
                                        additional: [window(duration: 10_080, used: 70, reset: later)])
        XCTAssertEqual(snapshot.pillWindow(at: resetDate).durationMinutes, 300)

        // The week used up with a fresh session: the week is what stops work.
        snapshot = try makeSnapshot(preferred: window(duration: 300, used: 0, reset: later),
                                    additional: [window(duration: 10_080, used: 100, reset: later)])
        XCTAssertEqual(snapshot.pillWindow(at: resetDate).durationMinutes, 10_080)

        // 10 % left takes over too, unless the session has even less left.
        snapshot = try makeSnapshot(preferred: window(duration: 300, used: 20, reset: later),
                                    additional: [window(duration: 10_080, used: 90, reset: later)])
        XCTAssertEqual(snapshot.pillWindow(at: resetDate).durationMinutes, 10_080)
        snapshot = try makeSnapshot(preferred: window(duration: 300, used: 95, reset: later),
                                    additional: [window(duration: 10_080, used: 90, reset: later)])
        XCTAssertEqual(snapshot.pillWindow(at: resetDate).durationMinutes, 300)
        snapshot = try makeSnapshot(preferred: window(duration: 300, used: 0, reset: later),
                                    additional: [window(duration: 10_080, used: 89, reset: later)])
        XCTAssertEqual(snapshot.pillWindow(at: resetDate).durationMinutes, 300, "11 % left is not nearly used up")
    }

    func testPerModelAndPastLimitsNeverTakeOverThePill() throws {
        let later = resetDate.addingTimeInterval(86_400)
        let fable = try UsageWindow(durationMinutes: 10_080, usedPercent: 100, resetsAt: later, scope: "Fable")
        var snapshot = try makeSnapshot(preferred: window(duration: 300, used: 10, reset: later), additional: [fable])
        XCTAssertNil(snapshot.pillWindow(at: resetDate).scope)
        XCTAssertEqual(snapshot.pillWindow(at: resetDate).durationMinutes, 300)

        // A weekly reading whose reset time has passed describes last week.
        snapshot = try makeSnapshot(preferred: window(duration: 300, used: 10, reset: later),
                                    additional: [window(duration: 10_080, used: 100, reset: resetDate.addingTimeInterval(-60))])
        XCTAssertEqual(snapshot.pillWindow(at: resetDate).durationMinutes, 300)

        // Plans without a 5-hour limit keep the weekly one.
        snapshot = try makeSnapshot(preferred: window(duration: 10_080, used: 30, reset: later))
        XCTAssertEqual(snapshot.pillWindow(at: resetDate).durationMinutes, 10_080)
    }

    func testCompatibilityIdentityInitializerPreservesCaptureDate() throws {
        let preferred = try window(duration: 300, used: 50)
        let snapshot = try UsageSnapshot(
            id: .codex,
            preferredWindow: preferred,
            additionalWindows: [],
            weeklySpend: nil,
            freshness: .fresh,
            isCurrentlyActive: false,
            capturedAt: resetDate
        )

        XCTAssertEqual(snapshot.id, .codex)
        XCTAssertEqual(snapshot.capturedAt, resetDate)
    }

    private func window(
        duration: Int,
        used: Int,
        reset: Date? = nil
    ) throws -> UsageWindow {
        try UsageWindow(
            durationMinutes: duration,
            usedPercent: used,
            resetsAt: reset
        )
    }

    private func makeSnapshot(
        preferred: UsageWindow,
        additional: [UsageWindow] = []
    ) throws -> UsageSnapshot {
        try UsageSnapshot(
            provider: .codex,
            preferredWindow: preferred,
            additionalWindows: additional,
            weeklySpend: nil,
            freshness: .fresh,
            isActivelyUsed: false,
            capturedAt: resetDate
        )
    }
}
