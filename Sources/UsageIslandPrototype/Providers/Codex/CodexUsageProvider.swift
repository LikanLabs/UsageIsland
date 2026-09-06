import Foundation

protocol CodexUsageClient: Sendable {
    func start() async throws
    func request(method: String, params: JSONValue?) async throws -> JSONValue
    func shutdown() async throws
}

extension CodexAppServerClient: CodexUsageClient {}

actor CodexUsageProvider: UsageProvider {
    nonisolated let id: ProviderID = .codex

    private enum State: Sendable {
        case idle
        case starting(UUID)
        case started
        case failed(CodexUsageError)
        case stopped
    }

    private struct StartupAttempt: Sendable {
        let id: UUID
        let completion: CodexUsageStartupCompletion
        let task: Task<Void, Never>
    }

    private struct ActiveFetch: Sendable {
        let id: UUID
        let task: Task<UsageSnapshot, Error>
    }

    private struct ShutdownAttempt: Sendable {
        let id: UUID
        let task: Task<Result<Void, CodexUsageError>, Never>
    }

    private var client: any CodexUsageClient
    private let makeReplacementClient: (@Sendable () -> any CodexUsageClient)?
    private var needsRecovery = false
    private let clock: any UsageClock
    private let gate: CodexUsageFetchGate
    private let beforeReturningSnapshot: @Sendable () async throws -> Void
    private let didJoinShutdown: @Sendable () async -> Void

    private var state = State.idle
    private var startupAttempt: StartupAttempt?
    private var activeFetch: ActiveFetch?
    private var shutdownAttempt: ShutdownAttempt?
    private var shutdownComplete = false

    init(
        configuration: CodexAppServerConfiguration,
        clock: any UsageClock = SystemUsageClock()
    ) {
        client = CodexAppServerClient(configuration: configuration)
        makeReplacementClient = { CodexAppServerClient(configuration: configuration) }
        self.clock = clock
        gate = CodexUsageFetchGate()
        beforeReturningSnapshot = {}
        didJoinShutdown = {}
    }

    init(
        client: any CodexUsageClient,
        clock: any UsageClock,
        gate: CodexUsageFetchGate = CodexUsageFetchGate(),
        makeReplacementClient: (@Sendable () -> any CodexUsageClient)? = nil,
        beforeReturningSnapshot: @escaping @Sendable () async throws -> Void = {},
        didJoinShutdown: @escaping @Sendable () async -> Void = {}
    ) {
        self.client = client
        self.makeReplacementClient = makeReplacementClient
        self.clock = clock
        self.gate = gate
        self.beforeReturningSnapshot = beforeReturningSnapshot
        self.didJoinShutdown = didJoinShutdown
    }

    func fetchUsage() async throws -> UsageSnapshot {
        try checkAvailable()
        try await gate.acquire()

        var ownsPermit = true
        var fetchID: UUID?
        do {
            try checkAvailable()
            try await recoverIfNeeded()
            try await ensureStarted()
            try Task.checkCancellation()
            try checkAvailable()

            let id = UUID()
            fetchID = id
            let task = makeFetchTask()
            activeFetch = ActiveFetch(id: id, task: task)

            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try await beforeReturningSnapshot()
            try Task.checkCancellation()

            finishFetch(id)
            await gate.release()
            ownsPermit = false
            try Task.checkCancellation()
            try checkAvailable()
            return snapshot
        } catch {
            let normalized = Self.normalized(error)
            // Cancelling an in-flight JSON-RPC request closes its transport.
            // Normalization deliberately exposes CancellationError to callers,
            // but the next refresh must still retire that client. Cancellation
            // while waiting for startup/the gate does not invalidate a client.
            if makeReplacementClient != nil, normalized is CancellationError,
               let fetchID, activeFetch?.id == fetchID {
                needsRecovery = true
            }
            if makeReplacementClient != nil,
               let failure = normalized as? CodexUsageError,
               case .appServerFailure = failure {
                needsRecovery = true
            }
            if let fetchID {
                finishFetch(fetchID)
            }
            if ownsPermit {
                await gate.release()
                ownsPermit = false
            }
            throw normalized
        }
    }

    func shutdown() async throws {
        state = .stopped
        startupAttempt?.task.cancel()
        activeFetch?.task.cancel()

        if shutdownComplete {
            return
        }

        let attempt: ShutdownAttempt
        if let shutdownAttempt {
            attempt = shutdownAttempt
        } else {
            let id = UUID()
            let task = Task<Result<Void, CodexUsageError>, Never> {
                [client, gate] in
                await gate.stop()
                let result: Result<Void, CodexUsageError>
                do {
                    try await client.shutdown()
                    result = .success(())
                } catch {
                    result = .failure(Self.sanitizedAppServerError(error))
                }
                self.completeShutdownAttempt(id: id, result: result)
                return result
            }
            attempt = ShutdownAttempt(id: id, task: task)
            shutdownAttempt = attempt
        }

        await didJoinShutdown()
        switch await attempt.task.value {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    /// Runs under the fetch gate. Retire the old process before constructing a new
    /// client, so each retry performs its own initialize/initialized handshake.
    private func recoverIfNeeded() async throws {
        guard needsRecovery, let makeReplacementClient else { return }
        try await client.shutdown()
        try Task.checkCancellation()
        if case .stopped = state { throw CodexUsageError.stopped }
        client = makeReplacementClient()
        startupAttempt = nil
        shutdownComplete = false
        needsRecovery = false
        state = .idle
    }

    private func ensureStarted() async throws {
        let attempt: StartupAttempt
        switch state {
        case .started:
            return
        case .stopped:
            throw CodexUsageError.stopped
        case .failed(let error):
            throw error
        case .starting(let id):
            guard let current = startupAttempt, current.id == id else {
                throw CodexUsageError.appServerFailure(.startup)
            }
            attempt = current
        case .idle:
            let id = UUID()
            let completion = CodexUsageStartupCompletion()
            let task = Task<Void, Never> { [client] in
                let result: Result<Void, CodexUsageError>
                do {
                    try await client.start()
                    result = .success(())
                } catch {
                    result = .failure(Self.sanitizedAppServerError(error))
                }
                await completion.complete(with: result)
            }
            attempt = StartupAttempt(id: id, completion: completion, task: task)
            startupAttempt = attempt
            state = .starting(id)
        }

        do {
            try await attempt.completion.wait()
            try Task.checkCancellation()
            if case .starting(let id) = state, id == attempt.id {
                startupAttempt = nil
                state = .started
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if case .stopped = state {
                throw CodexUsageError.stopped
            }
            let normalized = Self.sanitizedAppServerError(error)
            if case .starting(let id) = state, id == attempt.id {
                startupAttempt = nil
                state = .failed(normalized)
            }
            throw normalized
        }
    }

    private func makeFetchTask() -> Task<UsageSnapshot, Error> {
        Task { [client, clock] in
            do {
                try Task.checkCancellation()
                let account = try await client.request(
                    method: "account/read",
                    params: .object(["refreshToken": .bool(false)])
                )
                try Task.checkCancellation()
                try CodexUsageMapper.validateAccount(account)

                let rateLimits = try await client.request(
                    method: "account/rateLimits/read",
                    params: nil
                )
                try Task.checkCancellation()
                return try CodexUsageMapper.mapRateLimits(
                    rateLimits,
                    capturedAt: clock.now()
                )
            } catch {
                throw Self.normalized(error)
            }
        }
    }

    private func checkAvailable() throws {
        switch state {
        case .stopped:
            throw CodexUsageError.stopped
        case .failed(let error):
            if !needsRecovery { throw error }
        default:
            return
        }
    }

    private func finishFetch(_ id: UUID) {
        guard activeFetch?.id == id else {
            return
        }
        activeFetch = nil
    }

    private func completeShutdownAttempt(
        id: UUID,
        result: Result<Void, CodexUsageError>
    ) {
        guard shutdownAttempt?.id == id else {
            return
        }
        shutdownAttempt = nil
        if case .success = result {
            shutdownComplete = true
        }
    }

    private static func normalized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        if let error = error as? CodexUsageError {
            return error
        }
        return sanitizedAppServerError(error)
    }

    private static func sanitizedAppServerError(_ error: Error) -> CodexUsageError {
        if let error = error as? CodexUsageError {
            return error
        }
        guard let error = error as? JSONRPCError else {
            return .appServerFailure(.transport)
        }

        let failure: CodexAppServerFailure
        switch error {
        case .executableNotFound, .processLaunchFailed:
            failure = .executableUnavailable
        case .alreadyInitialized, .notInitialized, .startupCancelled:
            failure = .startup
        case .requestTimedOut, .notificationTimedOut,
             .processTerminationTimedOut:
            failure = .timeout
        case .pendingRequestLimitExceeded,
             .notificationSendLimitExceeded,
             .processInputBufferOverflow,
             .requestTooLarge,
             .responseTooLarge,
             .transportBufferOverflow,
             .notificationBufferOverflow:
            failure = .capacity
        case .malformedJSON, .missingResponsePayload,
             .invalidInitializeResponse, .unknownResponseID,
             .invalidPendingRequestLimit, .invalidRequestTimeout:
            failure = .protocolViolation
        case .remoteError:
            failure = .remote
        case .processExited, .processTerminationFailed,
             .requestCancelled, .transportClosed:
            failure = .transport
        }
        return .appServerFailure(failure)
    }
}

actor CodexUsageFetchGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Result<Void, Error>, Never>
    }

    private var isLocked = false
    private var isStopped = false
    private var waiters: [Waiter] = []
    private var queueObservers: [CheckedContinuation<Void, Never>] = []
    private let beforeRelease: @Sendable () async -> Void
    private var releaseCount = 0

    init(beforeRelease: @escaping @Sendable () async -> Void = {}) {
        self.beforeRelease = beforeRelease
    }

    func acquire(
        afterHandoff: (@Sendable () async -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard !isStopped else {
            throw CodexUsageError.stopped
        }
        guard isLocked else {
            isLocked = true
            return
        }

        let id = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                resumeQueueObservers()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        try result.get()
        if let afterHandoff {
            await afterHandoff()
        }
        do {
            try Task.checkCancellation()
        } catch {
            releasePermit()
            throw error
        }
    }

    func release() async {
        await beforeRelease()
        releasePermit()
        releaseCount += 1
    }

    func completedReleaseCount() -> Int {
        releaseCount
    }

    private func releasePermit() {
        guard isLocked else {
            return
        }
        guard !isStopped else {
            isLocked = false
            return
        }
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().continuation.resume(returning: .success(()))
        }
    }

    func stop() {
        isStopped = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(
                returning: .failure(CodexUsageError.stopped)
            )
        }
    }

    func waitUntilQueued() async {
        guard waiters.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            queueObservers.append(continuation)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: .failure(CancellationError()))
    }

    private func resumeQueueObservers() {
        let observers = queueObservers
        queueObservers.removeAll()
        observers.forEach { $0.resume() }
    }
}

private actor CodexUsageStartupCompletion {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Result<Void, Error>, Never>
    }

    private var result: Result<Void, CodexUsageError>?
    private var waiters: [Waiter] = []

    func wait() async throws {
        try Task.checkCancellation()
        if let result {
            try result.get()
            return
        }

        let id = UUID()
        let waiterResult = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        try waiterResult.get()
        try Task.checkCancellation()
    }

    func complete(with result: Result<Void, CodexUsageError>) {
        guard self.result == nil else {
            return
        }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            switch result {
            case .success:
                waiter.continuation.resume(returning: .success(()))
            case .failure(let error):
                waiter.continuation.resume(returning: .failure(error))
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(
            returning: .failure(CancellationError())
        )
    }
}
