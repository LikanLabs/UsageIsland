import Foundation
import XCTest

@testable import UsageIslandPrototype

final class DemoUsageProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEveryScenarioMatchesV26VisibleValuesAndResetOffsets() {
        for expectation in Self.expectations {
            let clock = FixedUsageClock(now)
            let snapshots = DemoUsageProvider.snapshots(
                for: expectation.scenario,
                clock: clock
            )

            XCTAssertEqual(snapshots.count, 3, expectation.scenario.rawValue)
            for providerExpectation in expectation.providers {
                let snapshot = snapshots.first { $0.id == providerExpectation.id }
                XCTAssertNotNil(snapshot)
                XCTAssertEqual(
                    snapshot?.shortWindow.remainingPercent,
                    providerExpectation.shortRemaining
                )
                XCTAssertEqual(
                    snapshot?.shortWindow.usedPercent,
                    100 - providerExpectation.shortRemaining
                )
                XCTAssertEqual(
                    snapshot?.shortWindow.resetsAt,
                    now.addingTimeInterval(providerExpectation.resetOffset)
                )
                XCTAssertEqual(
                    snapshot?.weeklyRemainingPercent,
                    providerExpectation.weeklyRemaining
                )
                XCTAssertEqual(snapshot?.weeklySpend, providerExpectation.weeklySpend)
                XCTAssertEqual(snapshot?.freshness, providerExpectation.freshness)
                XCTAssertEqual(
                    snapshot?.isCurrentlyActive,
                    providerExpectation.isActive
                )
                XCTAssertEqual(snapshot?.capturedAt, now)
            }
        }
    }

    func testAsyncProviderUsesInjectedClock() async throws {
        let provider = DemoUsageProvider(
            id: .codex,
            scenario: .normal,
            clock: FixedUsageClock(now)
        )

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.id, .codex)
        XCTAssertEqual(snapshot.capturedAt, now)
        XCTAssertEqual(snapshot.shortWindow.resetsAt, now.addingTimeInterval(2.1 * 3_600))
    }
}

private extension DemoUsageProviderTests {
    struct ScenarioExpectation {
        let scenario: DemoScenario
        let providers: [ProviderExpectation]
    }

    struct ProviderExpectation {
        let id: ProviderID
        let shortRemaining: Int
        let resetOffset: TimeInterval
        let weeklyRemaining: Int
        let weeklySpend: Decimal
        let freshness: DataFreshness
        let isActive: Bool
    }

    static let expectations: [ScenarioExpectation] = [
        ScenarioExpectation(
            scenario: .normal,
            providers: [
                ProviderExpectation(
                    id: .claude,
                    shortRemaining: 72,
                    resetOffset: 3.3 * 3_600,
                    weeklyRemaining: 43,
                    weeklySpend: 8.42,
                    freshness: .fresh,
                    isActive: true
                ),
                ProviderExpectation(
                    id: .codex,
                    shortRemaining: 48,
                    resetOffset: 2.1 * 3_600,
                    weeklyRemaining: 61,
                    weeklySpend: 6.20,
                    freshness: .fresh,
                    isActive: true
                ),
                ProviderExpectation(
                    id: .openCodeGo,
                    shortRemaining: 91,
                    resetOffset: 4.6 * 3_600,
                    weeklyRemaining: 88,
                    weeklySpend: 3.98,
                    freshness: .fresh,
                    isActive: false
                )
            ]
        ),
        ScenarioExpectation(
            scenario: .critical,
            providers: [
                ProviderExpectation(
                    id: .claude,
                    shortRemaining: 8,
                    resetOffset: 42 * 60,
                    weeklyRemaining: 29,
                    weeklySpend: 16.12,
                    freshness: .fresh,
                    isActive: true
                ),
                ProviderExpectation(
                    id: .codex,
                    shortRemaining: 64,
                    resetOffset: 3.8 * 3_600,
                    weeklyRemaining: 70,
                    weeklySpend: 4.80,
                    freshness: .fresh,
                    isActive: false
                ),
                ProviderExpectation(
                    id: .openCodeGo,
                    shortRemaining: 87,
                    resetOffset: 4.1 * 3_600,
                    weeklyRemaining: 81,
                    weeklySpend: 4.10,
                    freshness: .fresh,
                    isActive: false
                )
            ]
        ),
        ScenarioExpectation(
            scenario: .waiting,
            providers: [
                ProviderExpectation(
                    id: .claude,
                    shortRemaining: 68,
                    resetOffset: 3 * 3_600,
                    weeklyRemaining: 44,
                    weeklySpend: 8.90,
                    freshness: .fresh,
                    isActive: false
                ),
                ProviderExpectation(
                    id: .codex,
                    shortRemaining: 41,
                    resetOffset: 1.8 * 3_600,
                    weeklyRemaining: 59,
                    weeklySpend: 7.10,
                    freshness: .fresh,
                    isActive: true
                ),
                ProviderExpectation(
                    id: .openCodeGo,
                    shortRemaining: 90,
                    resetOffset: 4.5 * 3_600,
                    weeklyRemaining: 86,
                    weeklySpend: 3.98,
                    freshness: .fresh,
                    isActive: false
                )
            ]
        ),
        ScenarioExpectation(
            scenario: .error,
            providers: [
                ProviderExpectation(
                    id: .claude,
                    shortRemaining: 70,
                    resetOffset: 3.2 * 3_600,
                    weeklyRemaining: 42,
                    weeklySpend: 9.10,
                    freshness: .stale,
                    isActive: false
                ),
                ProviderExpectation(
                    id: .codex,
                    shortRemaining: 48,
                    resetOffset: 2.1 * 3_600,
                    weeklyRemaining: 61,
                    weeklySpend: 6.20,
                    freshness: .fresh,
                    isActive: false
                ),
                ProviderExpectation(
                    id: .openCodeGo,
                    shortRemaining: 91,
                    resetOffset: 4.6 * 3_600,
                    weeklyRemaining: 88,
                    weeklySpend: 3.98,
                    freshness: .unavailable,
                    isActive: false
                )
            ]
        )
    ]
}

private struct FixedUsageClock: UsageClock {
    let date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        date
    }
}
