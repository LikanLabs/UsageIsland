import AppKit
import Foundation
import XCTest

@testable import UsageIslandPrototype

@MainActor
final class LiveCompositionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testLiveCompositionSeedsOnlyClaudeAndOpenCodeAtOneCaptureTime() {
        let harness = makeLiveHarness()

        XCTAssertEqual(harness.composition.model.providers.map(\.id), [.claude, .openCodeGo])
        XCTAssertEqual(
            Set(harness.composition.model.providers.map(\.capturedAt)),
            [now]
        )
        XCTAssertEqual(
            harness.composition.model.connectionStates,
            [.claude: .connected, .codex: .disconnected, .openCodeGo: .connected]
        )
        XCTAssertEqual(harness.composition.model.freshness(for: .codex), .unavailable)
    }

    func testLiveCompositionStartsWithoutDemoAgents() {
        let harness = makeLiveHarness()

        XCTAssertTrue(harness.composition.model.agents.isEmpty)
        XCTAssertTrue(harness.composition.model.activeAgents.isEmpty)
        XCTAssertNil(harness.composition.model.attentionAgent)
    }

    func testLiveCompositionCreatesAndRetainsExactlyOneCodexProvider() {
        var factoryCalls = 0
        var createdProvider: CodexUsageProvider?

        let harness = makeLiveHarness { client, clock in
            factoryCalls += 1
            let provider = CodexUsageProvider(client: client, clock: clock)
            createdProvider = provider
            return provider
        }

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertNotNil(harness.composition.codexUsageProvider)
        XCTAssertTrue(harness.composition.codexUsageProvider === createdProvider)
    }

    func testInitialRefreshAddsRealCodexAndPreservesDemoProviders() async {
        let gate = LiveTestGate()
        let harness = makeLiveHarness(accountGate: gate)
        let initial = harness.composition.model.providers
        let delegate = AppDelegate(
            composition: harness.composition,
            terminationReply: { _ in }
        )

        delegate.startInitialRefresh()
        await gate.waitUntilEntered()

        XCTAssertEqual(harness.composition.model.providers, initial)
        XCTAssertEqual(harness.composition.model.connectionStates[.codex], .connecting)

        await gate.open()
        await delegate.waitForInitialRefresh()

        XCTAssertEqual(
            harness.composition.model.providers.map(\.id),
            [.claude, .codex, .openCodeGo]
        )
        XCTAssertEqual(harness.composition.model.connectionStates[.codex], .connected)
        XCTAssertEqual(
            harness.composition.model.providers.first(where: { $0.id == .claude })?.shortWindow,
            initial.first(where: { $0.id == .claude })?.shortWindow
        )
        XCTAssertEqual(
            harness.composition.model.providers.first(where: { $0.id == .openCodeGo })?.shortWindow,
            initial.first(where: { $0.id == .openCodeGo })?.shortWindow
        )
    }

    func testFirstCodexFailureKeepsOnlyImmediateDemoSnapshots() async {
        let harness = makeLiveHarness(startError: JSONRPCError.transportClosed)

        await harness.composition.model.refreshUsage()

        XCTAssertEqual(harness.composition.model.providers.map(\.id), [.claude, .openCodeGo])
        XCTAssertEqual(harness.composition.model.connectionStates[.codex], .failed)
        XCTAssertEqual(harness.composition.model.freshness(for: .codex), .unavailable)
    }

    func testFailureAfterCodexSuccessPreservesItAsStale() async throws {
        let harness = makeLiveHarness(rateLimitFailures: [2])

        await harness.composition.model.refreshUsage()
        let successfulCodex = try XCTUnwrap(
            harness.composition.model.providers.first(where: { $0.id == .codex })
        )
        await harness.composition.model.refreshUsage()

        let staleCodex = try XCTUnwrap(
            harness.composition.model.providers.first(where: { $0.id == .codex })
        )
        XCTAssertEqual(staleCodex.shortWindow, successfulCodex.shortWindow)
        XCTAssertEqual(staleCodex.freshness, .stale)
        XCTAssertEqual(harness.composition.model.connectionStates[.codex], .failed)
        XCTAssertEqual(harness.composition.model.providers.map(\.id), [.claude, .codex, .openCodeGo])
    }

    func testMissingExecutableUsesUnavailableAdapterWithoutCreatingCodexProvider() async {
        var factoryCalls = 0
        let locator = ExecutableLocator(
            environmentPath: nil,
            commonSearchPaths: [],
            isExecutable: { _ in false }
        )
        let client = LiveFakeCodexClient()
        let composition = AppDelegate.makeLiveComposition(
            clock: FixedLiveClock(now),
            locator: locator
        ) { _, clock in
            factoryCalls += 1
            return CodexUsageProvider(client: client, clock: clock)
        }

        XCTAssertNil(composition.codexUsageProvider)
        XCTAssertEqual(factoryCalls, 0)

        await composition.model.refreshUsage()

        XCTAssertEqual(composition.model.providers.map(\.id), [.claude, .openCodeGo])
        XCTAssertEqual(composition.model.connectionStates[.codex], .failed)
        XCTAssertEqual(composition.model.freshness(for: .codex), .unavailable)
        let startCalls = await client.startCallCount()
        XCTAssertEqual(startCalls, 0)
    }

    func testLivePriorityKeepsExistingV26OrderingBeforeAndAfterCodexAppears() async {
        let harness = makeLiveHarness()

        XCTAssertEqual(
            harness.composition.model.prioritizedProviders.map(\.id),
            [.claude, .openCodeGo]
        )

        await harness.composition.model.refreshUsage()

        XCTAssertEqual(
            harness.composition.model.prioritizedProviders.map(\.id),
            [.claude, .codex, .openCodeGo]
        )
    }

    func testDefaultAppModelInitializerPreservesDemoAgents() throws {
        let model = try AppModel(
            providerAdapters: DemoUsageProvider.providerAdapters(
                for: .normal,
                clock: FixedLiveClock(now)
            ),
            clock: FixedLiveClock(now),
            initialSnapshots: DemoUsageProvider.snapshots(
                for: .normal,
                clock: FixedLiveClock(now)
            )
        )

        XCTAssertEqual(model.agents.count, 2)
        XCTAssertEqual(model.agents.map(\.provider), [.claude, .codex])
    }

    func testExplicitInitialAgentsAreUsedWithoutChangingDemoScenarioBehavior() throws {
        let model = try AppModel(
            providerAdapters: [],
            clock: FixedLiveClock(now),
            initialSnapshots: [],
            initialAgents: []
        )

        XCTAssertTrue(model.agents.isEmpty)

        model.applyScenario(.waiting)

        XCTAssertEqual(model.agents.count, 2)
        XCTAssertEqual(model.scenario, .waiting)
    }

    func testLiveBeaconHidesDemoScenarios() {
        XCTAssertTrue(BeaconController.demoScenarios(whenAllowed: false).isEmpty)
    }

    func testDemoBeaconPreservesEveryScenario() {
        let model = AppDelegate.makeDemoModel(clock: FixedLiveClock(now))

        XCTAssertEqual(
            BeaconController.demoScenarios(whenAllowed: true),
            DemoScenario.allCases
        )
        XCTAssertFalse(model.agents.isEmpty)
    }

    func testPulseRefreshActionUsesLiveRefreshWithoutApplyingDemoScenario() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pulseURL = repositoryRoot.appendingPathComponent(
            "Sources/UsageIslandPrototype/UI/PulseView.swift"
        )
        let source = try String(contentsOf: pulseURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Task { await model.refreshUsage() }"))
        XCTAssertFalse(source.contains("model.applyScenario(model.scenario)"))
    }

    func testTerminationRepliesOnceAndShutsDownCodexOnceAcrossRepeatedRequests() async {
        let shutdownGate = LiveTestGate()
        let harness = makeLiveHarness(shutdownGate: shutdownGate)
        let replies = TerminationReplyRecorder()
        let delegate = AppDelegate(
            composition: harness.composition,
            terminationReply: { replies.record($0) }
        )

        XCTAssertEqual(delegate.requestTermination(), .terminateLater)
        XCTAssertEqual(delegate.requestTermination(), .terminateLater)
        await shutdownGate.waitUntilEntered()
        let shutdownCallsWhilePending = await harness.client.shutdownCallCount()
        XCTAssertEqual(shutdownCallsWhilePending, 1)

        await shutdownGate.open()
        await delegate.waitForTermination()

        XCTAssertEqual(replies.values, [true])
        let completedShutdownCalls = await harness.client.shutdownCallCount()
        XCTAssertEqual(completedShutdownCalls, 1)
        XCTAssertEqual(delegate.requestTermination(), .terminateNow)
        XCTAssertEqual(replies.values, [true])
    }

    func testTerminationDuringInitialRefreshCancelsFetchWithoutLateCodexPublication() async {
        let accountGate = LiveTestGate()
        let harness = makeLiveHarness(accountGate: accountGate)
        let initialProviders = harness.composition.model.providers
        let replies = TerminationReplyRecorder()
        let delegate = AppDelegate(
            composition: harness.composition,
            terminationReply: { replies.record($0) }
        )

        delegate.startInitialRefresh()
        await accountGate.waitUntilEntered()
        XCTAssertEqual(harness.composition.model.connectionStates[.codex], .connecting)

        XCTAssertEqual(delegate.requestTermination(), .terminateLater)
        XCTAssertEqual(delegate.requestTermination(), .terminateLater)
        await accountGate.waitUntilCancelled()
        await delegate.waitForTermination()

        let accountCalls = await harness.client.accountCallCount()
        let rateLimitCalls = await harness.client.rateLimitCallCount()
        let shutdownCalls = await harness.client.shutdownCallCount()
        XCTAssertEqual(accountCalls, 1)
        XCTAssertEqual(rateLimitCalls, 0)
        XCTAssertEqual(shutdownCalls, 1)
        XCTAssertEqual(replies.values, [true])
        XCTAssertEqual(harness.composition.model.providers, initialProviders)
        XCTAssertNil(
            harness.composition.model.providers.first(where: { $0.id == .codex })
        )
        XCTAssertEqual(
            harness.composition.model.connectionStates,
            [.claude: .disconnected, .codex: .disconnected, .openCodeGo: .disconnected]
        )
        XCTAssertEqual(delegate.requestTermination(), .terminateNow)
        XCTAssertEqual(replies.values, [true])
    }

    func testTerminationRepliesEvenWhenShutdownFails() async {
        let harness = makeLiveHarness(shutdownError: JSONRPCError.transportClosed)
        let replies = TerminationReplyRecorder()
        let delegate = AppDelegate(
            composition: harness.composition,
            terminationReply: { replies.record($0) }
        )

        XCTAssertEqual(delegate.requestTermination(), .terminateLater)
        await delegate.waitForTermination()

        XCTAssertEqual(replies.values, [true])
        let shutdownCalls = await harness.client.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
        XCTAssertEqual(
            harness.composition.model.connectionStates,
            [.claude: .disconnected, .codex: .disconnected, .openCodeGo: .disconnected]
        )
    }

    func testTerminationWithoutInstalledCodexStillRepliesOnce() async {
        let locator = ExecutableLocator(
            environmentPath: nil,
            commonSearchPaths: [],
            isExecutable: { _ in false }
        )
        let composition = AppDelegate.makeLiveComposition(
            clock: FixedLiveClock(now),
            locator: locator
        )
        let replies = TerminationReplyRecorder()
        let delegate = AppDelegate(
            composition: composition,
            terminationReply: { replies.record($0) }
        )

        XCTAssertEqual(delegate.requestTermination(), .terminateLater)
        await delegate.waitForTermination()

        XCTAssertEqual(replies.values, [true])
    }

    private func makeLiveHarness(
        accountGate: LiveTestGate? = nil,
        shutdownGate: LiveTestGate? = nil,
        startError: (any Error & Sendable)? = nil,
        shutdownError: (any Error & Sendable)? = nil,
        rateLimitFailures: Set<Int> = [],
        providerFactory: ((LiveFakeCodexClient, any UsageClock) -> CodexUsageProvider)? = nil
    ) -> LiveHarness {
        let client = LiveFakeCodexClient(
            accountGate: accountGate,
            shutdownGate: shutdownGate,
            startError: startError,
            shutdownError: shutdownError,
            rateLimitFailures: rateLimitFailures
        )
        let locator = ExecutableLocator(
            environmentPath: nil,
            additionalSearchPaths: [URL(fileURLWithPath: "/synthetic/bin", isDirectory: true)],
            commonSearchPaths: [],
            isExecutable: { $0.lastPathComponent == "codex" }
        )
        let composition = AppDelegate.makeLiveComposition(
            clock: FixedLiveClock(now),
            locator: locator
        ) { _, clock in
            providerFactory?(client, clock)
                ?? CodexUsageProvider(client: client, clock: clock)
        }
        return LiveHarness(composition: composition, client: client)
    }
}

private struct LiveHarness {
    let composition: LiveComposition
    let client: LiveFakeCodexClient
}

private struct FixedLiveClock: UsageClock {
    let value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        value
    }
}

@MainActor
private final class TerminationReplyRecorder {
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }
}

private actor LiveFakeCodexClient: CodexUsageClient {
    private let accountGate: LiveTestGate?
    private let shutdownGate: LiveTestGate?
    private let startError: (any Error & Sendable)?
    private let shutdownError: (any Error & Sendable)?
    private let rateLimitFailures: Set<Int>
    private var startCalls = 0
    private var accountCalls = 0
    private var rateLimitCalls = 0
    private var shutdownCalls = 0

    init(
        accountGate: LiveTestGate? = nil,
        shutdownGate: LiveTestGate? = nil,
        startError: (any Error & Sendable)? = nil,
        shutdownError: (any Error & Sendable)? = nil,
        rateLimitFailures: Set<Int> = []
    ) {
        self.accountGate = accountGate
        self.shutdownGate = shutdownGate
        self.startError = startError
        self.shutdownError = shutdownError
        self.rateLimitFailures = rateLimitFailures
    }

    func start() async throws {
        startCalls += 1
        if let startError {
            throw startError
        }
    }

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "account/read":
            accountCalls += 1
            if let accountGate {
                try await accountGate.wait()
            }
            return Self.accountResponse
        case "account/rateLimits/read":
            rateLimitCalls += 1
            if rateLimitFailures.contains(rateLimitCalls) {
                throw JSONRPCError.transportClosed
            }
            return Self.rateLimitsResponse
        default:
            throw JSONRPCError.remoteError(code: -32_601)
        }
    }

    func shutdown() async throws {
        shutdownCalls += 1
        if let shutdownGate {
            try await shutdownGate.wait()
        }
        if let shutdownError {
            throw shutdownError
        }
    }

    func startCallCount() -> Int {
        startCalls
    }

    func shutdownCallCount() -> Int {
        shutdownCalls
    }

    func accountCallCount() -> Int {
        accountCalls
    }

    func rateLimitCallCount() -> Int {
        rateLimitCalls
    }

    private static let accountResponse: JSONValue = .object([
        "requiresOpenaiAuth": .bool(true),
        "account": .object([
            "type": .string("chatgpt"),
            "email": .null,
            "planType": .string("plus")
        ])
    ])

    private static let rateLimitsResponse: JSONValue = .object([
        "rateLimits": .object([
            "primary": .object([
                "windowDurationMins": .integer(300),
                "usedPercent": .number(40.5),
                "resetsAt": .integer(1_700_003_600)
            ]),
            "secondary": .object([
                "windowDurationMins": .integer(10_080),
                "usedPercent": .number(60.5),
                "resetsAt": .null
            ])
        ])
    ])
}

private actor LiveTestGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Result<Void, Error>, Never>
    }

    private var isOpen = false
    private var waiters: [Waiter] = []
    private var entryObservers: [CheckedContinuation<Void, Never>] = []
    private var cancellationCount = 0
    private var cancellationObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        try Task.checkCancellation()
        guard !isOpen else {
            return
        }
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
        guard !waiters.isEmpty else {
            await withCheckedContinuation { continuation in
                entryObservers.append(continuation)
            }
            return
        }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.continuation.resume(returning: .success(())) }
    }

    func waitUntilCancelled() async {
        guard cancellationCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            cancellationObservers.append(continuation)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        cancellationCount += 1
        waiter.continuation.resume(returning: .failure(CancellationError()))
        let observers = cancellationObservers
        cancellationObservers.removeAll()
        observers.forEach { $0.resume() }
    }
}
