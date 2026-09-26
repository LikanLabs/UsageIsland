import Foundation
import XCTest

@testable import UsageIslandPrototype

@MainActor
final class AppModelStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDuplicateProviderAdaptersReturnTypedConfigurationError() {
        let first = ControlledProvider(id: .codex, controller: ControlledResponses())
        let duplicate = ControlledProvider(id: .codex, controller: ControlledResponses())

        assertConfigurationError(
            .duplicateProviderAdapter(.codex),
            providerAdapters: [first, duplicate],
            initialSnapshots: []
        )
    }

    func testDuplicateInitialSnapshotsReturnTypedConfigurationError() {
        let adapter = ControlledProvider(id: .codex, controller: ControlledResponses())
        let initial = snapshot(id: .codex, remaining: 60, capturedAt: now)

        assertConfigurationError(
            .duplicateInitialSnapshot(.codex),
            providerAdapters: [adapter],
            initialSnapshots: [initial, initial]
        )
    }

    func testSnapshotWithoutAdapterReturnsTypedConfigurationError() {
        let orphaned = snapshot(id: .codex, remaining: 60, capturedAt: now)

        assertConfigurationError(
            .snapshotWithoutAdapter(.codex),
            providerAdapters: [],
            initialSnapshots: [orphaned]
        )
    }

    func testAdapterWithoutInitialSnapshotStartsDisconnectedAndUnavailable() {
        let adapter = ControlledProvider(id: .codex, controller: ControlledResponses())
        let model = makeModel(providerAdapter: adapter, initialSnapshots: [])

        XCTAssertTrue(model.providers.isEmpty)
        XCTAssertEqual(model.connectionStates[.codex], .disconnected)
        XCTAssertEqual(model.freshness(for: .codex), .unavailable)
    }

    func testFreshnessIsDerivedFromCanonicalSnapshot() {
        let adapter = ControlledProvider(id: .codex, controller: ControlledResponses())
        var initial = snapshot(id: .codex, remaining: 60, capturedAt: now)
        initial.freshness = .stale
        let model = makeModel(providerAdapter: adapter, initialSnapshots: [initial])

        XCTAssertEqual(model.freshness(for: .codex), .stale)
    }

    func testInvalidCompositionFallsBackToEmptySafeModel() {
        let orphaned = snapshot(id: .codex, remaining: 60, capturedAt: now)

        let model = AppDelegate.makeModel(
            providerAdapters: [],
            clock: FixedStoreClock(now),
            initialSnapshots: [orphaned]
        )

        XCTAssertTrue(model.providers.isEmpty)
        XCTAssertTrue(model.connectionStates.isEmpty)
        XCTAssertEqual(model.freshness(for: .codex), .unavailable)
        XCTAssertEqual(model.lastUpdatedAt, now)
    }

    func testSuccessfulRefreshTransitionsFromConnectingToConnected() async {
        let controller = ControlledResponses()
        let adapter = ControlledProvider(id: .codex, controller: controller)
        let model = makeModel(providerAdapter: adapter, initialSnapshots: [])
        let refreshed = snapshot(id: .codex, remaining: 32, capturedAt: now.addingTimeInterval(10))

        let task = Task { await model.refreshUsage() }
        await controller.waitForRequestCount(1)

        XCTAssertEqual(model.connectionStates[.codex], .connecting)
        await controller.resolve(request: 0, with: .success(refreshed))
        await task.value

        XCTAssertEqual(model.connectionStates[.codex], .connected)
        XCTAssertEqual(model.providers, [refreshed])
        XCTAssertEqual(model.lastUpdatedAt, refreshed.capturedAt)
    }

    func testFailureAfterSuccessPreservesSnapshotAndMarksItStale() async {
        let controller = ControlledResponses()
        let adapter = ControlledProvider(id: .codex, controller: controller)
        let model = makeModel(providerAdapter: adapter, initialSnapshots: [])
        let refreshed = snapshot(id: .codex, remaining: 32, capturedAt: now.addingTimeInterval(10))

        let successTask = Task { await model.refreshUsage() }
        await controller.waitForRequestCount(1)
        await controller.resolve(request: 0, with: .success(refreshed))
        await successTask.value

        let failureTask = Task { await model.refreshUsage() }
        await controller.waitForRequestCount(2)
        await controller.resolve(request: 1, with: .failure)
        await failureTask.value

        XCTAssertEqual(model.connectionStates[.codex], .failed)
        XCTAssertEqual(model.freshness(for: .codex), .stale)
        XCTAssertEqual(model.providers.count, 1)
        XCTAssertEqual(model.providers[0].preferredWindow, refreshed.preferredWindow)
        XCTAssertEqual(model.providers[0].freshness, .stale)
        XCTAssertEqual(model.lastUpdatedAt, refreshed.capturedAt)
    }

    func testFirstFailureDoesNotInventPercentages() async {
        let controller = ControlledResponses()
        let adapter = ControlledProvider(id: .codex, controller: controller)
        let model = makeModel(providerAdapter: adapter, initialSnapshots: [])

        let task = Task { await model.refreshUsage() }
        await controller.waitForRequestCount(1)
        await controller.resolve(request: 0, with: .failure)
        await task.value

        XCTAssertTrue(model.providers.isEmpty)
        XCTAssertEqual(model.connectionStates[.codex], .failed)
        XCTAssertEqual(model.freshness(for: .codex), .unavailable)
    }

    func testCancellingAwaitingCallerCancelsManagedRefreshAndDoesNotPublish() async {
        let controller = ControlledResponses()
        let adapter = ControlledProvider(id: .codex, controller: controller)
        let initial = snapshot(id: .codex, remaining: 60, capturedAt: now)
        let replacement = snapshot(id: .codex, remaining: 5, capturedAt: now)
        let model = makeModel(providerAdapter: adapter, initialSnapshots: [initial])

        let task = Task { await model.refreshUsage() }
        await controller.waitForRequestCount(1)
        task.cancel()
        await controller.resolve(request: 0, with: .success(replacement))
        await task.value
        let observedCancellation = await controller.didObserveCancellation()

        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(model.providers, [initial])
        XCTAssertEqual(model.connectionStates[.codex], .disconnected)
    }

    func testOlderResponseCannotReplaceNewerRefresh() async {
        let controller = ControlledResponses()
        let adapter = ControlledProvider(id: .codex, controller: controller)
        let initial = snapshot(id: .codex, remaining: 60, capturedAt: now)
        let older = snapshot(id: .codex, remaining: 10, capturedAt: now.addingTimeInterval(10))
        let newer = snapshot(id: .codex, remaining: 80, capturedAt: now.addingTimeInterval(20))
        let model = makeModel(providerAdapter: adapter, initialSnapshots: [initial])

        let firstTask = Task { await model.refreshUsage() }
        await controller.waitForRequestCount(1)
        let secondTask = Task { await model.refreshUsage() }
        await controller.waitForRequestCount(2)

        await controller.resolve(request: 1, with: .success(newer))
        await secondTask.value
        await controller.resolve(request: 0, with: .success(older))
        await firstTask.value

        XCTAssertEqual(model.providers, [newer])
        XCTAssertEqual(model.lastUpdatedAt, newer.capturedAt)
    }

    func testStopCancelsActiveRefreshAndInvalidatesItsResult() async {
        let controller = ControlledResponses()
        let adapter = ControlledProvider(id: .codex, controller: controller)
        let initial = snapshot(id: .codex, remaining: 60, capturedAt: now)
        let model = makeModel(providerAdapter: adapter, initialSnapshots: [initial])

        let task = Task { await model.refreshUsage() }
        await controller.waitForRequestCount(1)
        model.stop()
        await controller.resolve(
            request: 0,
            with: .success(snapshot(id: .codex, remaining: 5, capturedAt: now))
        )
        await task.value
        let observedCancellation = await controller.didObserveCancellation()

        XCTAssertEqual(model.providers, [initial])
        XCTAssertEqual(model.connectionStates[.codex], .disconnected)
        XCTAssertNotEqual(model.providers[0].preferredWindow.remainingPercent, 5)
        XCTAssertTrue(observedCancellation)
    }

    private func makeModel(
        providerAdapter: any UsageProvider,
        initialSnapshots: [UsageSnapshot]
    ) -> AppModel {
        makeModel(providerAdapters: [providerAdapter], initialSnapshots: initialSnapshots)
    }

    private func makeModel(
        providerAdapters: [any UsageProvider],
        initialSnapshots: [UsageSnapshot]
    ) -> AppModel {
        do {
            return try AppModel(
                providerAdapters: providerAdapters,
                clock: FixedStoreClock(now),
                initialSnapshots: initialSnapshots
            )
        } catch {
            XCTFail("Expected valid AppModel configuration, received \(error)")
            return AppModel.empty(clock: FixedStoreClock(now))
        }
    }

    private func snapshot(
        id: ProviderID,
        remaining: Int,
        capturedAt: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            validatedProvider: id,
            preferredWindow: UsageWindow(
                validatedDurationMinutes: 300,
                remainingPercent: remaining,
                resetsAt: capturedAt.addingTimeInterval(3_600)
            ),
            additionalWindows: [
                UsageWindow(
                    validatedDurationMinutes: 10_080,
                    remainingPercent: 50,
                    resetsAt: nil
                )
            ],
            weeklySpend: 1.25,
            freshness: .fresh,
            isActivelyUsed: false,
            capturedAt: capturedAt
        )
    }

    private func assertConfigurationError(
        _ expected: AppModelConfigurationError,
        providerAdapters: [any UsageProvider],
        initialSnapshots: [UsageSnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AppModel(
                providerAdapters: providerAdapters,
                clock: FixedStoreClock(now),
                initialSnapshots: initialSnapshots
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AppModelConfigurationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private struct FixedStoreClock: UsageClock {
    let date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        date
    }
}

private struct ControlledProvider: UsageProvider {
    let id: ProviderID
    let controller: ControlledResponses

    func fetchUsage() async throws -> UsageSnapshot {
        let outcome = await controller.nextResponse()
        await controller.recordDelivery()
        if Task.isCancelled {
            await controller.recordCancellation()
        }

        switch outcome {
        case let .success(snapshot):
            return snapshot
        case .failure:
            throw ControlledProviderError.synthetic
        }
    }
}

private enum ControlledProviderError: Error {
    case synthetic
}

private enum ControlledOutcome: Sendable {
    case success(UsageSnapshot)
    case failure
}

private actor ControlledResponses {
    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<ControlledOutcome, Never>] = [:]
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var observedCancellation = false
    private var deliveryCount = 0
    private var deliveryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func nextResponse() async -> ControlledOutcome {
        let requestID = nextRequestID
        nextRequestID += 1
        resumeSatisfiedWaiters()

        return await withCheckedContinuation { continuation in
            pending[requestID] = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard nextRequestID < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func resolve(request: Int, with outcome: ControlledOutcome) {
        pending.removeValue(forKey: request)?.resume(returning: outcome)
    }

    func recordCancellation() {
        observedCancellation = true
    }

    func didObserveCancellation() -> Bool {
        observedCancellation
    }

    func recordDelivery() {
        deliveryCount += 1
        resumeSatisfiedDeliveryWaiters()
    }

    func waitForDeliveryCount(_ count: Int) async {
        guard deliveryCount < count else { return }
        await withCheckedContinuation { continuation in
            deliveryWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let ready = requestWaiters.filter { nextRequestID >= $0.0 }
        requestWaiters.removeAll { nextRequestID >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    private func resumeSatisfiedDeliveryWaiters() {
        let ready = deliveryWaiters.filter { deliveryCount >= $0.0 }
        deliveryWaiters.removeAll { deliveryCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}
