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
    }

    private let transport: any JSONRPCTransport
    private let timeoutScheduler: any JSONRPCTimeoutScheduler
    private let maximumLineSize: Int
    private let maximumRequestSize: Int
    private let maximumBufferedNotifications: Int
    private let notificationStream: AsyncThrowingStream<JSONRPCNotification, Error>
    private let notificationContinuation:
        AsyncThrowingStream<JSONRPCNotification, Error>.Continuation

    private var state = State.idle
    private var lifecycleGeneration: UInt64 = 0
    private var nextRequestID: Int64 = 1
    private var pendingRequests: [JSONRPCRequestID: PendingRequest] = [:]
    private var receiveBuffer = Data()
    private var readerTask: Task<Void, Never>?
    private var transportShutdownTask:
        Task<Result<Void, JSONRPCError>, Never>?
    private var transportShutdownComplete = false

    public init(
        transport: any JSONRPCTransport,
        timeoutScheduler: any JSONRPCTimeoutScheduler =
            ContinuousJSONRPCTimeoutScheduler(),
        maximumLineSize: Int = 1_048_576,
        maximumRequestSize: Int = 1_048_576,
        maximumBufferedNotifications: Int = 100
    ) {
        self.transport = transport
        self.timeoutScheduler = timeoutScheduler
        self.maximumLineSize = max(1, maximumLineSize)
        self.maximumRequestSize = max(1, maximumRequestSize)
        self.maximumBufferedNotifications = max(1, maximumBufferedNotifications)
        let pair = AsyncThrowingStream<JSONRPCNotification, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(
                max(1, maximumBufferedNotifications)
            )
        )
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
    }

    public func start() async throws {
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

        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                throw JSONRPCError.requestCancelled(id)
            }
            pendingRequests[id] = PendingRequest(
                continuation: pair.continuation,
                timeoutTask: nil,
                deliveryUncertain: false
            )
            if let timeout {
                installTimeout(for: id, duration: timeout)
            }
            if Task.isCancelled {
                cancelRequest(id)
                throw JSONRPCError.requestCancelled(id)
            }

            if pendingRequests[id] != nil {
                pendingRequests[id]?.deliveryUncertain = true
                do {
                    try await transport.send(data)
                } catch {
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
        guard case .running = state else {
            throw state == .idle
                ? JSONRPCError.notInitialized
                : JSONRPCError.transportClosed
        }
        guard !Task.isCancelled else {
            throw JSONRPCError.transportClosed
        }

        let data = try JSONRPCMessageCodec.encodeNotification(
            method: method,
            params: params
        )
        guard data.count <= maximumRequestSize else {
            throw JSONRPCError.requestTooLarge(limit: maximumRequestSize)
        }
        do {
            try await transport.send(data)
        } catch {
            let transportError = normalizedTransportError(error)
            close(with: transportError)
            readerTask?.cancel()
            beginTransportShutdown()
            throw transportError
        }
    }

    public func notifications() -> AsyncThrowingStream<JSONRPCNotification, Error> {
        notificationStream
    }

    public func shutdown() async throws {
        close(with: JSONRPCError.transportClosed)
        let reader = readerTask
        reader?.cancel()
        beginTransportShutdown()

        do {
            try await awaitTransportShutdown()
        } catch {
            _ = await reader?.result
            throw error
        }
        _ = await reader?.result
        if readerTask != nil {
            readerTask = nil
        }
        receiveBuffer.removeAll(keepingCapacity: false)
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

    private func timeoutRequest(_ id: JSONRPCRequestID) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.continuation.finish(
            throwing: JSONRPCError.requestTimedOut(id)
        )
        if pending.deliveryUncertain {
            closeAfterUncertainDelivery()
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
        if pending.deliveryUncertain {
            closeAfterUncertainDelivery()
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
        closeAfterUncertainDelivery()
    }

    private func closeAfterUncertainDelivery() {
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
            let lineSize = receiveBuffer.distance(
                from: receiveBuffer.startIndex,
                to: newline
            )
            guard lineSize <= maximumLineSize else {
                throw JSONRPCError.responseTooLarge(limit: maximumLineSize)
            }

            var line = Data(receiveBuffer[..<newline])
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                try handle(JSONRPCMessageCodec.decodeIncoming(line))
            }
        }

        guard receiveBuffer.count <= maximumLineSize else {
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
            guard let pending = pendingRequests.removeValue(forKey: id) else {
                throw JSONRPCError.unknownResponseID(
                    id.sanitizedForErrorStorage
                )
            }
            pending.timeoutTask?.cancel()
            pending.continuation.yield(result)
            pending.continuation.finish()

        case .failure(let id, let code):
            guard let pending = pendingRequests.removeValue(forKey: id) else {
                throw JSONRPCError.unknownResponseID(
                    id.sanitizedForErrorStorage
                )
            }
            pending.timeoutTask?.cancel()
            pending.continuation.finish(
                throwing: JSONRPCError.remoteError(code: code)
            )
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

        if !receiveBuffer.isEmpty {
            do {
                guard receiveBuffer.count <= maximumLineSize else {
                    throw JSONRPCError.responseTooLarge(
                        limit: maximumLineSize
                    )
                }
                var line = receiveBuffer
                receiveBuffer.removeAll(keepingCapacity: false)
                if line.last == 0x0D {
                    line.removeLast()
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
        }

        close(with: error)
        beginTransportShutdown()
        try? await awaitTransportShutdown()
    }

    private func close(with error: JSONRPCError) {
        guard state != .closed else {
            return
        }
        state = .closed
        failAllPending(with: error)
        notificationContinuation.finish(throwing: error)
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

    private func failAllPending(with error: JSONRPCError) {
        let pending = pendingRequests.values
        pendingRequests.removeAll(keepingCapacity: false)
        for request in pending {
            request.timeoutTask?.cancel()
            request.continuation.finish(throwing: error)
        }
    }
}
