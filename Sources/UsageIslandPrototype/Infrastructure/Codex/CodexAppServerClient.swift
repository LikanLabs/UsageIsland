import Foundation

struct CodexInitializeResponse: Sendable {
    private let codexHome: String
    private let platformFamily: String
    private let platformOs: String
    private let userAgent: String

    init(validating value: JSONValue) throws {
        guard case .object(let object) = value,
              case .string(let codexHome) = object["codexHome"],
              case .string(let platformFamily) = object["platformFamily"],
              case .string(let platformOs) = object["platformOs"],
              case .string(let userAgent) = object["userAgent"] else {
            throw JSONRPCError.invalidInitializeResponse
        }
        self.codexHome = codexHome
        self.platformFamily = platformFamily
        self.platformOs = platformOs
        self.userAgent = userAgent
    }
}

public actor CodexAppServerClient {
    private enum State: Equatable {
        case idle
        case initializing(UInt64)
        case ready(UInt64)
        case stopped
    }

    private let configuration: CodexAppServerConfiguration
    private let transportFactory: any CodexProcessTransportFactory
    private let timeoutScheduler: any JSONRPCTimeoutScheduler

    private var state = State.idle
    private var lifecycleGeneration: UInt64 = 0
    private var rpcClient: JSONRPCClient?
    private var startupTransport: (any JSONRPCTransport)?
    private var startupInFlight = false
    private var startupCompletionWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    private var shutdownTask: Task<Result<Void, JSONRPCError>, Never>?
    private var shutdownComplete = false

    public init(
        configuration: CodexAppServerConfiguration,
        transportFactory: any CodexProcessTransportFactory =
            ManagedCodexProcessTransportFactory(),
        timeoutScheduler: any JSONRPCTimeoutScheduler =
            ContinuousJSONRPCTimeoutScheduler()
    ) {
        self.configuration = configuration
        self.transportFactory = transportFactory
        self.timeoutScheduler = timeoutScheduler
    }

    public func start() async throws {
        try checkStartupCancellation()
        guard state == .idle else {
            throw state == .stopped
                ? JSONRPCError.transportClosed
                : JSONRPCError.alreadyInitialized
        }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        state = .initializing(generation)
        startupInFlight = true
        defer {
            completeStartup()
        }
        var createdClient: JSONRPCClient?

        do {
            try validateStartup(generation)
            let processConfiguration = ManagedProcessConfiguration(
                executableURL: configuration.executableURL,
                arguments: ["app-server"],
                maximumInputWriteSize: configuration.maximumLineSize,
                maximumPendingInputBytes: configuration.maximumLineSize
            )
            let transport = try await transportFactory.makeTransport(
                configuration: processConfiguration
            )
            startupTransport = transport
            shutdownComplete = false
            try validateStartup(generation)

            let client = JSONRPCClient(
                transport: transport,
                timeoutScheduler: timeoutScheduler,
                maximumLineSize: configuration.maximumLineSize,
                maximumRequestSize: configuration.maximumLineSize,
                maximumBufferedNotifications:
                    configuration.maximumBufferedNotifications
            )
            createdClient = client
            rpcClient = client
            startupTransport = nil

            try validateStartup(generation)
            try await client.start()
            try validateStartup(generation)

            try validateStartup(generation)
            let initializeResult: JSONValue
            do {
                initializeResult = try await client.request(
                    method: "initialize",
                    params: .object([
                        "clientInfo": .object([
                            "name": .string("Usage Island"),
                            "version": .string(configuration.clientVersion)
                        ])
                    ]),
                    timeout: configuration.requestTimeout
                )
            } catch JSONRPCError.missingResponsePayload {
                throw JSONRPCError.invalidInitializeResponse
            }
            _ = try CodexInitializeResponse(validating: initializeResult)
            try validateStartup(generation)

            try validateStartup(generation)
            try await client.sendNotification(method: "initialized")
            try validateStartup(generation)
            state = .ready(generation)
        } catch {
            let startupError = normalizedStartupError(error)
            if isInitializing(generation) {
                state = .stopped
            }
            if let createdClient {
                do {
                    try await createdClient.shutdown()
                    rpcClient = nil
                } catch {
                    rpcClient = createdClient
                    shutdownComplete = false
                }
            } else if let startupTransport {
                do {
                    try await startupTransport.shutdown()
                    self.startupTransport = nil
                } catch {
                    shutdownComplete = false
                }
            }
            throw startupError
        }
    }

    public func request(
        method: String,
        params: JSONValue? = nil
    ) async throws -> JSONValue {
        guard case .ready = state, let rpcClient else {
            throw state == .stopped
                ? JSONRPCError.transportClosed
                : JSONRPCError.notInitialized
        }
        return try await rpcClient.request(
            method: method,
            params: params,
            timeout: configuration.requestTimeout
        )
    }

    public func notifications() async throws ->
        AsyncThrowingStream<JSONRPCNotification, Error> {
        guard case .ready(let generation) = state, let rpcClient else {
            throw state == .stopped
                ? JSONRPCError.transportClosed
                : JSONRPCError.notInitialized
        }
        let notifications = await rpcClient.notifications()
        guard state == .ready(generation) else {
            throw JSONRPCError.transportClosed
        }
        return notifications
    }

    public func shutdown() async throws {
        state = .stopped
        if shutdownComplete {
            return
        }
        if let shutdownTask {
            try await resolveShutdownTask(shutdownTask)
            return
        }

        guard startupInFlight || rpcClient != nil || startupTransport != nil
        else {
            shutdownComplete = true
            return
        }

        let task = Task<Result<Void, JSONRPCError>, Never> { [self] in
            do {
                try await performShutdown()
                return .success(())
            } catch let error as JSONRPCError {
                return .failure(error)
            } catch {
                return .failure(JSONRPCError.transportClosed)
            }
        }
        shutdownTask = task
        try await resolveShutdownTask(task)
    }

    private func performShutdown() async throws {
        let startupWasInFlight = startupInFlight
        do {
            try await shutdownCurrentResources()
        } catch {
            guard startupWasInFlight else {
                throw error
            }
        }
        await waitForStartupCompletion()
        try await shutdownCurrentResources()
    }

    private func shutdownCurrentResources() async throws {
        let client = rpcClient
        let transport = startupTransport
        try await client?.shutdown()
        try await transport?.shutdown()
    }

    private func resolveShutdownTask(
        _ task: Task<Result<Void, JSONRPCError>, Never>
    ) async throws {
        switch await task.value {
        case .success:
            shutdownTask = nil
            shutdownComplete = true
            rpcClient = nil
            startupTransport = nil
        case .failure(let error):
            shutdownTask = nil
            shutdownComplete = false
            throw error
        }
    }

    private func waitForStartupCompletion() async {
        guard startupInFlight else {
            return
        }
        await withCheckedContinuation { continuation in
            startupCompletionWaiters.append(continuation)
        }
    }

    private func completeStartup() {
        startupInFlight = false
        let waiters = startupCompletionWaiters
        startupCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func validateStartup(_ generation: UInt64) throws {
        try checkStartupCancellation()
        guard isInitializing(generation) else {
            throw JSONRPCError.transportClosed
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
        if let error = error as? JSONRPCError {
            return error
        }
        return .transportClosed
    }

    private func isInitializing(_ generation: UInt64) -> Bool {
        guard case .initializing(let activeGeneration) = state else {
            return false
        }
        return activeGeneration == generation
    }
}
