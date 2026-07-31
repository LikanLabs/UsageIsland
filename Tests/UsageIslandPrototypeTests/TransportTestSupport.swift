import Foundation

@testable import UsageIslandPrototype

actor FakeJSONRPCTransport: JSONRPCTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let startGate: AsyncStream<Void>
    private let startGateContinuation: AsyncStream<Void>.Continuation
    private let sendGate: AsyncStream<Void>
    private let sendGateContinuation: AsyncStream<Void>.Continuation
    private let incomingGate: AsyncStream<Void>
    private let incomingGateContinuation: AsyncStream<Void>.Continuation
    private let shutdownGate: AsyncStream<Void>
    private let shutdownGateContinuation: AsyncStream<Void>.Continuation

    private var sentData: [Data] = []
    private let startError: JSONRPCError?
    private let sendError: JSONRPCError?
    private let shutdownError: JSONRPCError?
    private let suspendsStart: Bool
    private let suspendedSendIndex: Int?
    private let suspendsIncomingBytes: Bool
    private let suspendsShutdown: Bool
    private var startCalls = 0
    private var sendCalls = 0
    private var sendsInFlight = 0
    private var incomingCalls = 0
    private var shutdownCalls = 0
    private var stderrChunks: [Data] = []
    private var didShutdown = false

    init(
        startError: JSONRPCError? = nil,
        sendError: JSONRPCError? = nil,
        shutdownError: JSONRPCError? = nil,
        suspendsStart: Bool = false,
        suspendsSend: Bool = false,
        suspendedSendIndex: Int? = nil,
        suspendsIncomingBytes: Bool = false,
        suspendsShutdown: Bool = false
    ) {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        let startPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        startGate = startPair.stream
        startGateContinuation = startPair.continuation
        let sendPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        sendGate = sendPair.stream
        sendGateContinuation = sendPair.continuation
        let incomingPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        incomingGate = incomingPair.stream
        incomingGateContinuation = incomingPair.continuation
        let shutdownPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        shutdownGate = shutdownPair.stream
        shutdownGateContinuation = shutdownPair.continuation
        self.startError = startError
        self.sendError = sendError
        self.shutdownError = shutdownError
        self.suspendsStart = suspendsStart
        self.suspendedSendIndex = suspendedSendIndex ?? (suspendsSend ? 0 : nil)
        self.suspendsIncomingBytes = suspendsIncomingBytes
        self.suspendsShutdown = suspendsShutdown
    }

    func start() async throws {
        startCalls += 1
        if let startError {
            throw startError
        }
        if suspendsStart {
            var iterator = startGate.makeAsyncIterator()
            _ = await iterator.next()
            if didShutdown {
                throw JSONRPCError.transportClosed
            }
        }
    }

    func send(_ data: Data) async throws {
        guard !didShutdown else {
            throw JSONRPCError.transportClosed
        }
        let sendIndex = sendCalls
        sendCalls += 1
        sendsInFlight += 1
        defer { sendsInFlight = max(0, sendsInFlight - 1) }
        sentData.append(data)
        if suspendedSendIndex == sendIndex {
            var iterator = sendGate.makeAsyncIterator()
            _ = await iterator.next()
        }
        if didShutdown {
            throw JSONRPCError.transportClosed
        }
        if let sendError {
            throw sendError
        }
    }

    func incomingBytes() async -> AsyncThrowingStream<Data, Error> {
        incomingCalls += 1
        if suspendsIncomingBytes {
            var iterator = incomingGate.makeAsyncIterator()
            _ = await iterator.next()
        }
        return stream
    }

    func shutdown() async throws {
        guard !didShutdown else {
            return
        }
        didShutdown = true
        shutdownCalls += 1
        startGateContinuation.finish()
        sendGateContinuation.finish()
        incomingGateContinuation.finish()
        continuation.finish()
        if suspendsShutdown {
            var iterator = shutdownGate.makeAsyncIterator()
            _ = await iterator.next()
        }
        if let shutdownError {
            throw shutdownError
        }
    }

    func dataSent(at index: Int, maximumYields: Int = 10_000) async throws -> Data {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if sentData.indices.contains(index) {
                return sentData[index]
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Message \(index) was not sent"
        )
    }

    func waitUntilStartCalled(maximumYields: Int = 10_000) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if startCalls > 0 {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Transport start was not called"
        )
    }

    func waitUntilSendCalled(maximumYields: Int = 10_000) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if sendCalls > 0 {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Transport send was not called"
        )
    }

    func waitUntilIncomingBytesCalled(
        maximumYields: Int = 10_000
    ) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if incomingCalls > 0 {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Transport incomingBytes was not called"
        )
    }

    func waitUntilShutdownCalled(maximumYields: Int = 10_000) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if shutdownCalls > 0 {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Transport shutdown was not called"
        )
    }

    func releaseStart() {
        startGateContinuation.yield()
        startGateContinuation.finish()
    }

    func releaseSend() {
        sendGateContinuation.yield()
        sendGateContinuation.finish()
    }

    func releaseIncomingBytes() {
        incomingGateContinuation.yield()
        incomingGateContinuation.finish()
    }

    func releaseShutdown() {
        shutdownGateContinuation.yield()
        shutdownGateContinuation.finish()
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func emitLine(_ line: String) {
        continuation.yield(Data("\(line)\n".utf8))
    }

    func emitStandardError(_ data: Data) {
        stderrChunks.append(data)
    }

    func finish(throwing error: Error) {
        continuation.finish(throwing: error)
    }

    func startCallCount() -> Int {
        startCalls
    }

    func shutdownCallCount() -> Int {
        shutdownCalls
    }

    func sendsCurrentlyInFlight() -> Int {
        sendsInFlight
    }

    func incomingCallCount() -> Int {
        incomingCalls
    }

    func sentMessageCount() -> Int {
        sentData.count
    }

    func standardErrorChunkCount() -> Int {
        stderrChunks.count
    }
}

actor NonCooperativeSendJSONRPCTransport: JSONRPCTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let sendObservedStream: AsyncStream<Void>
    private let sendObservedContinuation: AsyncStream<Void>.Continuation
    private let shutdownObservedStream: AsyncStream<Void>
    private let shutdownObservedContinuation: AsyncStream<Void>.Continuation
    private let returnsNormallyAfterShutdown: Bool
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var sentData: [Data] = []
    private var sendsInFlight = 0
    private var shutdownCalls = 0
    private var didShutdown = false

    init(returnsNormallyAfterShutdown: Bool = false) {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        let sendObservedPair = AsyncStream<Void>.makeStream()
        sendObservedStream = sendObservedPair.stream
        sendObservedContinuation = sendObservedPair.continuation
        let shutdownObservedPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        shutdownObservedStream = shutdownObservedPair.stream
        shutdownObservedContinuation = shutdownObservedPair.continuation
        self.returnsNormallyAfterShutdown = returnsNormallyAfterShutdown
    }

    func start() async throws {}

    func send(_ data: Data) async throws {
        guard !didShutdown else {
            throw JSONRPCError.transportClosed
        }
        sentData.append(data)
        sendsInFlight += 1
        sendObservedContinuation.yield()
        await withCheckedContinuation { continuation in
            sendWaiters.append(continuation)
        }
        sendsInFlight -= 1
        guard !didShutdown || returnsNormallyAfterShutdown else {
            throw JSONRPCError.transportClosed
        }
    }

    func incomingBytes() async -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func shutdown() async throws {
        guard !didShutdown else {
            return
        }
        didShutdown = true
        shutdownCalls += 1
        shutdownObservedContinuation.yield()
        continuation.finish()
        let waiters = sendWaiters
        sendWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func releaseSends() {
        let waiters = sendWaiters
        sendWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func dataSent(at index: Int) async throws -> Data {
        var iterator = sendObservedStream.makeAsyncIterator()
        while !sentData.indices.contains(index) {
            guard await iterator.next() != nil else {
                throw TransportTestProbeError.conditionNotReached(
                    "Message \(index) was not sent"
                )
            }
        }
        return sentData[index]
    }

    func waitUntilShutdownCalled() async throws {
        guard shutdownCalls == 0 else {
            return
        }
        var iterator = shutdownObservedStream.makeAsyncIterator()
        guard await iterator.next() != nil else {
            throw TransportTestProbeError.conditionNotReached(
                "Transport shutdown was not called"
            )
        }
    }

    func sentMessageCount() -> Int {
        sentData.count
    }

    func sendsCurrentlyInFlight() -> Int {
        sendsInFlight
    }

    func shutdownCallCount() -> Int {
        shutdownCalls
    }
}

enum TransportTestProbeError: Error {
    case conditionNotReached(String)
}

actor RecordingCodexTransportFactory: CodexProcessTransportFactory {
    let transport: FakeJSONRPCTransport
    private let suspendsCreation: Bool
    private let creationGate: AsyncStream<Void>
    private let creationGateContinuation: AsyncStream<Void>.Continuation
    private var configurations: [ManagedProcessConfiguration] = []
    private var creationCalls = 0

    init(
        transport: FakeJSONRPCTransport,
        suspendsCreation: Bool = false
    ) {
        self.transport = transport
        self.suspendsCreation = suspendsCreation
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        creationGate = pair.stream
        creationGateContinuation = pair.continuation
    }

    func makeTransport(
        configuration: ManagedProcessConfiguration
    ) async -> any JSONRPCTransport {
        creationCalls += 1
        configurations.append(configuration)
        if suspendsCreation {
            var iterator = creationGate.makeAsyncIterator()
            _ = await iterator.next()
        }
        return transport
    }

    func configuration(at index: Int) -> ManagedProcessConfiguration? {
        guard configurations.indices.contains(index) else {
            return nil
        }
        return configurations[index]
    }

    func creationCallCount() -> Int {
        creationCalls
    }

    func waitUntilCreationCalled(maximumYields: Int = 10_000) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if creationCalls > 0 {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Transport factory was not called"
        )
    }

    func releaseCreation() {
        creationGateContinuation.yield()
        creationGateContinuation.finish()
    }
}

struct ImmediateTimeoutScheduler: JSONRPCTimeoutScheduler {
    func wait(for duration: Duration) async throws {}
}

struct ControlledTimeoutScheduler: JSONRPCTimeoutScheduler {
    func wait(for duration: Duration) async throws {
        let pair = AsyncThrowingStream<Void, Error>.makeStream()
        try await withTaskCancellationHandler {
            var iterator = pair.stream.makeAsyncIterator()
            _ = try await iterator.next()
        } onCancel: {
            pair.continuation.finish(throwing: CancellationError())
        }
    }
}

actor ManualTimeoutScheduler: JSONRPCTimeoutScheduler {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let scheduledStream: AsyncStream<Void>
    private let scheduledContinuation: AsyncStream<Void>.Continuation
    private let completionStream: AsyncStream<Void>
    private let completionContinuation: AsyncStream<Void>.Continuation
    private var waitCalls = 0
    private var completedWaitCalls = 0
    private var durations: [Duration] = []

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        let scheduledPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        scheduledStream = scheduledPair.stream
        scheduledContinuation = scheduledPair.continuation
        let completionPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        completionStream = completionPair.stream
        completionContinuation = completionPair.continuation
    }

    func wait(for duration: Duration) async throws {
        waitCalls += 1
        durations.append(duration)
        scheduledContinuation.yield()
        defer {
            completedWaitCalls += 1
            completionContinuation.yield()
        }
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else {
            throw CancellationError()
        }
    }

    func waitUntilScheduled() async throws {
        guard waitCalls == 0 else {
            return
        }
        var iterator = scheduledStream.makeAsyncIterator()
        guard await iterator.next() != nil else {
            throw TransportTestProbeError.conditionNotReached(
                "Timeout was not scheduled"
            )
        }
    }

    func waitUntilWaitCompleted() async throws {
        guard completedWaitCalls == 0 else {
            return
        }
        var iterator = completionStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func fire() {
        continuation.yield()
    }

    func scheduledDurations() -> [Duration] {
        durations
    }
}

actor TrackedTaskState {
    private var began = false
    private var completed = false

    func markBegan() {
        began = true
    }

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }

    func waitUntilCompleted(maximumYields: Int = 100_000) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if completed {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Tracked task did not complete"
        )
    }

    func waitUntilBegan(maximumYields: Int = 10_000) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if began {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Tracked task did not begin"
        )
    }
}

func makeTrackedTask<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) -> (task: Task<T, Error>, state: TrackedTaskState) {
    let state = TrackedTaskState()
    let task = Task {
        await state.markBegan()
        do {
            let value = try await operation()
            await state.markCompleted()
            return value
        } catch {
            await state.markCompleted()
            throw error
        }
    }
    return (task, state)
}

func boundedValue<T: Sendable>(
    of tracked: (task: Task<T, Error>, state: TrackedTaskState)
) async throws -> T {
    do {
        try await tracked.state.waitUntilCompleted()
    } catch {
        tracked.task.cancel()
        throw error
    }
    return try await tracked.task.value
}

func boundedResult<T: Sendable>(
    of tracked: (task: Task<T, Error>, state: TrackedTaskState)
) async throws -> Result<T, Error> {
    do {
        try await tracked.state.waitUntilCompleted()
    } catch {
        tracked.task.cancel()
        throw error
    }
    return await tracked.task.result
}

struct TestOutboundMessage: Decodable {
    let id: JSONRPCRequestID?
    let method: String
    let params: JSONValue?
}

func decodeOutbound(_ data: Data) throws -> TestOutboundMessage {
    try JSONDecoder().decode(TestOutboundMessage.self, from: data)
}

func successResponse(id: JSONRPCRequestID, result: JSONValue) throws -> Data {
    var data = try JSONEncoder().encode(
        TestSuccessResponse(id: id, result: result)
    )
    data.append(0x0A)
    return data
}

func errorResponse(id: JSONRPCRequestID, code: Int, message: String) throws -> Data {
    var data = try JSONEncoder().encode(
        TestErrorResponse(
            id: id,
            error: .init(code: code, message: message)
        )
    )
    data.append(0x0A)
    return data
}

private struct TestSuccessResponse: Encodable {
    let id: JSONRPCRequestID
    let result: JSONValue
}

private struct TestErrorResponse: Encodable {
    struct Payload: Encodable {
        let code: Int
        let message: String
    }

    let id: JSONRPCRequestID
    let error: Payload
}
