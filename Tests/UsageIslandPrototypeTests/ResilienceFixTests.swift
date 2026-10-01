import AppKit
import Foundation
import XCTest
@testable import UsageIslandPrototype

private let base = Date(timeIntervalSince1970: 1_700_000_000)

/// Synthetic `get_usage` answers in the CLI's shape.
private func answer(rateLimits: String, available: Bool = true) -> Data {
    Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"usage-island","response":{"rate_limits_available":\#(available),"rate_limits":\#(rateLimits)}}}"#.utf8)
}

private let withLimits = answer(rateLimits: #"{"limits":[{"kind":"session","percent":26,"resets_at":"2023-11-14T23:13:20+00:00"}]}"#)
private let withoutLimits = answer(rateLimits: "null")

final class ClaudeTemporaryFailureTests: XCTestCase {
    func testEmptyAnswerIsTemporaryNotNoPlan() throws {
        XCTAssertThrowsError(try ClaudeUsageResponseParser.limits(from: withoutLimits)) {
            XCTAssertEqual($0 as? ClaudeUsageResponseParser.Failure, .temporarilyUnavailable)
        }
        XCTAssertThrowsError(try ClaudeUsageResponseParser.limits(from: answer(rateLimits: "null", available: false))) {
            XCTAssertEqual($0 as? ClaudeUsageResponseParser.Failure, .limitsUnavailable)
        }
        XCTAssertEqual(ClaudeUsageError.temporarilyUnavailable.issue, .unavailable)
    }

    func testFailuresBackOffAndASuccessResetsTheInterval() async throws {
        let clock = MovableClock(base)
        let query = QueuedQuery([withoutLimits, withoutLimits, withLimits, withLimits])
        let provider = ClaudeUsageProvider(clock: clock, queryInterval: 300, maximumBackoff: 3_600, makeQuery: { query })

        _ = try? await provider.fetchUsage()                      // fails: next wait 10 min
        var wait = await provider.currentWait
        XCTAssertEqual(wait, 600)
        clock.advance(599)
        _ = try? await provider.fetchUsage()
        var calls = await query.calls
        XCTAssertEqual(calls, 1, "still backing off")

        clock.advance(1)
        _ = try? await provider.fetchUsage()                      // fails again: 20 min
        wait = await provider.currentWait
        XCTAssertEqual(wait, 1_200)

        clock.advance(1_200)
        let snapshot = try await provider.fetchUsage()            // succeeds
        XCTAssertEqual(snapshot.preferredWindow.usedPercent, 26)
        wait = await provider.currentWait
        XCTAssertEqual(wait, 300)
        calls = await query.calls
        XCTAssertEqual(calls, 3)
    }

    func testBackoffIsCappedAtTheMaximum() async throws {
        let clock = MovableClock(base)
        let query = QueuedQuery(Array(repeating: withoutLimits, count: 12))
        let provider = ClaudeUsageProvider(clock: clock, queryInterval: 300, maximumBackoff: 3_600, makeQuery: { query })
        for _ in 0..<8 {
            _ = try? await provider.fetchUsage()
            clock.advance(await provider.currentWait)
        }
        let wait = await provider.currentWait
        XCTAssertEqual(wait, 3_600)
    }
}

final class CodexExpiredSignInTests: XCTestCase {
    func testRejectedSignInMeansNotSignedIn() async throws {
        let provider = CodexUsageProvider(client: RejectingCodexClient(), clock: MovableClock(base))
        do {
            _ = try await provider.fetchUsage()
            XCTFail("expected a sign-in error")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .notAuthenticated)
            XCTAssertEqual((error as? CodexUsageError)?.issue, .notSignedIn)
        }
        try? await provider.shutdown()
    }
}

@MainActor
final class SelfHealingPauseTests: XCTestCase {
    func testPollsSkipWhileLockedAndResumeWithoutAnyNotification() async throws {
        let counter = Counter()
        let model = try AppModel(providerAdapters: [CountingCodex(counter: counter)], clock: MovableClock(base), initialSnapshots: [])
        let locked = Flag()
        let controller = UsageRefreshController(
            model: model, notifications: NotificationCenter(), distributedNotifications: NotificationCenter(),
            powerNotifications: NotificationCenter(), interval: .milliseconds(20), isLowPowerMode: { false },
            isScreenLocked: { locked.value }, areDisplaysAsleep: { false }
        )
        controller.start()
        defer { controller.stop() }
        try await eventually { await counter.value >= 2 }

        locked.value = true
        XCTAssertTrue(controller.isPaused)
        try await Task.sleep(for: .milliseconds(60))
        let whileLocked = await counter.value
        try await Task.sleep(for: .milliseconds(120))
        let stillLocked = await counter.value
        XCTAssertLessThanOrEqual(stillLocked - whileLocked, 1)

        // The unlock notification is never posted: polling heals by itself.
        locked.value = false
        try await eventually { await counter.value > stillLocked + 1 }
    }

    func testUnlockNotificationRefreshesAtOnce() async throws {
        let counter = Counter()
        let model = try AppModel(providerAdapters: [CountingCodex(counter: counter)], clock: MovableClock(base), initialSnapshots: [])
        let distributed = NotificationCenter()
        let controller = UsageRefreshController(
            model: model, notifications: NotificationCenter(), distributedNotifications: distributed,
            powerNotifications: NotificationCenter(), interval: .seconds(3_600), isLowPowerMode: { false },
            isScreenLocked: { false }, areDisplaysAsleep: { false }
        )
        controller.start()
        defer { controller.stop() }
        distributed.post(name: UsageRefreshController.screenUnlocked, object: nil)
        try await eventually { await counter.value >= 1 }
    }

    private func eventually(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not reached") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class MovableClock: UsageClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private actor QueuedQuery: ClaudeUsageQuerying {
    private var answers: [Data]
    private(set) var calls = 0
    init(_ answers: [Data]) { self.answers = answers }
    func queryUsage() async throws -> Data {
        calls += 1
        return answers.isEmpty ? withoutLimits : answers.removeFirst()
    }
}

private actor RejectingCodexClient: CodexUsageClient {
    func start() async throws {}
    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        if method == "account/read" {
            return .object(["requiresOpenaiAuth": .bool(true),
                            "account": .object(["type": .string("chatgpt"), "email": .null, "planType": .string("pro")])])
        }
        throw JSONRPCError.remoteAuthenticationRejected
    }
    func notifications() async throws -> AsyncThrowingStream<JSONRPCNotification, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func shutdown() async throws {}
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct CountingCodex: UsageProvider {
    let id: ProviderID = .codex
    let counter: Counter
    func fetchUsage() async throws -> UsageSnapshot {
        await counter.increment()
        return try UsageSnapshot(
            provider: .codex,
            preferredWindow: UsageWindow(durationMinutes: 10_080, usedPercent: 5, resetsAt: nil),
            additionalWindows: [], weeklySpend: nil, freshness: .fresh, isActivelyUsed: false, capturedAt: base
        )
    }
}
