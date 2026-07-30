import Foundation
import XCTest

@testable import UsageIslandPrototype

final class UsageDomainTests: XCTestCase {
    private let resetDate = Date(timeIntervalSince1970: 12_345)

    func testUsedPercentClampsBelowZero() {
        let window = UsageWindow(usedPercent: -1, resetsAt: resetDate)

        XCTAssertEqual(window.usedPercent, 0)
        XCTAssertEqual(window.remainingPercent, 100)
    }

    func testUsedPercentClampsAboveOneHundred() {
        let window = UsageWindow(usedPercent: 101, resetsAt: resetDate)

        XCTAssertEqual(window.usedPercent, 100)
        XCTAssertEqual(window.remainingPercent, 0)
    }

    func testRemainingPercentIsComputedFromUsedPercent() {
        let window = UsageWindow(usedPercent: 37, resetsAt: resetDate)

        XCTAssertEqual(window.remainingPercent, 63)
    }

    func testCompatibilityInitializerStoresUsedPercent() {
        let window = UsageWindow(remainingPercent: 72, resetsAt: resetDate)

        XCTAssertEqual(window.usedPercent, 28)
        XCTAssertEqual(window.remainingPercent, 72)
    }

    func testResetDateRemainsAbsolute() {
        let window = UsageWindow(usedPercent: 20, resetsAt: resetDate)

        XCTAssertEqual(window.resetsAt, resetDate)
    }

    func testWeeklyRemainingIsComputedFromClampedUsedPercent() {
        let belowRange = snapshot(weeklyUsedPercent: -20)
        let aboveRange = snapshot(weeklyUsedPercent: 120)

        XCTAssertEqual(belowRange.weeklyUsedPercent, 0)
        XCTAssertEqual(belowRange.weeklyRemainingPercent, 100)
        XCTAssertEqual(aboveRange.weeklyUsedPercent, 100)
        XCTAssertEqual(aboveRange.weeklyRemainingPercent, 0)
    }

    func testCompatibilitySnapshotPreservesExplicitCaptureDate() {
        let snapshot = UsageSnapshot(
            id: .codex,
            shortWindow: UsageWindow(usedPercent: 50, resetsAt: resetDate),
            weeklyRemainingPercent: 50,
            weeklySpend: nil,
            freshness: .fresh,
            isCurrentlyActive: false,
            capturedAt: resetDate
        )

        XCTAssertEqual(snapshot.capturedAt, resetDate)
    }

    private func snapshot(weeklyUsedPercent: Int) -> UsageSnapshot {
        UsageSnapshot(
            provider: .codex,
            shortWindow: UsageWindow(usedPercent: 50, resetsAt: resetDate),
            weeklyUsedPercent: weeklyUsedPercent,
            weeklySpend: nil,
            freshness: .fresh,
            isActivelyUsed: false,
            capturedAt: resetDate
        )
    }
}
