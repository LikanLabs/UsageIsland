import Foundation

public actor JSONRPCClient {
    private enum State: Equatable {
        case idle
        case starting(UInt64)
        case running(UInt64)
        case closed
    }

    private struct PendingRequest {
        let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
        var timeoutTask: Task<Void, Never>?
        var deliveryUncertain: Bool
        var bufferedOutcome: RequestOutcome?
    }

    private enum RequestOutcome {
        case success(JSONValue)
        case failure(code: Int)
    }

    private let transport: any JSONRPCTransport
    private let timeoutScheduler: any JSONRPCTimeoutScheduler
    private let maximumLineSize: Int
    private let maximumRequestSize: Int
    private let maximumBufferedNotifications: Int
    private let maximumPendingRequests: Int
    private let defaultRequestTimeout: Duration
    private let configurationError: JSONRPCError?
    private let notificationStream: AsyncThrowingStream<JSONRPCNotification, Error>
    private let notificationContinuation:
        AsyncThrowingStream<JSONRPCNotification, Error>.Continuation

    private var state = State.idle
    private var lifecycleGeneration: UInt64 = 0
    private var nextRequestID: Int64 = 1
    private var pendingRequests: [JSONRPCRequestID: PendingRequest] = [:]
    private var activeRequestSlots: Set<JSONRPCRequestID> = []
    private var nextSendToken: UInt64 = 1
    private var activeSendTokens: Set<UInt64> = []
    private var activeNotificationSendTokens: Set<UInt64> = []
    private var notificationSendErrors: [UInt64: JSONRPCError] = [:]
    private var sendQuiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var receiveBuffer = Data()
    private var readerTask: Task<Void, Never>?
    private var transportShutdownTask:
        Task<Result<Void, JSONRPCError>, Never>?
    private var transportShutdownComplete = false

    /// Creates a client with bounded resource usage. The configured limit
    /// defaults to 64 and independently bounds pending requests and active
    /// notification sends, rejecting excess work immediately without waiting.
    /// Every request and notification send uses a positive timeout, defaulting
    /// to 30 seconds; there is no infinite-wait mode.
    public init(
        transport: any JSONRPCTransport,
        timeoutScheduler: any JSONRPCTimeoutScheduler =
            ContinuousJSONRPCTimeoutScheduler(),
        maximumLineSize: Int = 1_048_576,
        maximumRequestSize: Int = 1_048_576,
        maximumBufferedNotifications: Int = 100,
        maximumPendingRequests: Int = 64,
        defaultRequestTimeout: Duration = .seconds(30)
    ) {
        self.transport = transport
        self.timeoutScheduler = timeoutScheduler
        self.maximumLineSize = max(1, maximumLineSize)
        self.maximumRequestSize = max(1, maximumRequestSize)
        self.maximumBufferedNotifications = max(1, maximumBufferedNotifications)
        self.maximumPendingRequests = maximumPendingRequests
        self.defaultRequestTimeout = defaultRequestTimeout
        if maximumPendingRequests <= 0 {
            configurationError = .invalidPendingRequestLimit
        } else if defaultRequestTimeout <= .zero {
            configurationError = .invalidRequestTimeout
        } else {
            configurationError = nil
        }
        let pair = AsyncThrowingStream<JSONRPCNotification, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(
                max(1, maximumBufferedNotifications)
            )
        )
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
        notificationContinuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else {
                return
            }
            Task { [weak self] in
                await self?.notificationStreamWasCancelled()
            }
        }
    }

    public func start() async throws {
        if let configurationError {
            close(with: configurationError)
            throw configurationError
        }
        try checkStartupCancellation()
        switch state {
        case .idle:
            break
        case .starting, .running:
            throw JSONRPCError.alreadyInitialized
        case .closed:
            throw JSONRPCError.transportClosed
        }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        state = .starting(generation)
        do {
            try checkStartupCancellation()
            try await transport.start()
            try checkStartupCancellation()
            guard isStarting(generation) else {
                throw JSONRPCError.transportClosed
            }

            try checkStartupCancellation()
            let incomingBytes = await transport.incomingBytes()
            try checkStartupCancellation()
            guard isStarting(generation) else {
                throw JSONRPCError.transportClosed
            }

            state = .running(generation)
            readerTask = Task { [weak self] in
                do {
                    for try await chunk in incomingBytes {
                        guard !Task.isCancelled else {
                            return
                        }
                        try await self?.consume(chunk)
                    }
                    await self?.readerEnded(
                        with: JSONRPCError.transportClosed,
                        generation: generation
                    )
                } catch is CancellationError {
                    return
                } catch let error as JSONRPCError {
                    await self?.readerEnded(
                        with: error,
                        generation: generation
                    )
                } catch {
                    await self?.readerEnded(
                        with: JSONRPCError.transportClosed,
                        generation: generation
                    )
                }
            }
        } catch {
            let startupError = normalizedStartupError(error)
            if isStarting(generation) {
                close(with: startupError)
            }
            beginTransportShutdown()
            try? await awaitTransportShutdown()
            throw startupError
        }
    }

    /// Sends one request or rejects it immediately when the configured cap is
    /// full. A nil timeout uses the configured positive default, which itself
    /// defaults to 30 seconds; nil never means infinity.
    public func request(
        method: String,
        params: JSONValue? = nil,
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        guard case .running = state else {
            throw state == .idle
                ? JSONRPCError.notInitialized
                : JSONRPCError.transportClosed
        }
        guard !Task.isCancelled else {
            throw JSONRPCError.requestCancelled(.integer(0))
        }
        let effectiveTimeout = timeout ?? defaultRequestTimeout
        guard effectiveTimeout > .zero else {
            throw JSONRPCError.invalidRequestTimeout
        }
        guard activeRequestSlots.count < maximumPendingRequests else {
            throw JSONRPCError.pendingRequestLimitExceeded(
                limit: maximumPendingRequests
            )
        }

        let id = try allocateRequestID()
        let data = try JSONRPCMessageCodec.encodeRequest(
            id: id,
            method: method,
            params: params
        )
        guard data.count <= maximumRequestSize else {
            throw JSONRPCError.requestTooLarge(limit: maximumRequestSize)
        }
        let pair = AsyncThrowingStream<JSONValue, Error>.makeStream()
        activeRequestSlots.insert(id)
        defer {
            releaseRequestSlot(id)
        }

        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                throw JSONRPCError.requestCancelled(id)
            }
            pendingRequests[id] = PendingRequest(
                continuation: pair.continuation,
                timeoutTask: nil,
                deliveryUncertain: false,
                bufferedOutcome: nil
            )
            installTimeout(for: id, duration: effectiveTimeout)
            if Task.isCancelled {
                cancelRequest(id)
                throw JSONRPCError.requestCancelled(id)
            }

            if pendingRequests[id] != nil {
                pendingRequests[id]?.deliveryUncertain = true
                let sendToken = beginActiveSend()
                do {
                    try await transport.send(data)
                    finishActiveSend(sendToken)
                    if Task.isCancelled {
                        cancelRequest(id)
                    } else {
                        settleRequestSend(id)
                    }
                } catch {
                    finishActiveSend(sendToken)
                    if Task.isCancelled {
                        cancelRequest(id)
                    } else {
                        failUncertainSend(
                            id,
                            with: normalizedTransportError(error)
                        )
                    }
                }
            }

            var iterator = pair.stream.makeAsyncIterator()
            do {
                guard let result = try await iterator.next() else {
                    if Task.isCancelled {
                        cancelRequest(id)
                        throw JSONRPCError.requestCancelled(id)
                    }
                    throw JSONRPCError.transportClosed
                }
                return result
            } catch is CancellationError {
                cancelRequest(id)
                throw JSONRPCError.requestCancelled(id)
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(id)
            }
        }
    }

    public func sendNotification(
        method: String,
        params: JSONValue? = nil
    ) async throws {
        guard case .running(let generation) = state else {
            throw state == .idle
                ? JSONRPCError.notInitialized
                : JSONRPCError.transportClosed
        }
        guard !Task.isCancelled else {
            throw JSONRPCError.transportClosed
        }
        guard activeNotificationSendTokens.count < maximumPendingRequests else {
            throw JSONRPCError.notificationSendLimitExceeded(
                limit: maximumPendingRequests
            )
        }

        let data = try JSONRPCMessageCodec.encodeNotification(
            method: method,
            params: params
        )
        guard data.count <= maximumRequestSize else {
            throw JSONRPCError.requestTooLarge(limit: maximumRequestSize)
        }
        let sendToken = beginActiveSend()
        activeNotificationSendTokens.insert(sendToken)
        let timeoutTask = installNotificationTimeout(
            for: sendToken,
            duration: defaultRequestTimeout
        )
        defer {
            timeoutTask.cancel()
            notificationSendErrors.removeValue(forKey: sendToken)
            activeNotificationSendTokens.remove(sendToken)
            finishActiveSend(sendToken)
        }
        try await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                cancelNotificationSend(sendToken)
                throw JSONRPCError.transportClosed
            }
            do {
                try await transport.send(data)
            } catch {
                if let terminalError = notificationSendErrors[sendToken] {
                    throw terminalError
                }
                let transportError = normalizedTransportError(error)
                close(with: transportError)
                readerTask?.cancel()
                beginTransportShutdown()
                throw transportError
            }
            if Task.isCancelled {
                cancelNotificationSend(sendToken)
            }
            if let terminalError = notificationSendErrors[sendToken] {
                throw terminalError
            }
            guard case .running(let activeGeneration) = state,
                  activeGeneration == generation else {
                throw JSONRPCError.transportClosed
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelNotificationSend(sendToken)
            }
        }
    }

    /// Returns one bounded stream shared by all callers. Iterators compete for
    /// events; this API intentionally does not provide broadcast delivery.
    /// Cancelling an iterator terminates the only channel and fails the client
    /// closed, preventing notifications from being silently discarded.
    public func notifications() -> AsyncThrowingStream<JSONRPCNotification, Error> {
        notificationStream
    }

    func waitForActiveSendQuiescence() async {
        guard !activeSendTokens.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            if activeSendTokens.isEmpty {
                continuation.resume()
            } else {
                sendQuiescenceWaiters.append(continuation)
            }
        }
    }

    public func shutdown() async throws {
        close(with: JSONRPCError.transportClosed)
        let reader = readerTask
        reader?.cancel()
        beginTransportShutdown()

        var shutdownError: JSONRPCError?
        do {
            try await awaitTransportShutdown()
        } catch {
            shutdownError = normalizedTransportError(error)
        }
        _ = await reader?.result
        await waitForQuiescence()
        if readerTask != nil {
            readerTask = nil
        }
        receiveBuffer.removeAll(keepingCapacity: false)
        if let shutdownError {
            throw shutdownError
        }
    }

    private func allocateRequestID() throws -> JSONRPCRequestID {
        guard nextRequestID < Int64.max else {
            throw JSONRPCError.transportClosed
        }
        defer { nextRequestID += 1 }
        return .integer(nextRequestID)
    }

    private func installTimeout(
        for id: JSONRPCRequestID,
        duration: Duration
    ) {
        let scheduler = timeoutScheduler
        let timeoutTask = Task { [weak self] in
            do {
                try await scheduler.wait(for: duration)
                guard !Task.isCancelled else {
                    return
                }
                await self?.timeoutRequest(id)
            } catch {
                return
            }
        }

        if pendingRequests[id] != nil {
            pendingRequests[id]?.timeoutTask = timeoutTask
        } else {
            timeoutTask.cancel()
        }
    }

    private func installNotificationTimeout(
        for token: UInt64,
        duration: Duration
    ) -> Task<Void, Never> {
        let scheduler = timeoutScheduler
        return Task { [weak self] in
            do {
                try await scheduler.wait(for: duration)
                guard !Task.isCancelled else {
                    return
                }
                await self?.timeoutNotificationSend(token)
            } catch {
                return
            }
        }
    }

    private func settleRequestSend(_ id: JSONRPCRequestID) {
        guard var pending = pendingRequests[id] else {
            return
        }
        pending.deliveryUncertain = false
        guard let outcome = pending.bufferedOutcome else {
            pendingRequests[id] = pending
            return
        }
        pendingRequests.removeValue(forKey: id)
        complete(pending, with: outcome)
    }

    private func timeoutRequest(_ id: JSONRPCRequestID) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.continuation.finish(
            throwing: JSONRPCError.requestTimedOut(id)
        )
        if pending.deliveryUncertain {
            closeFailClosed()
        }
    }

    private func cancelRequest(_ id: JSONRPCRequestID) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask?.cancel()
        pending.continuation.finish(
            throwing: JSONRPCError.requestCancelled(id)
        )
        closeFailClosed()
    }

    private func receive(
        _ outcome: RequestOutcome,
        for id: JSONRPCRequestID
    ) throws {
        guard var pending = pendingRequests[id] else {
            if isPreviouslyAllocatedRequestID(id) {
                return
            }
            throw JSONRPCError.unknownResponseID(
                id.sanitizedForErrorStorage
            )
        }
        guard pending.bufferedOutcome == nil else {
            return
        }
        if pending.deliveryUncertain {
            pending.bufferedOutcome = outcome
            pendingRequests[id] = pending
            return
        }
        pendingRequests.removeValue(forKey: id)
        complete(pending, with: outcome)
    }

    private func complete(
        _ pending: PendingRequest,
        with outcome: RequestOutcome
    ) {
        pending.timeoutTask?.cancel()
        switch outcome {
        case .success(let result):
            pending.continuation.yield(result)
            pending.continuation.finish()
        case .failure(let code):
            pending.continuation.finish(
                throwing: JSONRPCError.remoteError(code: code)
            )
        }
    }

    private func failUncertainSend(
        _ id: JSONRPCRequestID,
        with error: JSONRPCError
    ) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask?.cancel()
        pending.continuation.finish(throwing: error)
        closeFailClosed()
    }

    private func closeFailClosed() {
        close(with: JSONRPCError.transportClosed)
        readerTask?.cancel()
        beginTransportShutdown()
    }


    private func consume(_ chunk: Data) throws {
        guard case .running = state else {
            return
        }

        receiveBuffer.append(chunk)
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let rawLineSize = receiveBuffer.distance(
                from: receiveBuffer.startIndex,
                to: newline
            )
            let hasCarriageReturn = rawLineSize > 0
                && receiveBuffer[receiveBuffer.index(before: newline)] == 0x0D
            let lineSize = rawLineSize - (hasCarriageReturn ? 1 : 0)
            guard lineSize <= maximumLineSize else {
                receiveBuffer.removeAll(keepingCapacity: false)
                throw JSONRPCError.responseTooLarge(limit: maximumLineSize)
            }

            var line = Data(receiveBuffer[..<newline])
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                do {
                    try handle(JSONRPCMessageCodec.decodeIncoming(line))
                } catch {
                    receiveBuffer.removeAll(keepingCapacity: false)
                    throw error
                }
            }
        }

        guard lineSizeExcludingOptionalCarriageReturn(receiveBuffer)
            <= maximumLineSize else {
            throw JSONRPCError.responseTooLarge(limit: maximumLineSize)
        }
    }

    private func handle(_ message: JSONRPCIncomingMessage) throws {
        switch message {
        case .notification(let notification):
            switch notificationContinuation.yield(notification) {
            case .enqueued:
                break
            case .dropped:
                throw JSONRPCError.notificationBufferOverflow(
                    limit: maximumBufferedNotifications
                )
            case .terminated:
                break
            @unknown default:
                throw JSONRPCError.transportClosed
            }

        case .success(let id, let result):
            try receive(.success(result), for: id)

        case .failure(let id, let code):
            try receive(.failure(code: code), for: id)
        }
    }

    private func readerEnded(
        with error: JSONRPCError,
        generation: UInt64
    ) async {
        guard case .running(let activeGeneration) = state,
              activeGeneration == generation else {
            return
        }

        if !receiveBuffer.isEmpty, isCleanTransportEOF(error) {
            do {
                var line = receiveBuffer
                receiveBuffer.removeAll(keepingCapacity: false)
                if line.last == 0x0D {
                    line.removeLast()
                }
                guard line.count <= maximumLineSize else {
                    throw JSONRPCError.responseTooLarge(
                        limit: maximumLineSize
                    )
                }
                if !line.isEmpty {
                    try handle(JSONRPCMessageCodec.decodeIncoming(line))
                }
            } catch let terminalError as JSONRPCError {
                close(with: terminalError)
                beginTransportShutdown()
                try? await awaitTransportShutdown()
                return
            } catch {
                close(with: JSONRPCError.malformedJSON)
                beginTransportShutdown()
                try? await awaitTransportShutdown()
                return
            }
        } else if !isCleanTransportEOF(error) {
            receiveBuffer.removeAll(keepingCapacity: false)
        }

        close(with: error)
        beginTransportShutdown()
        try? await awaitTransportShutdown()
    }

    private func isCleanTransportEOF(_ error: JSONRPCError) -> Bool {
        if case .transportClosed = error {
            return true
        }
        return false
    }

    private func close(with error: JSONRPCError) {
        guard state != .closed else {
            return
        }
        state = .closed
        failAllPending(with: error)
        notificationContinuation.finish(throwing: error)
        resumeSendQuiescenceWaitersIfNeeded()
    }

    private func notificationStreamWasCancelled() {
        guard state != .closed else {
            return
        }
        close(with: JSONRPCError.transportClosed)
        readerTask?.cancel()
        beginTransportShutdown()
    }

    private func cancelNotificationSend(_ token: UInt64) {
        guard activeSendTokens.contains(token),
              notificationSendErrors[token] == nil else {
            return
        }
        notificationSendErrors[token] = .transportClosed
        close(with: JSONRPCError.transportClosed)
        readerTask?.cancel()
        beginTransportShutdown()
    }

    private func timeoutNotificationSend(_ token: UInt64) {
        guard activeSendTokens.contains(token),
              notificationSendErrors[token] == nil else {
            return
        }
        notificationSendErrors[token] = .notificationTimedOut
        close(with: JSONRPCError.transportClosed)
        readerTask?.cancel()
        beginTransportShutdown()
    }

    private func beginTransportShutdown() {
        guard !transportShutdownComplete,
              transportShutdownTask == nil else {
            return
        }
        let transport = self.transport
        transportShutdownTask = Task {
            do {
                try await transport.shutdown()
                return .success(())
            } catch let error as JSONRPCError {
                return .failure(error)
            } catch {
                return .failure(JSONRPCError.transportClosed)
            }
        }
    }

    private func awaitTransportShutdown() async throws {
        if transportShutdownComplete {
            return
        }
        beginTransportShutdown()
        guard let task = transportShutdownTask else {
            return
        }

        switch await task.value {
        case .success:
            transportShutdownComplete = true
            transportShutdownTask = nil
        case .failure(let error):
            transportShutdownTask = nil
            throw error
        }
    }

    private func checkStartupCancellation() throws {
        guard !Task.isCancelled else {
            throw JSONRPCError.startupCancelled
        }
    }

    private func normalizedStartupError(_ error: Error) -> JSONRPCError {
        if Task.isCancelled || error is CancellationError {
            return .startupCancelled
        }
        return normalizedTransportError(error)
    }

    private func normalizedTransportError(_ error: Error) -> JSONRPCError {
        if let error = error as? JSONRPCError {
            return error
        }
        return .transportClosed
    }

    private func isStarting(_ generation: UInt64) -> Bool {
        guard case .starting(let activeGeneration) = state else {
            return false
        }
        return activeGeneration == generation
    }

    private func isPreviouslyAllocatedRequestID(
        _ id: JSONRPCRequestID
    ) -> Bool {
        guard case .integer(let value) = id else {
            return false
        }
        return value > 0 && value < nextRequestID
    }

    private func beginActiveSend() -> UInt64 {
        let token = nextSendToken
        nextSendToken &+= 1
        if nextSendToken == 0 {
            nextSendToken = 1
        }
        activeSendTokens.insert(token)
        return token
    }

    private func finishActiveSend(_ token: UInt64) {
        activeSendTokens.remove(token)
        // A waiter resumes on this actor only after the current turn finishes.
        // Request send settlement therefore completes before the barrier returns.
        resumeSendQuiescenceWaitersIfNeeded()
        resumeQuiescenceWaitersIfNeeded()
    }

    private func resumeSendQuiescenceWaitersIfNeeded() {
        guard activeSendTokens.isEmpty else {
            return
        }
        let waiters = sendQuiescenceWaiters
        sendQuiescenceWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func releaseRequestSlot(_ id: JSONRPCRequestID) {
        activeRequestSlots.remove(id)
        resumeQuiescenceWaitersIfNeeded()
    }

    private func waitForQuiescence() async {
        guard !activeRequestSlots.isEmpty || !activeSendTokens.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            if activeRequestSlots.isEmpty && activeSendTokens.isEmpty {
                continuation.resume()
            } else {
                quiescenceWaiters.append(continuation)
            }
        }
    }

    private func resumeQuiescenceWaitersIfNeeded() {
        guard activeRequestSlots.isEmpty,
              activeSendTokens.isEmpty else {
            return
        }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func lineSizeExcludingOptionalCarriageReturn(
        _ data: Data
    ) -> Int {
        data.count - (data.last == 0x0D ? 1 : 0)
    }

    private func failAllPending(with error: JSONRPCError) {
        let pending = pendingRequests.values
        pendingRequests.removeAll(keepingCapacity: false)
        for request in pending {
            request.timeoutTask?.cancel()
            request.continuation.finish(throwing: error)
        }
    }
}
