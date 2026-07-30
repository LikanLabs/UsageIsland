import Foundation

public struct DemoUsageProvider: UsageProvider {
    public let id: ProviderID

    private let scenario: DemoScenario
    private let clock: any UsageClock

    public init(id: ProviderID, scenario: DemoScenario, clock: any UsageClock) {
        self.id = id
        self.scenario = scenario
        self.clock = clock
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        snapshot(at: clock.now())
    }

    public func snapshot(at now: Date? = nil) -> UsageSnapshot {
        Self.snapshot(for: id, scenario: scenario, capturedAt: now ?? clock.now())
    }

    public static func providerAdapters(
        for scenario: DemoScenario,
        clock: any UsageClock
    ) -> [any UsageProvider] {
        ProviderID.allCases.map {
            DemoUsageProvider(id: $0, scenario: scenario, clock: clock)
        }
    }

    public static func snapshots(
        for scenario: DemoScenario,
        clock: any UsageClock
    ) -> [UsageSnapshot] {
        let now = clock.now()
        return ProviderID.allCases.map {
            snapshot(for: $0, scenario: scenario, capturedAt: now)
        }
    }

    private static func snapshot(
        for provider: ProviderID,
        scenario: DemoScenario,
        capturedAt now: Date
    ) -> UsageSnapshot {
        let fixture = fixture(for: provider, scenario: scenario)
        return UsageSnapshot(
            provider: provider,
            shortWindow: UsageWindow(
                remainingPercent: fixture.shortWindowRemaining,
                resetsAt: now.addingTimeInterval(fixture.resetOffset)
            ),
            weeklyUsedPercent: 100 - fixture.weeklyRemaining,
            weeklySpend: fixture.weeklySpend,
            freshness: fixture.freshness,
            isActivelyUsed: fixture.isActivelyUsed,
            capturedAt: now
        )
    }

    private static func fixture(
        for provider: ProviderID,
        scenario: DemoScenario
    ) -> Fixture {
        switch (scenario, provider) {
        case (.normal, .claude):
            Fixture(
                shortWindowRemaining: 72,
                resetOffset: 3.3 * 3_600,
                weeklyRemaining: 43,
                weeklySpend: 8.42,
                freshness: .fresh,
                isActivelyUsed: true
            )
        case (.normal, .codex):
            Fixture(
                shortWindowRemaining: 48,
                resetOffset: 2.1 * 3_600,
                weeklyRemaining: 61,
                weeklySpend: 6.20,
                freshness: .fresh,
                isActivelyUsed: true
            )
        case (.normal, .openCodeGo):
            Fixture(
                shortWindowRemaining: 91,
                resetOffset: 4.6 * 3_600,
                weeklyRemaining: 88,
                weeklySpend: 3.98,
                freshness: .fresh,
                isActivelyUsed: false
            )

        case (.critical, .claude):
            Fixture(
                shortWindowRemaining: 8,
                resetOffset: 42 * 60,
                weeklyRemaining: 29,
                weeklySpend: 16.12,
                freshness: .fresh,
                isActivelyUsed: true
            )
        case (.critical, .codex):
            Fixture(
                shortWindowRemaining: 64,
                resetOffset: 3.8 * 3_600,
                weeklyRemaining: 70,
                weeklySpend: 4.80,
                freshness: .fresh,
                isActivelyUsed: false
            )
        case (.critical, .openCodeGo):
            Fixture(
                shortWindowRemaining: 87,
                resetOffset: 4.1 * 3_600,
                weeklyRemaining: 81,
                weeklySpend: 4.10,
                freshness: .fresh,
                isActivelyUsed: false
            )

        case (.waiting, .claude):
            Fixture(
                shortWindowRemaining: 68,
                resetOffset: 3 * 3_600,
                weeklyRemaining: 44,
                weeklySpend: 8.90,
                freshness: .fresh,
                isActivelyUsed: false
            )
        case (.waiting, .codex):
            Fixture(
                shortWindowRemaining: 41,
                resetOffset: 1.8 * 3_600,
                weeklyRemaining: 59,
                weeklySpend: 7.10,
                freshness: .fresh,
                isActivelyUsed: true
            )
        case (.waiting, .openCodeGo):
            Fixture(
                shortWindowRemaining: 90,
                resetOffset: 4.5 * 3_600,
                weeklyRemaining: 86,
                weeklySpend: 3.98,
                freshness: .fresh,
                isActivelyUsed: false
            )

        case (.error, .claude):
            Fixture(
                shortWindowRemaining: 70,
                resetOffset: 3.2 * 3_600,
                weeklyRemaining: 42,
                weeklySpend: 9.10,
                freshness: .stale,
                isActivelyUsed: false
            )
        case (.error, .codex):
            Fixture(
                shortWindowRemaining: 48,
                resetOffset: 2.1 * 3_600,
                weeklyRemaining: 61,
                weeklySpend: 6.20,
                freshness: .fresh,
                isActivelyUsed: false
            )
        case (.error, .openCodeGo):
            Fixture(
                shortWindowRemaining: 91,
                resetOffset: 4.6 * 3_600,
                weeklyRemaining: 88,
                weeklySpend: 3.98,
                freshness: .unavailable,
                isActivelyUsed: false
            )
        }
    }
}

private extension DemoUsageProvider {
    struct Fixture: Sendable {
        let shortWindowRemaining: Int
        let resetOffset: TimeInterval
        let weeklyRemaining: Int
        let weeklySpend: Decimal
        let freshness: DataFreshness
        let isActivelyUsed: Bool

    }
}
