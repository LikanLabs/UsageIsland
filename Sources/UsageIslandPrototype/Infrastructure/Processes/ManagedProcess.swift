import Darwin
import Dispatch
import Foundation
import os

public struct ManagedProcessConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL?
    public let maximumBufferedOutputChunks: Int
    public let maximumOutputChunkSize: Int
    public let maximumPendingInputWrites: Int
    public let maximumInputWriteSize: Int
    public let maximumPendingInputBytes: Int

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        maximumBufferedOutputChunks: Int = 32,
        maximumOutputChunkSize: Int = 1_048_576,
        maximumPendingInputWrites: Int = 8,
        maximumInputWriteSize: Int = 1_048_576,
        maximumPendingInputBytes: Int = 4_194_304
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.maximumBufferedOutputChunks = max(1, maximumBufferedOutputChunks)
        self.maximumOutputChunkSize = max(1, maximumOutputChunkSize)
        self.maximumPendingInputWrites = max(1, maximumPendingInputWrites)
        self.maximumInputWriteSize = max(1, maximumInputWriteSize)
        self.maximumPendingInputBytes = max(1, maximumPendingInputBytes)
    }
}

public protocol ProcessSignaling: Sendable {
    func terminate(processIdentifier: Int32) async -> Bool
    func forceTerminate(processIdentifier: Int32) async -> Bool
}

public struct POSIXProcessSignaler: ProcessSignaling {
    public init() {}

    public func terminate(processIdentifier: Int32) async -> Bool {
        guard processIdentifier > 0 else {
            return false
        }
        return Darwin.kill(processIdentifier, SIGTERM) == 0
    }

    public func forceTerminate(processIdentifier: Int32) async -> Bool {
        guard processIdentifier > 0 else {
            return false
        }
        return Darwin.kill(processIdentifier, SIGKILL) == 0
    }
}


public protocol ManagedChildProcess: Sendable {
    func start(
        configuration: ManagedProcessConfiguration,
        standardInput: Pipe,
        standardOutput: Pipe,
        standardError: Pipe,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) async throws -> Int32
    func terminationStatusIfExited() async -> Int32?
}

public protocol ManagedChildProcessFactory: Sendable {
    func makeProcess() -> any ManagedChildProcess
}

public struct FoundationManagedChildProcessFactory: ManagedChildProcessFactory {
    public init() {}

    public func makeProcess() -> any ManagedChildProcess {
        FoundationManagedChildProcess()
    }
}

private actor FoundationManagedChildProcess: ManagedChildProcess {
    private var process: Process?

    func start(
        configuration: ManagedProcessConfiguration,
        standardInput: Pipe,
        standardOutput: Pipe,
        standardError: Pipe,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> Int32 {
        let child = Process()
        child.executableURL = configuration.executableURL
        child.arguments = configuration.arguments
        child.currentDirectoryURL = configuration.currentDirectoryURL
        child.standardInput = standardInput
        child.standardOutput = standardOutput
        child.standardError = standardError
        child.terminationHandler = { terminatedProcess in
            onTermination(terminatedProcess.terminationStatus)
        }
        try child.run()
        process = child
        return child.processIdentifier
    }

    func terminationStatusIfExited() -> Int32? {
        guard let process, !process.isRunning else {
            return nil
        }
        return process.terminationStatus
    }
}

struct BoundedProcessOutput: Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let maximumBufferedChunks: Int
    private let maximumChunkSize: Int

    init(maximumBufferedChunks: Int, maximumChunkSize: Int) {
        self.maximumBufferedChunks = max(1, maximumBufferedChunks)
        self.maximumChunkSize = max(1, maximumChunkSize)
        let pair = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, maximumBufferedChunks))
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ data: Data) -> JSONRPCError? {
        guard data.count <= maximumChunkSize else {
            let error = JSONRPCError.responseTooLarge(limit: maximumChunkSize)
            continuation.finish(throwing: error)
            return error
        }

        switch continuation.yield(data) {
        case .enqueued:
            return nil
        case .dropped:
            let error = JSONRPCError.transportBufferOverflow(
                limit: maximumBufferedChunks
            )
            continuation.finish(throwing: error)
            return error
        case .terminated:
            return JSONRPCError.transportClosed
        @unknown default:
            return JSONRPCError.transportClosed
        }
    }

    func finish() {
        continuation.finish()
    }

    func finish(throwing error: Error) {
        continuation.finish(throwing: error)
    }
}

private final class ProcessInputWriteProbe: Sendable {
    private typealias Continuation = AsyncStream<Void>.Continuation

    let stream: AsyncStream<Void>
    private let state: OSAllocatedUnfairLock<Continuation?>

    init() {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = pair.stream
        state = OSAllocatedUnfairLock(
            initialState: pair.continuation
        )
    }

    func recordWriteStarted() {
        let continuation = takeContinuation()
        continuation?.yield()
        continuation?.finish()
    }

    func finish() {
        takeContinuation()?.finish()
    }

    private func takeContinuation() -> Continuation? {
        state.withLock { continuation in
            defer {
                continuation = nil
            }
            return continuation
        }
    }
}

private actor NonblockingProcessInput {
    private let handle: FileHandle
    private let descriptor: Int32
    private var isClosed = false
    private var writableSource: DispatchSourceWrite?
    private var writableContinuation:
        CheckedContinuation<Void, Error>?

    init(handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
    }

    func write(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard !isClosed else {
                throw JSONRPCError.transportClosed
            }
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                throw JSONRPCError.transportClosed
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try await waitUntilWritable()
                continue
            }
            throw JSONRPCError.transportClosed
        }
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        writableSource?.cancel()
        writableSource = nil
        let continuation = writableContinuation
        writableContinuation = nil
        try? handle.close()
        continuation?.resume(
            throwing: JSONRPCError.transportClosed
        )
    }

    private func waitUntilWritable() async throws {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    installWritableWait(continuation)
                }
            },
            onCancel: { [self] in
                Task {
                    await cancelWritableWait()
                }
            }
        )
    }

    private func installWritableWait(
        _ continuation: CheckedContinuation<Void, Error>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard !isClosed else {
            continuation.resume(
                throwing: JSONRPCError.transportClosed
            )
            return
        }
        writableContinuation = continuation
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: descriptor,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [self] in
            Task {
                didBecomeWritable()
            }
        }
        writableSource = source
        source.resume()
    }

    private func didBecomeWritable() {
        writableSource?.cancel()
        writableSource = nil
        let continuation = writableContinuation
        writableContinuation = nil
        continuation?.resume()
    }

    private func cancelWritableWait() {
        writableSource?.cancel()
        writableSource = nil
        let continuation = writableContinuation
        writableContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

struct ProcessInputOperations: Sendable {
    let write: @Sendable (Data) async throws -> Void
    let close: @Sendable () async -> Void
    let abort: @Sendable () async -> Void

    static func fileHandle(_ handle: FileHandle) -> ProcessInputOperations {
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            try? handle.close()
            return ProcessInputOperations(
                write: { _ in
                    throw JSONRPCError.transportClosed
                },
                close: {},
                abort: {}
            )
        }
        let input = NonblockingProcessInput(handle: handle)
        return ProcessInputOperations(
            write: { data in
                try await input.write(data)
            },
            close: {
                await input.close()
            },
            abort: {
                await input.close()
            }
        )
    }
}

private final class ProcessInputAdmission: Sendable {
    private struct State: Sendable {
        var queuedWrites: [Data] = []
        var pendingWrites = 0
        var pendingBytes = 0
        var isClosed = false
    }

    private let maximumPendingWrites: Int
    private let maximumInputWriteSize: Int
    private let maximumPendingBytes: Int
    private let state: OSAllocatedUnfairLock<State>

    init(
        maximumPendingWrites: Int,
        maximumInputWriteSize: Int,
        maximumPendingBytes: Int
    ) {
        self.maximumPendingWrites = max(1, maximumPendingWrites)
        self.maximumInputWriteSize = max(1, maximumInputWriteSize)
        self.maximumPendingBytes = max(1, maximumPendingBytes)
        state = OSAllocatedUnfairLock(initialState: State())
    }

    func enqueue(_ data: Data) throws {
        try state.withLock { state in
            guard !state.isClosed else {
                throw JSONRPCError.transportClosed
            }
            guard data.count <= maximumInputWriteSize else {
                throw JSONRPCError.requestTooLarge(
                    limit: maximumInputWriteSize
                )
            }
            guard state.pendingWrites < maximumPendingWrites else {
                throw JSONRPCError.processInputBufferOverflow(
                    limit: maximumPendingWrites
                )
            }
            guard data.count <= maximumPendingBytes - state.pendingBytes
            else {
                throw JSONRPCError.processInputBufferOverflow(
                    limit: maximumPendingBytes
                )
            }

            state.queuedWrites.append(data)
            state.pendingWrites += 1
            state.pendingBytes += data.count
        }
    }

    func dequeue() -> Data? {
        state.withLock { state in
            guard !state.isClosed, !state.queuedWrites.isEmpty else {
                return nil
            }
            return state.queuedWrites.removeFirst()
        }
    }

    func complete(byteCount: Int) {
        state.withLock { state in
            state.pendingWrites = max(0, state.pendingWrites - 1)
            state.pendingBytes = max(
                0,
                state.pendingBytes - byteCount
            )
        }
    }

    func close() {
        state.withLock { state in
            guard !state.isClosed else {
                return
            }
            state.isClosed = true
            let queuedByteCount = state.queuedWrites.reduce(0) {
                partial,
                data in
                partial + data.count
            }
            state.pendingWrites = max(
                0,
                state.pendingWrites - state.queuedWrites.count
            )
            state.pendingBytes = max(
                0,
                state.pendingBytes - queuedByteCount
            )
            state.queuedWrites.removeAll(keepingCapacity: false)
        }
    }

    func pendingWork() -> (writes: Int, bytes: Int) {
        state.withLock { state in
            (state.pendingWrites, state.pendingBytes)
        }
    }

    func isClosed() -> Bool {
        state.withLock { state in
            state.isClosed
        }
    }
}

actor ProcessInputWriter {
    private let operations: ProcessInputOperations
    private nonisolated let admission: ProcessInputAdmission
    private let onFailure: @Sendable (JSONRPCError) -> Void
    private let onWriteStarted: @Sendable () -> Void

    private var didReportFailure = false
    private var terminalError: JSONRPCError?
    private var workerTask: Task<JSONRPCError?, Never>?
    private var closingWorkerTask: Task<JSONRPCError?, Never>?
    private var closeTask: Task<Void, Never>?

    init(
        operations: ProcessInputOperations,
        maximumPendingWrites: Int,
        maximumInputWriteSize: Int,
        maximumPendingBytes: Int,
        onFailure: @escaping @Sendable (JSONRPCError) -> Void,
        onWriteStarted: @escaping @Sendable () -> Void = {}
    ) {
        self.operations = operations
        admission = ProcessInputAdmission(
            maximumPendingWrites: maximumPendingWrites,
            maximumInputWriteSize: maximumInputWriteSize,
            maximumPendingBytes: maximumPendingBytes
        )
        self.onFailure = onFailure
        self.onWriteStarted = onWriteStarted
    }

    nonisolated func admit(_ data: Data) throws {
        try admission.enqueue(data)
    }

    func enqueue(_ data: Data) throws {
        try admit(data)
        startWorkerIfNeeded()
    }

    func startAdmittedWrites() {
        startWorkerIfNeeded()
    }

    nonisolated func closeAdmission() {
        admission.close()
    }

    func beginClose() {
        if closingWorkerTask == nil {
            closingWorkerTask = workerTask
        }
        admission.close()
        if closeTask == nil {
            closingWorkerTask?.cancel()
            let operations = self.operations
            closeTask = Task {
                await operations.close()
            }
        }
    }

    func finishClose() async -> JSONRPCError? {
        beginClose()
        let closeTask = self.closeTask
        let activeWorker = closingWorkerTask
        await operations.abort()
        _ = await closeTask?.result
        let workerError = await activeWorker?.value
        if let workerError {
            terminalError = workerError
        }
        self.closeTask = nil
        closingWorkerTask = nil
        return terminalError
    }

    func closeInput() async {
        _ = await finishClose()
    }

    nonisolated func pendingWork() -> (writes: Int, bytes: Int) {
        admission.pendingWork()
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil, !admission.isClosed() else {
            return
        }
        workerTask = Task { [weak self] in
            guard let self else {
                return nil
            }
            return await self.processQueue()
        }
    }

    private func processQueue() async -> JSONRPCError? {
        defer {
            workerTask = nil
        }
        while !Task.isCancelled, let data = admission.dequeue() {
            onWriteStarted()
            do {
                try await operations.write(data)
                admission.complete(byteCount: data.count)
                if admission.isClosed() || Task.isCancelled {
                    terminalError = .transportClosed
                    return terminalError
                }
            } catch {
                admission.complete(byteCount: data.count)
                let writeError =
                    error as? JSONRPCError ?? JSONRPCError.transportClosed
                terminalError = writeError
                if !admission.isClosed(), !didReportFailure {
                    didReportFailure = true
                    admission.close()
                    await operations.close()
                    onFailure(.transportClosed)
                }
                return writeError
            }
        }
        return terminalError
    }
}

private actor ProcessExitMonitor {
    private var status: Int32?
    private var waiters:
        [UUID: AsyncStream<Int32>.Continuation] = [:]

    func record(_ status: Int32) {
        guard self.status == nil else {
            return
        }
        self.status = status
        let continuations = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.yield(status)
            continuation.finish()
        }
    }

    func events() -> AsyncStream<Int32> {
        if let status {
            return AsyncStream { continuation in
                continuation.yield(status)
                continuation.finish()
            }
        }

        let id = UUID()
        let pair = AsyncStream<Int32>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeWaiter(id)
            }
        }
        waiters[id] = pair.continuation
        return pair.stream
    }

    private func removeWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)
    }
}

public actor ManagedProcess: JSONRPCTransport {
    private enum State: Sendable {
        case idle
        case starting(UInt64)
        case running(UInt64)
        case stopping
        case failing
        case stopped
    }

    private enum ExitWaitResult: Sendable {
        case exited(Int32)
        case deadline
    }

    private let configuration: ManagedProcessConfiguration
    private let shutdownScheduler: any JSONRPCTimeoutScheduler
    private let processSignaler: any ProcessSignaling
    private let processFactory: any ManagedChildProcessFactory
    private let inputOperationsProvider:
        @Sendable (FileHandle) -> ProcessInputOperations
    private let shutdownStartGate: @Sendable () async -> Void
    private let terminationGracePeriod: Duration
    private let killGracePeriod: Duration
    private let output: BoundedProcessOutput
    private let exitMonitor = ProcessExitMonitor()
    private let inputWriteProbe = ProcessInputWriteProbe()

    private var state = State.idle
    private var lifecycleGeneration: UInt64 = 0
    private var process: (any ManagedChildProcess)?
    private var launchedProcessIdentifier: Int32?
    private var startTask: Task<Result<Int32, JSONRPCError>, Never>?
    private var inputWriter: ProcessInputWriter?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var observedExitStatus: Int32?
    private var standardOutputReachedEnd = false
    private var standardOutputReadabilityInvocations = 0
    private var standardErrorReadabilityInvocations = 0
    private var standardOutputEOFInvocations = 0
    private var standardErrorEOFInvocations = 0
    private var inputWriterTerminationError: JSONRPCError?
    private var shutdownTask: Task<Void, Error>?

    public init(
        configuration: ManagedProcessConfiguration,
        shutdownScheduler: any JSONRPCTimeoutScheduler =
            ContinuousJSONRPCTimeoutScheduler(),
        processSignaler: any ProcessSignaling = POSIXProcessSignaler(),
        processFactory: any ManagedChildProcessFactory =
            FoundationManagedChildProcessFactory(),
        terminationGracePeriod: Duration = .seconds(2),
        killGracePeriod: Duration = .seconds(1)
    ) {
        self.configuration = configuration
        self.shutdownScheduler = shutdownScheduler
        self.processSignaler = processSignaler
        self.processFactory = processFactory
        inputOperationsProvider = { handle in
            .fileHandle(handle)
        }
        shutdownStartGate = {}
        self.terminationGracePeriod = terminationGracePeriod
        self.killGracePeriod = killGracePeriod
        output = BoundedProcessOutput(
            maximumBufferedChunks: configuration.maximumBufferedOutputChunks,
            maximumChunkSize: configuration.maximumOutputChunkSize
        )
    }

    init(
        configuration: ManagedProcessConfiguration,
        shutdownScheduler: any JSONRPCTimeoutScheduler,
        processSignaler: any ProcessSignaling,
        processFactory: any ManagedChildProcessFactory,
        inputOperations: ProcessInputOperations,
        shutdownStartGate: @escaping @Sendable () async -> Void = {},
        terminationGracePeriod: Duration = .seconds(2),
        killGracePeriod: Duration = .seconds(1)
    ) {
        self.configuration = configuration
        self.shutdownScheduler = shutdownScheduler
        self.processSignaler = processSignaler
        self.processFactory = processFactory
        inputOperationsProvider = { _ in
            inputOperations
        }
        self.shutdownStartGate = shutdownStartGate
        self.terminationGracePeriod = terminationGracePeriod
        self.killGracePeriod = killGracePeriod
        output = BoundedProcessOutput(
            maximumBufferedChunks: configuration.maximumBufferedOutputChunks,
            maximumChunkSize: configuration.maximumOutputChunkSize
        )
    }

    public func start() async throws {
        switch state {
        case .idle:
            break
        case .starting, .running:
            throw JSONRPCError.alreadyInitialized
        case .stopping, .failing, .stopped:
            throw JSONRPCError.transportClosed
        }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let child = processFactory.makeProcess()
        let launchError = JSONRPCError.processLaunchFailed(
            JSONRPCError.sanitizedExecutableName(
                configuration.executableURL.path
            )
        )

        let boundedOutput = output
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.noteStandardOutputReadability()
            }
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task {
                    await self?.standardOutputDidReachEnd()
                }
                return
            }
            guard let error = boundedOutput.yield(data) else {
                return
            }
            Task {
                await self?.outputDidFail(with: error)
            }
        }

        let errorHandle = errorPipe.fileHandleForReading
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.noteStandardErrorReadability()
            }
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task {
                    await self?.standardErrorDidReachEnd()
                }
            }
        }

        let exitMonitor = self.exitMonitor
        let terminationHandler: @Sendable (Int32) -> Void = {
            [weak self] status in
            Task {
                await exitMonitor.record(status)
                await self?.processDidTerminate(status: status)
            }
        }

        process = child
        let inputWriteProbe = self.inputWriteProbe
        inputWriter = ProcessInputWriter(
            operations: inputOperationsProvider(
                inputPipe.fileHandleForWriting
            ),
            maximumPendingWrites: configuration.maximumPendingInputWrites,
            maximumInputWriteSize: configuration.maximumInputWriteSize,
            maximumPendingBytes: configuration.maximumPendingInputBytes,
            onFailure: { [weak self] error in
                Task {
                    await self?.inputWriterDidFail(with: error)
                }
            },
            onWriteStarted: {
                inputWriteProbe.recordWriteStarted()
            }
        )
        standardOutput = outputHandle
        standardError = errorHandle
        state = .starting(generation)

        let task = Task<Result<Int32, JSONRPCError>, Never> {
            do {
                let processIdentifier = try await child.start(
                    configuration: configuration,
                    standardInput: inputPipe,
                    standardOutput: outputPipe,
                    standardError: errorPipe,
                    onTermination: terminationHandler
                )
                guard processIdentifier > 0 else {
                    return .failure(launchError)
                }
                return .success(processIdentifier)
            } catch {
                return .failure(launchError)
            }
        }
        startTask = task

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        switch result {
        case .success(let processIdentifier):
            let startupError = Task.isCancelled
                ? JSONRPCError.startupCancelled
                : JSONRPCError.transportClosed

            if case .starting(let activeGeneration) = state,
               activeGeneration == generation {
                launchedProcessIdentifier = processIdentifier
                startTask = nil
                state = .running(generation)

                if Task.isCancelled {
                    try await shutdown()
                    throw startupError
                }
                return
            }

            if case .stopping = state, process != nil {
                launchedProcessIdentifier = processIdentifier
                startTask = nil
                try await shutdown()
            }
            throw startupError

        case .failure(let error):
            if case .starting(let activeGeneration) = state,
               activeGeneration == generation {
                startTask = nil
                await cleanUpFailedLaunch()
                state = .stopped
                output.finish(throwing: error)
            }
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        guard case .running(let generation) = state,
              let process,
              let writer = inputWriter else {
            throw JSONRPCError.transportClosed
        }
        let terminationStatus = await process.terminationStatusIfExited()
        guard terminationStatus == nil,
              case .running(let currentGeneration) = state,
              currentGeneration == generation,
              inputWriter === writer else {
            throw JSONRPCError.transportClosed
        }
        try writer.admit(data)
        await writer.startAdmittedWrites()
    }

    public func incomingBytes() -> AsyncThrowingStream<Data, Error> {
        output.stream
    }

    public func shutdown() async throws {
        if let shutdownTask {
            try await shutdownTask.value
            return
        }
        if case .stopped = state {
            return
        }

        let stateAtShutdown = state
        state = .stopping
        inputWriter?.closeAdmission()
        let task = Task { [self] in
            await shutdownStartGate()
            try await performShutdown(from: stateAtShutdown)
        }
        shutdownTask = task
        do {
            try await task.value
            shutdownTask = nil
        } catch {
            shutdownTask = nil
            throw error
        }
    }

    func hasProcessOwnership() -> Bool {
        process != nil
    }

    func ownedProcessIdentifier() -> Int32? {
        launchedProcessIdentifier
    }

    func pendingInputWork() -> (writes: Int, bytes: Int) {
        inputWriter?.pendingWork() ?? (0, 0)
    }

    func inputWriteStartedEvents() -> AsyncStream<Void> {
        inputWriteProbe.stream
    }

    func completedInputWriteError() -> JSONRPCError? {
        inputWriterTerminationError
    }

    func readabilityProbe() -> (
        stdout: Int,
        stderr: Int,
        stdoutEOF: Int,
        stderrEOF: Int
    ) {
        (
            standardOutputReadabilityInvocations,
            standardErrorReadabilityInvocations,
            standardOutputEOFInvocations,
            standardErrorEOFInvocations
        )
    }

    private func performShutdown(from initialState: State) async throws {
        switch initialState {
        case .idle:
            output.finish()
            inputWriteProbe.finish()
            state = .stopped
            return

        case .starting:
            guard let launchTask = startTask else {
                await cleanUpFailedLaunch()
                state = .stopped
                output.finish()
                return
            }
            switch await launchTask.value {
            case .failure:
                startTask = nil
                await cleanUpFailedLaunch()
                state = .stopped
                output.finish()
                return
            case .success(let processIdentifier):
                guard processIdentifier > 0 else {
                    startTask = nil
                    await cleanUpFailedLaunch()
                    state = .stopped
                    output.finish()
                    return
                }
                launchedProcessIdentifier = processIdentifier
                startTask = nil
            }

        case .running, .failing, .stopping:
            break

        case .stopped:
            return
        }

        guard let child = process,
              let processIdentifier = launchedProcessIdentifier,
              processIdentifier > 0 else {
            await cleanUpFailedLaunch()
            state = .stopped
            output.finish()
            return
        }

        state = .stopping
        let closingWriter = inputWriter
        await closingWriter?.beginClose()

        if let status = await observeExitIfAvailable(child) {
            await completeShutdownAfterObservedExit(
                status,
                closingWriter: closingWriter
            )
            return
        }

        switch await Self.waitForExit(
            exitMonitor,
            scheduler: shutdownScheduler,
            timeout: terminationGracePeriod
        ) {
        case .exited(let status):
            await completeShutdownAfterObservedExit(
                status,
                closingWriter: closingWriter
            )
            return
        case .deadline:
            break
        }

        if let status = await observeExitIfAvailable(child) {
            await completeShutdownAfterObservedExit(
                status,
                closingWriter: closingWriter
            )
            return
        }

        _ = await processSignaler.terminate(
            processIdentifier: processIdentifier
        )
        if let status = await observeExitIfAvailable(child) {
            await completeShutdownAfterObservedExit(
                status,
                closingWriter: closingWriter
            )
            return
        }

        switch await Self.waitForExit(
            exitMonitor,
            scheduler: shutdownScheduler,
            timeout: terminationGracePeriod
        ) {
        case .exited(let status):
            await completeShutdownAfterObservedExit(
                status,
                closingWriter: closingWriter
            )
            return
        case .deadline:
            break
        }

        if let status = await observeExitIfAvailable(child) {
            await completeShutdownAfterObservedExit(
                status,
                closingWriter: closingWriter
            )
            return
        }

        let forceSignalWasSent = await processSignaler.forceTerminate(
            processIdentifier: processIdentifier
        )
        if !forceSignalWasSent {
            if let status = await observeExitIfAvailable(child) {
                await completeShutdownAfterObservedExit(
                    status,
                    closingWriter: closingWriter
                )
                return
            }
            throw JSONRPCError.processTerminationFailed
        }

        switch await Self.waitForExit(
            exitMonitor,
            scheduler: shutdownScheduler,
            timeout: killGracePeriod
        ) {
        case .exited(let status):
            await completeShutdownAfterObservedExit(
                status,
                closingWriter: closingWriter
            )
        case .deadline:
            if let status = await observeExitIfAvailable(child) {
                await completeShutdownAfterObservedExit(
                    status,
                    closingWriter: closingWriter
                )
            } else {
                throw JSONRPCError.processTerminationTimedOut
            }
        }
    }

    private func inputWriterDidFail(with error: JSONRPCError) async {
        await outputDidFail(with: error)
    }

    private func outputDidFail(with error: JSONRPCError) async {
        guard case .running = state else {
            return
        }
        state = .failing
        output.finish(throwing: error)
        await inputWriter?.closeInput()
        guard let process else {
            return
        }
        if let status = await observeExitIfAvailable(process) {
            await completeObservedExit(status: status)
            return
        }
        guard let processIdentifier = launchedProcessIdentifier,
              processIdentifier > 0 else {
            return
        }
        _ = await processSignaler.forceTerminate(
            processIdentifier: processIdentifier
        )
    }

    private func processDidTerminate(status: Int32) async {
        await completeObservedExit(status: status)
    }

    private func noteStandardOutputReadability() {
        standardOutputReadabilityInvocations += 1
    }

    private func noteStandardErrorReadability() {
        standardErrorReadabilityInvocations += 1
    }

    private func standardOutputDidReachEnd() async {
        standardOutputEOFInvocations += 1
        standardOutputReachedEnd = true
        if let observedExitStatus {
            await completeObservedExit(status: observedExitStatus)
        }
    }

    private func standardErrorDidReachEnd() {
        standardErrorEOFInvocations += 1
    }

    private func completeObservedExit(status: Int32) async {
        if observedExitStatus == nil {
            observedExitStatus = status
        }
        guard observedExitStatus == status, process != nil else {
            return
        }

        switch state {
        case .starting, .running:
            guard standardOutputReachedEnd else {
                return
            }
            output.finish(
                throwing: JSONRPCError.processExited(status: status)
            )
        case .stopping:
            output.finish()
            return
        case .idle, .failing, .stopped:
            break
        }

        inputWriterTerminationError = await inputWriter?.finishClose()
        cleanUpHandlesAfterObservedExit()
        state = .stopped
    }

    private func completeShutdownAfterObservedExit(
        _ status: Int32,
        closingWriter: ProcessInputWriter?
    ) async {
        await completeObservedExit(status: status)
        inputWriterTerminationError = await closingWriter?.finishClose()
        cleanUpHandlesAfterObservedExit()
        state = .stopped
    }

    private func observeExitIfAvailable(
        _ child: any ManagedChildProcess
    ) async -> Int32? {
        if let observedExitStatus {
            return observedExitStatus
        }
        return await child.terminationStatusIfExited()
    }

    private func cleanUpHandlesAfterObservedExit() {
        guard observedExitStatus != nil else {
            return
        }
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        try? standardOutput?.close()
        try? standardError?.close()
        standardOutput = nil
        standardError = nil
        inputWriter = nil
        process = nil
        launchedProcessIdentifier = nil
        inputWriteProbe.finish()
    }

    private func cleanUpFailedLaunch() async {
        await inputWriter?.closeInput()
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        try? standardOutput?.close()
        try? standardError?.close()
        standardOutput = nil
        standardError = nil
        inputWriter = nil
        process = nil
        launchedProcessIdentifier = nil
        inputWriteProbe.finish()
    }

    private nonisolated static func waitForExit(
        _ monitor: ProcessExitMonitor,
        scheduler: any JSONRPCTimeoutScheduler,
        timeout: Duration
    ) async -> ExitWaitResult {
        await withTaskGroup(of: ExitWaitResult.self) { group in
            group.addTask {
                let stream = await monitor.events()
                var iterator = stream.makeAsyncIterator()
                if let status = await iterator.next() {
                    return .exited(status)
                }
                return .deadline
            }
            group.addTask {
                do {
                    try await scheduler.wait(for: timeout)
                } catch {
                    return .deadline
                }
                return .deadline
            }
            let result = await group.next() ?? .deadline
            group.cancelAll()
            return result
        }
    }
}
