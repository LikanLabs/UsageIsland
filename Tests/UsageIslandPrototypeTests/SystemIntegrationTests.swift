import Foundation
import XCTest
@testable import UsageIslandPrototype

private let start = Date(timeIntervalSince1970: 1_700_000_000)

private func snapshot(
    _ provider: ProviderID = .claude,
    used: Int,
    resetsAt: Date? = start.addingTimeInterval(3_600),
    freshness: DataFreshness = .fresh
) throws -> UsageSnapshot {
    try UsageSnapshot(
        provider: provider,
        preferredWindow: UsageWindow(durationMinutes: 300, usedPercent: used, resetsAt: resetsAt),
        additionalWindows: [],
        weeklySpend: nil,
        freshness: freshness,
        isActivelyUsed: false,
        capturedAt: start
    )
}

final class UsageAlertPolicyTests: XCTestCase {
    func testFirstReadingIsQuietEvenWhenAlreadyLow() throws {
        var policy = UsageAlertPolicy()
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 95)]), [])
    }

    func testEachThresholdAlertsOnceAsQuotaRunsDown() throws {
        var policy = UsageAlertPolicy()
        _ = policy.alerts(for: [try snapshot(used: 50)])
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 79)]).map(\.kind), [])
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 81)]).map(\.kind), [.level(.low)])
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 85)]).map(\.kind), [], "no repeat within a level")
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 92)]).map(\.kind), [.level(.critical)])
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 100)]).map(\.kind), [.level(.exhausted)])
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 100)]).map(\.kind), [])
    }

    func testJumpingPastSeveralThresholdsSendsOnlyTheWorst() throws {
        var policy = UsageAlertPolicy()
        _ = policy.alerts(for: [try snapshot(used: 10)])
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 95)]).map(\.kind), [.level(.critical)])
    }

    func testResetAlertsOnlyWhenTheWindowHadRunLow() throws {
        var policy = UsageAlertPolicy()
        _ = policy.alerts(for: [try snapshot(used: 40)])
        let nextPeriod = start.addingTimeInterval(3_600 + 5 * 3_600)
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 2, resetsAt: nextPeriod)]).map(\.kind), [],
                       "a routine reset is not news")

        _ = policy.alerts(for: [try snapshot(used: 97, resetsAt: nextPeriod)])
        let later = nextPeriod.addingTimeInterval(5 * 3_600)
        let alerts = policy.alerts(for: [try snapshot(used: 0, resetsAt: later)])
        XCTAssertEqual(alerts.map(\.kind), [.reset])
        XCTAssertEqual(alerts.first?.window.remainingPercent, 100)
    }

    func testResetTimeJitterIsNotANewPeriod() throws {
        var policy = UsageAlertPolicy()
        _ = policy.alerts(for: [try snapshot(used: 85)])
        let jittered = start.addingTimeInterval(3_600.4)
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 91, resetsAt: jittered)]).map(\.kind), [.level(.critical)])
    }

    func testWithoutResetTimesALargeDropCountsAsReset() throws {
        var policy = UsageAlertPolicy()
        _ = policy.alerts(for: [try snapshot(used: 90, resetsAt: nil)])
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 5, resetsAt: nil)]).map(\.kind), [.reset])
    }

    func testStaleReadingsNeverAlertOrMoveTheBaseline() throws {
        var policy = UsageAlertPolicy()
        _ = policy.alerts(for: [try snapshot(used: 50)])
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 99, freshness: .stale)]), [])
        XCTAssertEqual(policy.alerts(for: [try snapshot(used: 85)]).map(\.kind), [.level(.low)])
    }

    func testWindowsAreTrackedPerProvider() throws {
        var policy = UsageAlertPolicy()
        _ = policy.alerts(for: [try snapshot(.codex, used: 50), try snapshot(.claude, used: 50)])
        let alerts = policy.alerts(for: [try snapshot(.codex, used: 50), try snapshot(.claude, used: 90)])
        XCTAssertEqual(alerts.map(\.provider), [.claude])
        XCTAssertEqual(alerts.first?.identifier, "usage.claude.300|")
    }
}

@MainActor
final class UsageAlertMonitorTests: XCTestCase {
    func testPostsOnlyWhileAlertsAreEnabled() async throws {
        let notifier = RecordingNotifier()
        let preferences = try makePreferences()
        preferences.language = .spanish
        let model = AppModel.empty(clock: FixedAlertClock(start))
        let monitor = UsageAlertMonitor(model: model, preferences: preferences, notifier: notifier, clock: FixedAlertClock(start))

        monitor.evaluate([try snapshot(used: 50)])
        monitor.evaluate([try snapshot(used: 90)])
        try await notifier.waitForPosts(1)
        let posts = await notifier.posts
        XCTAssertEqual(posts.first?.id, "usage.claude.300|")
        XCTAssertEqual(posts.first?.title, "Claude · Sesión")
        XCTAssertEqual(posts.first?.body, "Te queda 10 %. Reinicia en 1h 0m.")

        preferences.usageAlerts = false
        monitor.evaluate([try snapshot(used: 100)])
        try await Task.sleep(for: .milliseconds(50))
        let count = await notifier.posts.count
        XCTAssertEqual(count, 1)
    }

    func testMessagesCoverExhaustionAndReset() throws {
        let preferences = try makePreferences()
        preferences.language = .english
        let window = try UsageWindow(durationMinutes: 10_080, usedPercent: 100, resetsAt: start.addingTimeInterval(1_800))
        let exhausted = UsageAlertMonitor.message(
            for: UsageAlert(provider: .codex, window: window, kind: .level(.exhausted)), now: start, preferences: preferences)
        XCTAssertEqual(exhausted.title, "Codex · Week")
        XCTAssertEqual(exhausted.body, "Limit reached. Resets in 30 min.")

        let fresh = try UsageWindow(durationMinutes: 300, usedPercent: 0, resetsAt: start.addingTimeInterval(18_000))
        let reset = UsageAlertMonitor.message(
            for: UsageAlert(provider: .claude, window: fresh, kind: .reset), now: start, preferences: preferences)
        XCTAssertEqual(reset.body, "Reset: 100% available again.")
    }

    private func makePreferences() throws -> AppPreferences {
        let suite = "UsageIsland.alerts.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppPreferences(defaults: defaults)
    }
}

@MainActor
final class PillCountdownTests: XCTestCase {
    func testCountdownFormats() {
        XCTAssertEqual(CodexEdgeText.countdown(until: start.addingTimeInterval(45 * 60), now: start), "45 min")
        XCTAssertEqual(CodexEdgeText.countdown(until: start.addingTimeInterval(80 * 60), now: start), "1h 20m")
        XCTAssertEqual(CodexEdgeText.countdown(until: start.addingTimeInterval(52 * 3_600), now: start), "2d 4h")
        XCTAssertEqual(CodexEdgeText.countdown(until: start.addingTimeInterval(10), now: start), "1 min")
    }
}

final class AppUpdateRelaunchTests: XCTestCase {
    func testReadsVersionFromBundleOnDisk() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("uip-\(UUID())/Test.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        XCTAssertNil(BundleVersion.onDisk(at: bundle), "a half-copied bundle has no version yet")

        let info: NSDictionary = ["CFBundleShortVersionString": "0.1.7", "CFBundleVersion": "0.1.7"]
        info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        XCTAssertEqual(BundleVersion.onDisk(at: bundle), BundleVersion(short: "0.1.7", build: "0.1.7"))
        XCTAssertNil(BundleVersion.onDisk(at: bundle.deletingLastPathComponent()), "not an app bundle")
    }

    func testRelaunchesOnlyForANewCompleteVersionWithThePanelClosed() {
        let old = BundleVersion(short: "0.1.6", build: "0.1.6")
        let new = BundleVersion(short: "0.1.7", build: "0.1.7")
        XCTAssertTrue(AppUpdateRelaunch.shouldRelaunch(running: old, onDisk: new, panelOpen: false))
        XCTAssertFalse(AppUpdateRelaunch.shouldRelaunch(running: old, onDisk: new, panelOpen: true))
        XCTAssertFalse(AppUpdateRelaunch.shouldRelaunch(running: old, onDisk: old, panelOpen: false))
        XCTAssertFalse(AppUpdateRelaunch.shouldRelaunch(running: old, onDisk: nil, panelOpen: false))
        XCTAssertFalse(AppUpdateRelaunch.shouldRelaunch(running: nil, onDisk: new, panelOpen: false))
    }
}

final class ClaudeQueryEnvironmentTests: XCTestCase {
    func testClaudeQueriesSkipUpdatesAndTelemetryButMayFetchLimits() {
        let environment = ClaudeUsageCommand.environment(from: [
            "PATH": "/usr/bin", "HOME": "/Users/example",
            // Even if the user's environment sets it, it must not reach the
            // query: it stops Claude Code from fetching expired limits.
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        ])
        XCTAssertNil(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        XCTAssertEqual(environment["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(environment["DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(environment["DISABLE_ERROR_REPORTING"], "1")
        XCTAssertEqual(environment["HOME"], "/Users/example")
    }
}

@MainActor
final class RefreshPowerTests: XCTestCase {
    func testLowPowerModeStretchesTheInterval() throws {
        let model = AppModel.empty(clock: FixedAlertClock(start))
        var lowPower = false
        let controller = UsageRefreshController(model: model, interval: .seconds(60), isLowPowerMode: { lowPower })
        XCTAssertEqual(controller.currentInterval, .seconds(60))
        lowPower = true
        XCTAssertEqual(controller.currentInterval, .seconds(180))
    }

    private func eventually(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not reached")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor FetchCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct CountingProvider: UsageProvider {
    let id: ProviderID = .codex
    let counter: FetchCounter
    func fetchUsage() async throws -> UsageSnapshot {
        await counter.increment()
        return try snapshot(.codex, used: 10)
    }
}

private actor RecordingNotifier: UsageNotifying {
    private(set) var posts: [(id: String, title: String, body: String)] = []
    func requestAuthorization() async -> Bool { true }
    func isDenied() async -> Bool { false }
    func post(id: String, title: String, body: String) async { posts.append((id, title, body)) }

    func waitForPosts(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while posts.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct FixedAlertClock: UsageClock {
    let value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { value }
}

@MainActor
final class ProviderVisibilityTests: XCTestCase {
    func testOnlyInstalledProvidersGetCardsAndThePill() async throws {
        let model = try AppModel(
            providerAdapters: [FailingProvider(id: .codex, error: CodexUsageError.appServerFailure(.executableUnavailable)),
                               WorkingProvider(id: .claude)],
            clock: FixedAlertClock(start), initialSnapshots: []
        )
        XCTAssertEqual(model.visibleProviderIDs, [.codex, .claude], "before the first refresh nothing is hidden")

        await model.refreshUsage()
        XCTAssertEqual(model.issues[.codex], .notInstalled)
        XCTAssertEqual(model.visibleProviderIDs, [.claude], "a Claude-only user sees only Claude")
        XCTAssertEqual(model.pillProviderID, .claude)
    }

    func testSignedOutOrNoPlanProvidersStayVisibleWithTheirReason() async throws {
        let model = try AppModel(
            providerAdapters: [FailingProvider(id: .codex, error: CodexUsageError.notAuthenticated),
                               FailingProvider(id: .claude, error: ClaudeUsageError.noPlanLimits)],
            clock: FixedAlertClock(start), initialSnapshots: []
        )
        await model.refreshUsage()
        XCTAssertEqual(model.visibleProviderIDs, [.codex, .claude])
        XCTAssertNil(model.displayedProviderID)
        XCTAssertEqual(model.pillProviderID, .codex, "the pill still names a provider")
    }

    func testNothingInstalledLeavesNoCards() async throws {
        let model = try AppModel(
            providerAdapters: [FailingProvider(id: .codex, error: CodexUsageError.appServerFailure(.executableUnavailable)),
                               FailingProvider(id: .claude, error: ClaudeUsageError.cliNotFound)],
            clock: FixedAlertClock(start), initialSnapshots: []
        )
        await model.refreshUsage()
        XCTAssertEqual(model.visibleProviderIDs, [])
        XCTAssertNil(model.pillProviderID)
        XCTAssertEqual(CodexEdgeLayout.panelHeight(settings: false, model: model),
                       CodexEdgeLayout.panelPadding * 2 + CodexEdgeLayout.headerHeight + 14
                       + CodexEdgeLayout.welcomeCardHeight + CodexEdgeLayout.footerHeight)
    }
}

private struct FailingProvider: UsageProvider {
    let id: ProviderID
    let error: any Error & Sendable
    func fetchUsage() async throws -> UsageSnapshot { throw error }
}

private struct WorkingProvider: UsageProvider {
    let id: ProviderID
    func fetchUsage() async throws -> UsageSnapshot { try snapshot(id, used: 20) }
}
