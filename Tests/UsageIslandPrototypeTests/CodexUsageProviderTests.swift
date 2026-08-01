import Foundation
import XCTest

@testable import UsageIslandPrototype

final class CodexUsageProviderTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 9_999)

    func testStartsOnceAndRequestsAccountBeforeRateLimits() async throws {
        let client = FakeCodexUsageClient()
        let provider = makeProvider(client: client)

        let first = try await provider.fetchUsage()
        let second = try await provider.fetchUsage()
        let startCalls = await client.startCallCount()
        let requests = await client.recordedRequests()

        XCTAssertEqual(first, second)
        XCTAssertEqual(startCalls, 1)
        XCTAssertEqual(
            requests,
            [
                .init(
                    method: "account/read",
                    params: .object(["refreshToken": .bool(false)])
                ),
                .init(method: "account/rateLimits/read", params: nil),
                .init(
                    method: "account/read",
                    params: .object(["refreshToken": .bool(false)])
                ),
                .init(method: "account/rateLimits/read", params: nil)
            ]
        )
        XCTAssertEqual(first.capturedAt, fixedDate)
    }

    func testSuccessfulStartIsNotRepeatedAfterRejectedAccount() async {
        let client = FakeCodexUsageClient(
            accountResponse: .object([
                "requiresOpenaiAuth": .bool(true),
                "account": .null
            ])
        )
        let provider = makeProvider(client: client)

        for _ in 0..<2 {
            do {
                _ = try await provider.fetchUsage()
                XCTFail("Expected authentication rejection")
            } catch {
                XCTAssertEqual(error as? CodexUsageError, .notAuthenticated)
            }
        }

        let startCalls = await client.startCallCount()
        let rateLimitCalls = await client.requestCallCount(
            method: "account/rateLimits/read"
        )
        XCTAssertEqual(startCalls, 1)
        XCTAssertEqual(rateLimitCalls, 0)
    }

    func testAppServerErrorsAreSanitized() async {
        let client = FakeCodexUsageClient(
            startError: JSONRPCError.executableNotFound(
                "/Users/private/.local/bin/codex-secret"
            )
        )
        let provider = makeProvider(client: client)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected app-server failure")
        } catch {
            XCTAssertEqual(
                error as? CodexUsageError,
                .appServerFailure(.executableUnavailable)
            )
            XCTAssertFalse(String(describing: error).contains("/Users/private"))
            XCTAssertFalse(
                (error as? LocalizedError)?.errorDescription?
                    .contains("codex-secret") == true
            )
        }
    }

    func testSanitizedErrorDescriptionsPreserveSafeCategories() {
        let descriptions = [
            CodexUsageError.unsupportedAccountMode(.apiKey).errorDescription,
            CodexUsageError.unsupportedAccountMode(.amazonBedrock)
                .errorDescription,
            CodexUsageError.invalidResetTimestamp(.short).errorDescription,
            CodexUsageError.invalidResetTimestamp(.weekly).errorDescription,
            CodexUsageError.appServerFailure(.timeout).errorDescription,
            CodexUsageError.appServerFailure(.protocolViolation)
                .errorDescription
        ]

        XCTAssertEqual(Set(descriptions.compactMap { $0 }).count, 6)
        XCTAssertTrue(descriptions.compactMap { $0 }.allSatisfy {
            !$0.contains("private") && !$0.contains("/")
        })
    }

    func testFetchesAreSerializedWithoutCoalescing() async throws {
        let accountGate = TestSuspensionGate()
        let fetchGate = CodexUsageFetchGate()
        let client = FakeCodexUsageClient(accountGate: accountGate)
        let provider = makeProvider(client: client, gate: fetchGate)

        let first = Task { try await provider.fetchUsage() }
        await accountGate.waitUntilEntered()
        let second = Task { try await provider.fetchUsage() }
        await fetchGate.waitUntilQueued()

        let callsWhileFirstBlocked = await client.requestCallCount(
            method: "account/read"
        )
        XCTAssertEqual(callsWhileFirstBlocked, 1)
        accountGate.releaseNext()
        _ = try await first.value

        await accountGate.waitUntilEntered()
        let accountCalls = await client.requestCallCount(method: "account/read")
        XCTAssertEqual(accountCalls, 2)
        accountGate.releaseNext()
        _ = try await second.value
        let rateLimitCalls = await client.requestCallCount(
            method: "account/rateLimits/read"
        )
        XCTAssertEqual(rateLimitCalls, 2)
    }

    func testCancellationWhileWaitingForGateIsIndependent() async throws {
        let accountGate = TestSuspensionGate()
        let fetchGate = CodexUsageFetchGate()
        let client = FakeCodexUsageClient(accountGate: accountGate)
        let provider = makeProvider(client: client, gate: fetchGate)

        let first = Task { try await provider.fetchUsage() }
        await accountGate.waitUntilEntered()
        let second = Task { try await provider.fetchUsage() }
        await fetchGate.waitUntilQueued()
        second.cancel()

        do {
            _ = try await second.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let accountCalls = await client.requestCallCount(method: "account/read")
        XCTAssertEqual(accountCalls, 1)

        accountGate.releaseNext()
        _ = try await first.value
    }

    func testCancellationAfterGateHandoffReleasesPermit() async throws {
        let gate = CodexUsageFetchGate()
        let handoffBarrier = TestSuspensionGate()
        try await gate.acquire()

        let queued = Task {
            try await gate.acquire {
                await handoffBarrier.waitIgnoringCancellation()
            }
        }
        await gate.waitUntilQueued()
        await gate.release()
        await handoffBarrier.waitUntilEntered()
        queued.cancel()
        handoffBarrier.releaseNext()

        do {
            try await queued.value
            XCTFail("Expected cancellation after handoff")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        try await gate.acquire()
        await gate.release()
    }

    func testCancelledStartupCallerDoesNotPoisonLaterFetch() async throws {
        let startGate = TestSuspensionGate()
        let client = FakeCodexUsageClient(startGate: startGate)
        let provider = makeProvider(client: client)

        let first = Task { try await provider.fetchUsage() }
        await startGate.waitUntilEntered()
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("Expected startup waiter cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let startCallsBeforeRelease = await client.startCallCount()
        let accountCallsBeforeRelease = await client.requestCallCount(
            method: "account/read"
        )
        XCTAssertEqual(startCallsBeforeRelease, 1)
        XCTAssertEqual(accountCallsBeforeRelease, 0)

        startGate.releaseNext()
        let snapshot = try await provider.fetchUsage()
        let finalStartCalls = await client.startCallCount()
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(finalStartCalls, 1)
    }

    func testCancellationDuringRequestPropagatesCancellation() async {
        let accountGate = TestSuspensionGate()
        let client = FakeCodexUsageClient(accountGate: accountGate)
        let provider = makeProvider(client: client)

        let fetch = Task { try await provider.fetchUsage() }
        await accountGate.waitUntilEntered()
        fetch.cancel()

        do {
            _ = try await fetch.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let rateLimitCalls = await client.requestCallCount(
            method: "account/rateLimits/read"
        )
        XCTAssertEqual(rateLimitCalls, 0)
    }

    func testConcurrentAndRepeatedShutdownCallsClientOnce() async throws {
        let shutdownGate = TestSuspensionGate()
        let joinCounter = TestCallCounter()
        let client = FakeCodexUsageClient(shutdownGate: shutdownGate)
        let provider = makeProvider(
            client: client,
            didJoinShutdown: { await joinCounter.recordCall() }
        )

        let first = Task { try await provider.shutdown() }
        await shutdownGate.waitUntilEntered()
        let second = Task { try await provider.shutdown() }
        await joinCounter.waitForCalls(2)
        let callsWhileBlocked = await client.shutdownCallCount()
        XCTAssertEqual(callsWhileBlocked, 1)

        shutdownGate.releaseNext()
        try await first.value
        try await second.value
        try await provider.shutdown()
        let finalCalls = await client.shutdownCallCount()
        XCTAssertEqual(finalCalls, 1)
    }

    func testConcurrentFailedShutdownCanRetryWithoutStaleWaiterClearingRetry() async {
        let firstShutdownGate = TestSuspensionGate()
        let joinCounter = TestCallCounter()
        let client = FakeCodexUsageClient(
            shutdownGate: firstShutdownGate,
            shutdownFailures: 1
        )
        let provider = makeProvider(
            client: client,
            didJoinShutdown: { await joinCounter.recordCall() }
        )

        let first = Task { try await provider.shutdown() }
        await firstShutdownGate.waitUntilEntered()
        let second = Task { try await provider.shutdown() }
        let third = Task { try await provider.shutdown() }
        await joinCounter.waitForCalls(3)
        firstShutdownGate.releaseNext()

        for task in [first, second, third] {
            do {
                try await task.value
                XCTFail("Expected shared shutdown failure")
            } catch {
                XCTAssertEqual(
                    error as? CodexUsageError,
                    .appServerFailure(.transport)
                )
            }
        }

        do {
            try await provider.shutdown()
        } catch {
            XCTFail("Expected retry to succeed: \(error)")
        }
        let calls = await client.shutdownCallCount()
        XCTAssertEqual(calls, 2)
    }

    func testLateCallerCancellationCannotReturnCompletedSnapshot() async {
        let beforeReturnGate = TestSuspensionGate()
        let client = FakeCodexUsageClient()
        let provider = makeProvider(
            client: client,
            beforeReturningSnapshot: {
                await beforeReturnGate.waitIgnoringCancellation()
            }
        )

        let fetch = Task { try await provider.fetchUsage() }
        await beforeReturnGate.waitUntilEntered()
        fetch.cancel()
        beforeReturnGate.releaseNext()

        do {
            _ = try await fetch.value
            XCTFail("Expected late cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationDuringFinalPermitReleaseCannotReturnSnapshot() async {
        let releaseBarrier = TestSuspensionGate()
        let gate = CodexUsageFetchGate(beforeRelease: {
            await releaseBarrier.waitIgnoringCancellation()
        })
        let client = FakeCodexUsageClient()
        let provider = makeProvider(client: client, gate: gate)

        let fetch = Task { try await provider.fetchUsage() }
        await releaseBarrier.waitUntilEntered()
        fetch.cancel()
        releaseBarrier.releaseNext()

        do {
            _ = try await fetch.value
            XCTFail("Expected cancellation during final release")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let releases = await gate.completedReleaseCount()
        XCTAssertEqual(releases, 1)
    }

    func testShutdownDuringFinalPermitReleaseCannotReturnSnapshot() async throws {
        let releaseBarrier = TestSuspensionGate()
        let gate = CodexUsageFetchGate(beforeRelease: {
            await releaseBarrier.waitIgnoringCancellation()
        })
        let client = FakeCodexUsageClient()
        let provider = makeProvider(client: client, gate: gate)

        let fetch = Task { try await provider.fetchUsage() }
        await releaseBarrier.waitUntilEntered()
        try await provider.shutdown()
        releaseBarrier.releaseNext()

        do {
            _ = try await fetch.value
            XCTFail("Expected stopped provider during final release")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .stopped)
        }
        let releases = await gate.completedReleaseCount()
        XCTAssertEqual(releases, 1)
    }

    func testShutdownCancelsActiveFetchAndStopsFutureFetches() async throws {
        let accountGate = TestSuspensionGate()
        let client = FakeCodexUsageClient(accountGate: accountGate)
        let provider = makeProvider(client: client)

        let fetch = Task { try await provider.fetchUsage() }
        await accountGate.waitUntilEntered()
        try await provider.shutdown()

        do {
            _ = try await fetch.value
            XCTFail("Expected active fetch cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected stopped provider")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .stopped)
        }
    }

    func testSyntheticClientProducesNoPartialSnapshotAfterMappingFailure() async {
        let client = FakeCodexUsageClient(
            rateLimitsResponse: .object([
                "rateLimits": .object([
                    "primary": .object([
                        "windowDurationMins": .integer(10_080),
                        "usedPercent": .integer(50),
                        "resetsAt": .null
                    ]),
                    "secondary": .null
                ])
            ])
        )
        let provider = makeProvider(client: client)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected missing short window")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .missingShortWindow)
        }
    }

    private func makeProvider(
        client: FakeCodexUsageClient,
        gate: CodexUsageFetchGate = CodexUsageFetchGate(),
        beforeReturningSnapshot: @escaping @Sendable () async throws -> Void = {},
        didJoinShutdown: @escaping @Sendable () async -> Void = {}
    ) -> CodexUsageProvider {
        CodexUsageProvider(
            client: client,
            clock: FixedUsageClock(now: fixedDate),
            gate: gate,
            beforeReturningSnapshot: beforeReturningSnapshot,
            didJoinShutdown: didJoinShutdown
        )
    }
}

private struct FixedUsageClock: UsageClock {
    let nowValue: Date

    init(now: Date) {
        nowValue = now
    }

    func now() -> Date {
        nowValue
    }
}

private actor FakeCodexUsageClient: CodexUsageClient {
    struct Request: Equatable, Sendable {
        let method: String
        let params: JSONValue?
    }

    private let accountResponse: JSONValue
    private let rateLimitsResponse: JSONValue
    private let startError: (any Error & Sendable)?
    private let startGate: TestSuspensionGate?
    private let accountGate: TestSuspensionGate?
    private let shutdownGate: TestSuspensionGate?
    private var shutdownFailures: Int

    private var startCalls = 0
    private var requests: [Request] = []
    private var shutdownCalls = 0

    init(
        accountResponse: JSONValue = FakeCodexUsageClient.validAccount,
        rateLimitsResponse: JSONValue = FakeCodexUsageClient.validRateLimits,
        startError: (any Error & Sendable)? = nil,
        startGate: TestSuspensionGate? = nil,
        accountGate: TestSuspensionGate? = nil,
        shutdownGate: TestSuspensionGate? = nil,
        shutdownFailures: Int = 0
    ) {
        self.accountResponse = accountResponse
        self.rateLimitsResponse = rateLimitsResponse
        self.startError = startError
        self.startGate = startGate
        self.accountGate = accountGate
        self.shutdownGate = shutdownGate
        self.shutdownFailures = shutdownFailures
    }

    func start() async throws {
        startCalls += 1
        if let startGate {
            try await startGate.wait()
        }
        if let startError {
            throw startError
        }
    }

    func request(
        method: String,
        params: JSONValue?
    ) async throws -> JSONValue {
        requests.append(Request(method: method, params: params))
        if method == "account/read" {
            if let accountGate {
                try await accountGate.wait()
            }
            return accountResponse
        }
        if method == "account/rateLimits/read" {
            return rateLimitsResponse
        }
        throw JSONRPCError.remoteError(code: -32_601)
    }

    func shutdown() async throws {
        shutdownCalls += 1
        if shutdownCalls == 1, let shutdownGate {
            try await shutdownGate.wait()
        }
        if shutdownFailures > 0 {
            shutdownFailures -= 1
            throw JSONRPCError.transportClosed
        }
    }

    func startCallCount() -> Int {
        startCalls
    }

    func recordedRequests() -> [Request] {
        requests
    }

    func requestCallCount(method: String) -> Int {
        requests.filter { $0.method == method }.count
    }

    func shutdownCallCount() -> Int {
        shutdownCalls
    }

    private static let validAccount: JSONValue = .object([
        "requiresOpenaiAuth": .bool(true),
        "account": .object([
            "type": .string("chatgpt"),
            "email": .null,
            "planType": .string("plus")
        ])
    ])

    private static let validRateLimits: JSONValue = .object([
        "rateLimits": .object([
            "primary": .object([
                "windowDurationMins": .integer(300),
                "usedPercent": .integer(40),
                "resetsAt": .integer(10_000)
            ]),
            "secondary": .object([
                "windowDurationMins": .integer(10_080),
                "usedPercent": .integer(60),
                "resetsAt": .null
            ])
        ])
    ])
}

private actor TestSuspensionGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Result<Void, Error>, Never>
    }

    private var waiters: [Waiter] = []
    private var entryObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        let id = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                let observers = entryObservers
                entryObservers.removeAll()
                observers.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try result.get()
    }

    func waitUntilEntered() async {
        guard waiters.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            entryObservers.append(continuation)
        }
    }

    func waitIgnoringCancellation() async {
        let result = await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: UUID(), continuation: continuation))
            let observers = entryObservers
            entryObservers.removeAll()
            observers.forEach { $0.resume() }
        }
        _ = try? result.get()
    }

    nonisolated func releaseNext() {
        Task { await self.resumeNext() }
    }

    private func resumeNext() {
        guard !waiters.isEmpty else {
            return
        }
        waiters.removeFirst().continuation.resume(returning: .success(()))
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(
            returning: .failure(CancellationError())
        )
    }
}

private actor TestCallCounter {
    private struct Observer {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var calls = 0
    private var observers: [Observer] = []

    func recordCall() {
        calls += 1
        let ready = observers.filter { $0.target <= calls }
        observers.removeAll { $0.target <= calls }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForCalls(_ target: Int) async {
        guard calls < target else {
            return
        }
        await withCheckedContinuation { continuation in
            observers.append(Observer(target: target, continuation: continuation))
        }
    }
}
