import Darwin
import Dispatch
import Foundation
import XCTest

@testable import UsageIslandPrototype

final class ManagedProcessTests: XCTestCase {
    func testNonexistentExecutableReturnsSanitizedLaunchError() async {
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/missing/private-token-value/codex"),
                arguments: ["app-server"]
            )
        )

        do {
            try await process.start()
            XCTFail("Expected launch failure")
        } catch {
            guard case .processLaunchFailed(let storedName) =
                error as? JSONRPCError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(storedName, "codex")
            XCTAssertFalse(storedName.contains("private-token-value"))
            XCTAssertFalse(error.localizedDescription.contains("private-token-value"))
        }
    }

    func testRealProcessReceivesLiteralArgumentsAndKeepsStderrOutOfStdout() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let literalFile = directory.appendingPathComponent(
            "literal;$(not-a-shell).json"
        )
        let missingFile = directory.appendingPathComponent("missing.json")
        try Data("literal stdout\n".utf8).write(to: literalFile)
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [literalFile.path, missingFile.path]
            ),
            shutdownScheduler: ControlledTimeoutScheduler()
        )
        let stream = await process.incomingBytes()

        try await process.start()
        var stdout = Data()
        var terminalError: JSONRPCError?
        do {
            for try await chunk in stream {
                stdout.append(chunk)
            }
        } catch {
            terminalError = error as? JSONRPCError
        }

        XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "literal stdout\n")
        XCTAssertFalse(String(decoding: stdout, as: UTF8.self).contains("missing.json"))
        XCTAssertEqual(terminalError, .processExited(status: 1))
        try await process.shutdown()
    }

    func testRealBlockingProcessShutdownIsCleanAndIdempotent() async throws {
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: []
            ),
            shutdownScheduler: ControlledTimeoutScheduler()
        )
        try await process.start()

        try await process.shutdown()
        try await process.shutdown()

        do {
            try await process.send(Data("after shutdown".utf8))
            XCTFail("Expected closed transport")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
    }

    func testStdoutEOFUnregistersHandlerWhileChildStaysAlive() async throws {
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 1>&-; exec sleep 1"]
            ),
            shutdownScheduler: ControlledTimeoutScheduler()
        )
        try await process.start()
        try await waitUntilReadability(process) { $0.stdoutEOF >= 1 }
        let first = await process.readabilityProbe()
        try await Task.sleep(for: .milliseconds(250))
        let second = await process.readabilityProbe()

        XCTAssertEqual(first.stdoutEOF, 1)
        XCTAssertEqual(second.stdoutEOF, 1)
        XCTAssertEqual(first.stdout, second.stdout)
        XCTAssertLessThan(first.stdout, 8)
        try await process.shutdown()
    }

    func testStderrEOFUnregistersHandlerWhileChildStaysAlive() async throws {
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 2>&-; exec sleep 1"]
            ),
            shutdownScheduler: ControlledTimeoutScheduler()
        )
        try await process.start()
        try await waitUntilReadability(process) { $0.stderrEOF >= 1 }
        let first = await process.readabilityProbe()
        try await Task.sleep(for: .milliseconds(250))
        let second = await process.readabilityProbe()

        XCTAssertEqual(first.stderrEOF, 1)
        XCTAssertEqual(second.stderrEOF, 1)
        XCTAssertEqual(first.stderr, second.stderr)
        XCTAssertLessThan(first.stderr, 8)
        XCTAssertEqual(first.stdoutEOF, 0)
        try await process.shutdown()
    }

    func testRealFullPipeShutdownTerminatesOwnedNonReadingChild() async throws {
        let executable = "/usr/bin/tail"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip(
                "Required non-reading system child /usr/bin/tail is absent"
            )
        }
        let scheduler = ScriptedProcessTimeoutScheduler(
            actions: [.fire, .suspend]
        )
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: executable),
                arguments: ["-f", "/dev/null"],
                maximumPendingInputWrites: 2,
                maximumInputWriteSize: 1_048_576,
                maximumPendingInputBytes: 1_048_576
            ),
            shutdownScheduler: scheduler
        )
        try await process.start()
        let ownedPID = await process.ownedProcessIdentifier()
        let processIdentifier = try XCTUnwrap(ownedPID)
        defer {
            if processIdentifier > 0 {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }

        let inputWriteEvents = await process.inputWriteStartedEvents()
        try await process.send(Data(repeating: 0x61, count: 1_048_576))
        var inputWriteIterator = inputWriteEvents.makeAsyncIterator()
        guard await inputWriteIterator.next() != nil else {
            throw TransportTestProbeError.conditionNotReached(
                "Real process input write did not start"
            )
        }

        try await withOuterTimeout(.seconds(5)) {
            try await process.shutdown()
        }

        let completedWriteError =
            await process.completedInputWriteError()
        XCTAssertEqual(completedWriteError, .transportClosed)
        errno = 0
        XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        do {
            try await process.send(Data("after shutdown".utf8))
            XCTFail("Expected closed transport")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
    }

    func testDirectExitAbortsWriteWhenDescendantRetainsStdin() async throws {
        let swiftExecutable = "/usr/bin/swift"
        let tailExecutable = "/usr/bin/tail"
        guard FileManager.default.isExecutableFile(atPath: swiftExecutable),
              FileManager.default.isExecutableFile(atPath: tailExecutable)
        else {
            throw XCTSkip(
                "Required Swift and tail system executables are absent"
            )
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("RetainStdin.swift")
        let gate = directory.appendingPathComponent("exit.fifo")
        let scriptSource = """
        import Darwin
        import Foundation

        let descendant = Process()
        descendant.executableURL = URL(
            fileURLWithPath: "\(tailExecutable)"
        )
        descendant.arguments = ["-f", "/dev/null"]
        descendant.standardInput = FileHandle.standardInput
        descendant.standardOutput = FileHandle.nullDevice
        descendant.standardError = FileHandle.nullDevice
        do {
            try descendant.run()
        } catch {
            Darwin.exit(70)
        }
        FileHandle.standardOutput.write(
            Data("\\(descendant.processIdentifier)\\n".utf8)
        )
        let descriptor = Darwin.open(CommandLine.arguments[1], O_RDONLY)
        guard descriptor >= 0 else {
            Darwin.exit(71)
        }
        var byte: UInt8 = 0
        _ = Darwin.read(descriptor, &byte, 1)
        Darwin.close(descriptor)
        Darwin.exit(0)
        """
        try Data(scriptSource.utf8).write(to: script)
        XCTAssertEqual(Darwin.mkfifo(gate.path, S_IRUSR | S_IWUSR), 0)

        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: swiftExecutable),
                arguments: [script.path, gate.path],
                maximumPendingInputWrites: 2,
                maximumInputWriteSize: 1_048_576,
                maximumPendingInputBytes: 1_048_576
            ),
            shutdownScheduler: ControlledTimeoutScheduler()
        )
        let stream = await process.incomingBytes()
        try await process.start()
        var gateDescriptor: Int32 = -1
        var descendantPID: Int32 = -1
        defer {
            if gateDescriptor >= 0 {
                Darwin.close(gateDescriptor)
            }
            if descendantPID > 0 {
                _ = Darwin.kill(descendantPID, SIGKILL)
            }
        }

        let parsedPID = try await withOuterValueTimeout(
            .seconds(10)
        ) {
            await Self.readFirstProcessIdentifier(from: stream)
        }
        descendantPID = try XCTUnwrap(parsedPID)
        XCTAssertGreaterThan(descendantPID, 0)
        gateDescriptor = try await openFIFOForWriting(gate)

        let inputWriteEvents = await process.inputWriteStartedEvents()
        try await process.send(Data(repeating: 0x61, count: 1_048_576))
        var inputWriteIterator = inputWriteEvents.makeAsyncIterator()
        guard await inputWriteIterator.next() != nil else {
            throw TransportTestProbeError.conditionNotReached(
                "Retained-stdin process input write did not start"
            )
        }
        XCTAssertEqual(Darwin.close(gateDescriptor), 0)
        gateDescriptor = -1

        try await withOuterTimeout(.seconds(10)) {
            do {
                for try await _ in stream {}
                throw JSONRPCError.transportClosed
            } catch let error as JSONRPCError {
                guard error == .processExited(status: 0) else {
                    throw error
                }
            }
        }

        try await withOuterTimeout(.seconds(5)) {
            try await process.shutdown()
        }
        let writerError = await process.completedInputWriteError()
        XCTAssertEqual(writerError, .transportClosed)
        try await terminateAndConfirmExit(descendantPID)
        descendantPID = -1
    }

    func testRealUnexpectedExitResolvesPendingJSONRPCRequest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("input.fifo")
        let missingFile = directory.appendingPathComponent("missing.json")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        var fifoDescriptor: Int32 = -1
        defer {
            if fifoDescriptor >= 0 {
                Darwin.close(fifoDescriptor)
            }
        }

        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [fifo.path, missingFile.path]
            ),
            shutdownScheduler: ControlledTimeoutScheduler()
        )
        let transport = RecordingRealTransport(base: process)
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        fifoDescriptor = try await openFIFOForWriting(fifo)
        let requestTask = makeTrackedTask {
            try await client.request(method: "pending/until-exit")
        }
        try await transport.waitUntilSendCalled()

        XCTAssertEqual(Darwin.close(fifoDescriptor), 0)
        fifoDescriptor = -1

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected process exit")
        } catch {
            switch error as? JSONRPCError {
            case .processExited(status: 1), .transportClosed:
                break
            default:
                XCTFail("Unexpected lifecycle error: \(error)")
            }
        }
        try await client.shutdown()
    }

    func testBoundedProcessOutputFailsInsteadOfDroppingBytes() async throws {
        let output = BoundedProcessOutput(
            maximumBufferedChunks: 1,
            maximumChunkSize: 8
        )

        XCTAssertNil(output.yield(Data("first".utf8)))
        XCTAssertEqual(
            output.yield(Data("second".utf8)),
            .transportBufferOverflow(limit: 1)
        )

        var iterator = output.stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, Data("first".utf8))
        do {
            _ = try await iterator.next()
            XCTFail("Expected explicit buffer overflow")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .transportBufferOverflow(limit: 1)
            )
        }
    }

    func testBoundedProcessOutputRejectsOversizedChunk() async {
        let output = BoundedProcessOutput(
            maximumBufferedChunks: 1,
            maximumChunkSize: 4
        )

        XCTAssertEqual(
            output.yield(Data("oversized".utf8)),
            .responseTooLarge(limit: 4)
        )
    }

    func testForceSignalFailureRetainsOwnershipUntilRetryConfirmsExit() async throws {
        let scheduler = ScriptedProcessTimeoutScheduler(
            actions: [.fire, .fire, .fire, .fire, .suspend]
        )
        let child = FakeManagedChildProcess()
        let signaler = ScriptedProcessSignaler(
            child: child,
            terminateActions: [.reportSuccess, .reportSuccess],
            forceActions: [.reportFailure, .confirmExit(9)]
        )
        let process = makeLongRunningProcess(
            child: child,
            scheduler: scheduler,
            signaler: signaler
        )
        try await process.start()

        do {
            try await process.shutdown()
            XCTFail("Expected force termination failure")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .processTerminationFailed
            )
        }
        let retainedAfterFailure = await process.hasProcessOwnership()
        XCTAssertTrue(retainedAfterFailure)

        try await process.shutdown()

        let retainedAfterRetry = await process.hasProcessOwnership()
        let forceCalls = await signaler.forceCallCount()
        let signalEvents = await signaler.recordedEvents()
        XCTAssertFalse(retainedAfterRetry)
        XCTAssertEqual(forceCalls, 2)
        XCTAssertEqual(
            signalEvents,
            [
                .terminate(4_242),
                .forceTerminate(4_242),
                .terminate(4_242),
                .forceTerminate(4_242)
            ]
        )
    }

    func testSecondTerminationDeadlineRetainsOwnershipUntilRetry() async throws {
        let scheduler = ScriptedProcessTimeoutScheduler(
            actions: [
                .fire, .fire, .fire, .fire, .fire, .suspend
            ]
        )
        let child = FakeManagedChildProcess()
        let signaler = ScriptedProcessSignaler(
            child: child,
            terminateActions: [.reportSuccess, .reportSuccess],
            forceActions: [.reportSuccess, .confirmExit(9)]
        )
        let process = makeLongRunningProcess(
            child: child,
            scheduler: scheduler,
            signaler: signaler
        )
        try await process.start()

        do {
            try await process.shutdown()
            XCTFail("Expected termination timeout")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .processTerminationTimedOut
            )
        }
        let retainedAfterTimeout = await process.hasProcessOwnership()
        XCTAssertTrue(retainedAfterTimeout)

        try await process.shutdown()

        let retainedAfterRetry = await process.hasProcessOwnership()
        let signalEvents = await signaler.recordedEvents()
        XCTAssertFalse(retainedAfterRetry)
        XCTAssertEqual(
            signalEvents,
            [
                .terminate(4_242),
                .forceTerminate(4_242),
                .terminate(4_242),
                .forceTerminate(4_242)
            ]
        )
    }

    func testConcurrentManagedShutdownCallsAwaitSameBarrier() async throws {
        let child = FakeManagedChildProcess()
        let signaler = BlockingProcessSignaler(child: child)
        let process = makeLongRunningProcess(
            child: child,
            scheduler: ImmediateTimeoutScheduler(),
            signaler: signaler
        )
        try await process.start()
        let first = makeTrackedTask {
            try await process.shutdown()
        }
        try await signaler.waitUntilTerminateCalled()
        let second = makeTrackedTask {
            try await process.shutdown()
        }
        try await second.state.waitUntilBegan()

        let secondCompleted = await second.state.isCompleted()
        XCTAssertFalse(secondCompleted)
        await signaler.releaseTermination()
        try await boundedValue(of: first)
        try await boundedValue(of: second)

        let terminateCalls = await signaler.terminateCallCount()
        let retained = await process.hasProcessOwnership()
        XCTAssertEqual(terminateCalls, 1)
        XCTAssertFalse(retained)
    }

    func testPOSIXSignalerRejectsNonPositiveProcessIdentifiers() async {
        let signaler = POSIXProcessSignaler()

        let zeroTerm = await signaler.terminate(processIdentifier: 0)
        let negativeTerm = await signaler.terminate(processIdentifier: -1)
        let zeroKill = await signaler.forceTerminate(processIdentifier: 0)
        let negativeKill = await signaler.forceTerminate(processIdentifier: -1)

        XCTAssertFalse(zeroTerm)
        XCTAssertFalse(negativeTerm)
        XCTAssertFalse(zeroKill)
        XCTAssertFalse(negativeKill)
    }

    func testShutdownRacingFailedLaunchNeverSignals() async throws {
        try await assertShutdownRacingInvalidLaunch(
            outcome: .fail
        )
    }

    func testShutdownRacingPIDZeroLaunchNeverSignals() async throws {
        try await assertShutdownRacingInvalidLaunch(
            outcome: .succeed(0)
        )
    }

    func testCancellationAfterPositiveLaunchShutsDownBeforeReturning() async throws {
        let child = FakeManagedChildProcess(
            suspendsAfterLaunch: true
        )
        let signaler = ScriptedProcessSignaler(
            child: child,
            terminateActions: [.confirmExit(0)],
            forceActions: []
        )
        let process = makeLongRunningProcess(
            child: child,
            scheduler: ImmediateTimeoutScheduler(),
            signaler: signaler
        )
        let startTask = makeTrackedTask {
            try await process.start()
        }
        try await child.waitUntilPositiveLaunch()

        startTask.task.cancel()
        await child.releasePostLaunch()

        let result = try await boundedResult(of: startTask)
        switch result {
        case .success:
            XCTFail("Cancelled startup must not publish success")
        case .failure(let error):
            XCTAssertEqual(error as? JSONRPCError, .startupCancelled)
        }
        let events = await signaler.recordedEvents()
        let retained = await process.hasProcessOwnership()
        XCTAssertEqual(events, [.terminate(4_242)])
        XCTAssertFalse(retained)
    }

    func testShutdownAfterPositiveLaunchWaitsForPIDAndConfirmedExit() async throws {
        let child = FakeManagedChildProcess(
            suspendsAfterLaunch: true
        )
        let signaler = ScriptedProcessSignaler(
            child: child,
            terminateActions: [.confirmExit(0)],
            forceActions: []
        )
        let process = makeLongRunningProcess(
            child: child,
            scheduler: ImmediateTimeoutScheduler(),
            signaler: signaler
        )
        let startTask = makeTrackedTask {
            try await process.start()
        }
        try await child.waitUntilPositiveLaunch()
        let shutdownTask = makeTrackedTask {
            try await process.shutdown()
        }
        try await shutdownTask.state.waitUntilBegan()
        let shutdownCompletedBeforePID =
            await shutdownTask.state.isCompleted()
        XCTAssertFalse(shutdownCompletedBeforePID)

        await child.releasePostLaunch()

        let startResult = try await boundedResult(of: startTask)
        switch startResult {
        case .success:
            XCTFail("Shutdown must invalidate startup")
        case .failure(let error):
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        try await boundedValue(of: shutdownTask)
        let events = await signaler.recordedEvents()
        let retained = await process.hasProcessOwnership()
        XCTAssertEqual(events, [.terminate(4_242)])
        XCTAssertFalse(retained)
    }

    func testInputWriterRejectsSingleOversizedWrite() async throws {
        let sink = ControlledProcessInputSink()
        let writer = makeInputWriter(
            sink: sink,
            maximumInputWriteSize: 4,
            maximumPendingBytes: 8
        )

        do {
            try await writer.enqueue(Data(repeating: 0x61, count: 5))
            XCTFail("Expected oversized write rejection")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .requestTooLarge(limit: 4))
        }
        let calls = await sink.writeCallCount()
        XCTAssertEqual(calls, 0)
        await writer.closeInput()
    }

    func testInputWriterRejectsAggregatePendingByteOverflow() async throws {
        let sink = ControlledProcessInputSink()
        let writer = makeInputWriter(
            sink: sink,
            maximumInputWriteSize: 8,
            maximumPendingBytes: 10
        )
        try await writer.enqueue(Data(repeating: 0x61, count: 8))
        try await sink.waitUntilWriteCalled(count: 1)

        do {
            try await writer.enqueue(Data(repeating: 0x62, count: 4))
            XCTFail("Expected aggregate byte budget rejection")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .processInputBufferOverflow(limit: 10)
            )
        }
        await writer.closeInput()
        let pending = writer.pendingWork()
        XCTAssertEqual(pending.writes, 0)
        XCTAssertEqual(pending.bytes, 0)
    }

    func testInputWriterShutdownCancelsActiveAndDropsQueuedWrite() async throws {
        let sink = ControlledProcessInputSink()
        let writer = makeInputWriter(
            sink: sink,
            maximumInputWriteSize: 8,
            maximumPendingBytes: 16
        )
        try await writer.enqueue(Data(repeating: 0x61, count: 8))
        try await sink.waitUntilWriteCalled(count: 1)
        try await writer.enqueue(Data(repeating: 0x62, count: 4))
        let closeTask = makeTrackedTask {
            await writer.closeInput()
        }

        try await boundedValue(of: closeTask)

        let writeCalls = await sink.writeCallCount()
        let completedWrites = await sink.completedWriteCount()
        let closeCalls = await sink.closeCallCount()
        let pending = writer.pendingWork()
        XCTAssertEqual(writeCalls, 1)
        XCTAssertEqual(completedWrites, 0)
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(pending.writes, 0)
        XCTAssertEqual(pending.bytes, 0)
    }

    func testManagedShutdownSignalsBeforeBlockedWriterIsReleased() async throws {
        let child = FakeManagedChildProcess()
        let scheduler = ManualTimeoutScheduler()
        let signaler = ScriptedProcessSignaler(
            child: child,
            terminateActions: [.confirmExit(0)],
            forceActions: []
        )
        let sink = ControlledProcessInputSink(
            closeUnblocksWrite: false,
            abortUnblocksWrite: false
        )
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/test/fake-child"),
                arguments: [],
                maximumPendingInputWrites: 4,
                maximumInputWriteSize: 8,
                maximumPendingInputBytes: 16
            ),
            shutdownScheduler: scheduler,
            processSignaler: signaler,
            processFactory: FakeManagedChildProcessFactory(child: child),
            inputOperations: makeInputOperations(sink: sink),
            terminationGracePeriod: .seconds(30),
            killGracePeriod: .seconds(30)
        )
        try await process.start()
        try await process.send(Data(repeating: 0x61, count: 8))
        try await sink.waitUntilWriteCalled(count: 1)
        try await process.send(Data(repeating: 0x62, count: 4))
        let shutdownTask = makeTrackedTask {
            try await process.shutdown()
        }

        try await sink.waitUntilCloseCalled()
        try await scheduler.waitUntilScheduled()
        let eventsBeforeGrace = await signaler.recordedEvents()
        let completedBeforeGrace =
            await shutdownTask.state.isCompleted()
        XCTAssertTrue(eventsBeforeGrace.isEmpty)
        XCTAssertFalse(completedBeforeGrace)

        await scheduler.fire()
        try await signaler.waitUntilEventCount(1)
        let eventsBeforeWriterRelease = await signaler.recordedEvents()
        let completedBeforeWriterRelease =
            await shutdownTask.state.isCompleted()
        let writeCompletionsBeforeRelease =
            await sink.writeCompletionCount()
        XCTAssertEqual(eventsBeforeWriterRelease, [.terminate(4_242)])
        XCTAssertFalse(completedBeforeWriterRelease)
        XCTAssertEqual(writeCompletionsBeforeRelease, 0)
        do {
            try await process.send(Data("late".utf8))
            XCTFail("Stopping process must reject new writes")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }

        await sink.releaseWrite()
        try await boundedValue(of: shutdownTask)

        let writeCalls = await sink.writeCallCount()
        let completedWrites = await sink.completedWriteCount()
        let writeCompletions = await sink.writeCompletionCount()
        let events = await signaler.recordedEvents()
        let retained = await process.hasProcessOwnership()
        let writerError = await process.completedInputWriteError()
        XCTAssertEqual(writeCalls, 1)
        XCTAssertEqual(completedWrites, 0)
        XCTAssertEqual(writeCompletions, 1)
        XCTAssertEqual(events, [.terminate(4_242)])
        XCTAssertEqual(writerError, .transportClosed)
        XCTAssertFalse(retained)
    }

    func testManagedShutdownAbortsBlockedWriterAfterObservedExit() async throws {
        let child = FakeManagedChildProcess()
        let scheduler = ManualTimeoutScheduler()
        let signaler = ScriptedProcessSignaler(
            child: child,
            terminateActions: [.confirmExit(0)],
            forceActions: []
        )
        let sink = ControlledProcessInputSink(
            closeUnblocksWrite: false,
            abortUnblocksWrite: true
        )
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/test/fake-child"),
                arguments: [],
                maximumPendingInputWrites: 1,
                maximumInputWriteSize: 8,
                maximumPendingInputBytes: 8
            ),
            shutdownScheduler: scheduler,
            processSignaler: signaler,
            processFactory: FakeManagedChildProcessFactory(child: child),
            inputOperations: makeInputOperations(sink: sink),
            terminationGracePeriod: .seconds(30),
            killGracePeriod: .seconds(30)
        )
        try await process.start()
        try await process.send(Data(repeating: 0x61, count: 8))
        try await sink.waitUntilWriteCalled(count: 1)

        let shutdownTask = makeTrackedTask {
            try await process.shutdown()
        }
        try await sink.waitUntilCloseCalled()
        try await scheduler.waitUntilScheduled()
        await scheduler.fire()

        try await boundedValue(of: shutdownTask)

        let events = await signaler.recordedEvents()
        let abortCalls = await sink.abortCallCount()
        let writeCompletions = await sink.writeCompletionCount()
        let writerError = await process.completedInputWriteError()
        XCTAssertEqual(events, [.terminate(4_242)])
        XCTAssertEqual(abortCalls, 1)
        XCTAssertEqual(writeCompletions, 1)
        XCTAssertEqual(writerError, .transportClosed)
    }

    func testShutdownRejectsWritesBeforeCleanupTaskBegins() async throws {
        let child = FakeManagedChildProcess()
        let scheduler = ManualTimeoutScheduler()
        let signaler = ScriptedProcessSignaler(
            child: child,
            terminateActions: [.confirmExit(0)],
            forceActions: []
        )
        let shutdownGate = ControlledShutdownStartGate()
        let sink = ControlledProcessInputSink()
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/test/fake-child"),
                arguments: []
            ),
            shutdownScheduler: scheduler,
            processSignaler: signaler,
            processFactory: FakeManagedChildProcessFactory(child: child),
            inputOperations: makeInputOperations(sink: sink),
            shutdownStartGate: {
                await shutdownGate.wait()
            },
            terminationGracePeriod: .seconds(30),
            killGracePeriod: .seconds(30)
        )
        try await process.start()

        let shutdownTask = makeTrackedTask {
            try await process.shutdown()
        }
        await shutdownGate.waitUntilEntered()

        do {
            try await process.send(Data("late".utf8))
            XCTFail("Shutdown must synchronously reject new writes")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let eventsBeforeCleanup = await signaler.recordedEvents()
        XCTAssertTrue(eventsBeforeCleanup.isEmpty)

        await shutdownGate.release()
        try await scheduler.waitUntilScheduled()
        await scheduler.fire()
        try await boundedValue(of: shutdownTask)

        let events = await signaler.recordedEvents()
        XCTAssertEqual(events, [.terminate(4_242)])
    }

    func testSendSuspendedBeforeShutdownCannotEnterWriterQueue() async throws {
        let child = FakeManagedChildProcess(
            suspendsTerminationStatus: true
        )
        let scheduler = ManualTimeoutScheduler()
        let signaler = ScriptedProcessSignaler(
            child: child,
            terminateActions: [.confirmExit(0)],
            forceActions: []
        )
        let shutdownGate = ControlledShutdownStartGate()
        let sink = ControlledProcessInputSink()
        let process = ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/test/fake-child"),
                arguments: [],
                maximumPendingInputWrites: 1,
                maximumInputWriteSize: 8,
                maximumPendingInputBytes: 8
            ),
            shutdownScheduler: scheduler,
            processSignaler: signaler,
            processFactory: FakeManagedChildProcessFactory(child: child),
            inputOperations: makeInputOperations(sink: sink),
            shutdownStartGate: {
                await shutdownGate.wait()
            },
            terminationGracePeriod: .seconds(30),
            killGracePeriod: .seconds(30)
        )
        try await process.start()

        let sendTask = makeTrackedTask {
            try await process.send(Data(repeating: 0x61, count: 8))
        }
        try await child.waitUntilTerminationStatusCalled()
        let shutdownTask = makeTrackedTask {
            try await process.shutdown()
        }
        await shutdownGate.waitUntilEntered()

        let pendingBeforeRelease = await process.pendingInputWork()
        let writeCallsBeforeRelease = await sink.writeCallCount()
        XCTAssertEqual(pendingBeforeRelease.writes, 0)
        XCTAssertEqual(pendingBeforeRelease.bytes, 0)
        XCTAssertEqual(writeCallsBeforeRelease, 0)

        await child.releaseTerminationStatus()
        do {
            try await boundedValue(of: sendTask)
            XCTFail("Send suspended before shutdown must be rejected")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }

        let pendingAfterSend = await process.pendingInputWork()
        let writeCallsAfterSend = await sink.writeCallCount()
        XCTAssertEqual(pendingAfterSend.writes, 0)
        XCTAssertEqual(pendingAfterSend.bytes, 0)
        XCTAssertEqual(writeCallsAfterSend, 0)

        await shutdownGate.release()
        try await scheduler.waitUntilScheduled()
        await scheduler.fire()
        try await boundedValue(of: shutdownTask)
    }

    private func assertShutdownRacingInvalidLaunch(
        outcome: FakeManagedChildProcess.StartOutcome
    ) async throws {
        let child = FakeManagedChildProcess(
            startOutcome: outcome,
            suspendsStart: true
        )
        let signaler = ScriptedProcessSignaler(
            child: child,
            terminateActions: [],
            forceActions: []
        )
        let process = makeLongRunningProcess(
            child: child,
            scheduler: ControlledTimeoutScheduler(),
            signaler: signaler
        )
        let startTask = makeTrackedTask {
            try await process.start()
        }
        try await child.waitUntilStartCalled()
        let shutdownTask = makeTrackedTask {
            try await process.shutdown()
        }
        try await shutdownTask.state.waitUntilBegan()
        let shutdownCompletedBeforeLaunch =
            await shutdownTask.state.isCompleted()
        XCTAssertFalse(shutdownCompletedBeforeLaunch)

        await child.releaseStart()

        let startResult = try await boundedResult(of: startTask)
        switch startResult {
        case .success:
            XCTFail("Invalid launch must not succeed")
        case .failure(let error):
            guard case .processLaunchFailed = error as? JSONRPCError else {
                return XCTFail("Unexpected launch error: \(error)")
            }
        }
        try await boundedValue(of: shutdownTask)
        let events = await signaler.recordedEvents()
        let retained = await process.hasProcessOwnership()
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(retained)
        do {
            try await process.send(Data("not-running".utf8))
            XCTFail("Invalid launch must never become running")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
    }

    private func makeInputWriter(
        sink: ControlledProcessInputSink,
        maximumInputWriteSize: Int,
        maximumPendingBytes: Int
    ) -> ProcessInputWriter {
        ProcessInputWriter(
            operations: makeInputOperations(sink: sink),
            maximumPendingWrites: 4,
            maximumInputWriteSize: maximumInputWriteSize,
            maximumPendingBytes: maximumPendingBytes,
            onFailure: { _ in }
        )
    }

    private func makeInputOperations(
        sink: ControlledProcessInputSink
    ) -> ProcessInputOperations {
        ProcessInputOperations(
            write: { data in
                try await sink.write(data)
            },
            close: {
                await sink.close()
            },
            abort: {
                await sink.abort()
            }
        )
    }

    private func waitUntilReadability(
        _ process: ManagedProcess,
        timeout: Duration = .seconds(2),
        condition: @Sendable (
            (stdout: Int, stderr: Int, stdoutEOF: Int, stderrEOF: Int)
        ) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let probe = await process.readabilityProbe()
            if condition(probe) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let probe = await process.readabilityProbe()
        XCTFail("Readability probe condition not reached: \(probe)")
    }

    private func withOuterTimeout(
        _ timeout: DispatchTimeInterval,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let pair = AsyncStream<OuterTimeoutOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let operationTask = Task {
            do {
                try await operation()
                pair.continuation.yield(.completed)
            } catch let error as JSONRPCError {
                pair.continuation.yield(.failed(error))
            } catch {
                pair.continuation.yield(.failed(.transportClosed))
            }
        }
        let timeoutWork = DispatchWorkItem {
            pair.continuation.yield(.timedOut)
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWork
        )
        var iterator = pair.stream.makeAsyncIterator()
        let outcome = await iterator.next()
        operationTask.cancel()
        timeoutWork.cancel()
        pair.continuation.finish()

        switch outcome {
        case .completed:
            return
        case .failed(let error):
            throw error
        case .timedOut, .none:
            throw TransportTestProbeError.conditionNotReached(
                "Real process shutdown exceeded its outer timeout"
            )
        }
    }

    private func withOuterValueTimeout<Value: Sendable>(
        _ timeout: DispatchTimeInterval,
        operation: @escaping @Sendable () async -> Value
    ) async throws -> Value {
        let pair = AsyncStream<OuterValueTimeoutOutcome<Value>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let operationTask = Task {
            pair.continuation.yield(
                .value(await operation())
            )
        }
        let timeoutWork = DispatchWorkItem {
            pair.continuation.yield(.timedOut)
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWork
        )
        var iterator = pair.stream.makeAsyncIterator()
        let outcome = await iterator.next()
        operationTask.cancel()
        timeoutWork.cancel()
        pair.continuation.finish()

        switch outcome {
        case .value(let value):
            return value
        case .timedOut, .none:
            throw TransportTestProbeError.conditionNotReached(
                "Real process output exceeded its outer timeout"
            )
        }
    }

    private nonisolated static func readFirstProcessIdentifier(
        from stream: AsyncThrowingStream<Data, Error>
    ) async -> Int32? {
        var line = Data()
        do {
            for try await chunk in stream {
                line.append(chunk)
                if let newline = line.firstIndex(of: 0x0A) {
                    let value = String(
                        decoding: line[..<newline],
                        as: UTF8.self
                    )
                    return Int32(value)
                }
                if line.count > 64 {
                    return nil
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func terminateAndConfirmExit(
        _ processIdentifier: Int32
    ) async throws {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        source.setEventHandler {
            pair.continuation.yield()
            pair.continuation.finish()
        }
        source.resume()
        defer {
            source.cancel()
            pair.continuation.finish()
        }

        errno = 0
        let signalResult = Darwin.kill(processIdentifier, SIGKILL)
        if signalResult == -1, errno != ESRCH {
            throw TransportTestProbeError.conditionNotReached(
                "Could not terminate retained-stdin descendant"
            )
        }
        if signalResult == 0 {
            try await withOuterTimeout(.seconds(5)) {
                var iterator = pair.stream.makeAsyncIterator()
                guard await iterator.next() != nil else {
                    throw JSONRPCError.transportClosed
                }
            }
        }
    }

    private func makeLongRunningProcess(
        child: FakeManagedChildProcess,
        scheduler: any JSONRPCTimeoutScheduler,
        signaler: any ProcessSignaling
    ) -> ManagedProcess {
        ManagedProcess(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/test/fake-child"),
                arguments: []
            ),
            shutdownScheduler: scheduler,
            processSignaler: signaler,
            processFactory: FakeManagedChildProcessFactory(child: child),
            terminationGracePeriod: .seconds(30),
            killGracePeriod: .seconds(30)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func openFIFOForWriting(
        _ fifo: URL,
        maximumYields: Int = 10_000
    ) async throws -> Int32 {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            let descriptor = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                return descriptor
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "FIFO reader was not ready"
        )
    }
}

private actor RecordingRealTransport: JSONRPCTransport {
    private let base: any JSONRPCTransport
    private var sendCalls = 0

    init(base: any JSONRPCTransport) {
        self.base = base
    }

    func start() async throws {
        try await base.start()
    }

    func send(_ data: Data) async throws {
        sendCalls += 1
        try await base.send(data)
    }

    func incomingBytes() async -> AsyncThrowingStream<Data, Error> {
        await base.incomingBytes()
    }

    func shutdown() async throws {
        try await base.shutdown()
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
            "Real transport send was not called"
        )
    }
}

private actor ScriptedProcessTimeoutScheduler: JSONRPCTimeoutScheduler {
    enum Action: Sendable {
        case fire
        case suspend
    }

    private var actions: [Action]

    init(actions: [Action]) {
        self.actions = actions
    }

    func wait(for duration: Duration) async throws {
        guard !actions.isEmpty else {
            throw TransportTestProbeError.conditionNotReached(
                "No scripted process timeout action remained"
            )
        }
        let action = actions.removeFirst()
        switch action {
        case .fire:
            return
        case .suspend:
            try await ControlledTimeoutScheduler().wait(for: duration)
        }
    }
}

private actor FakeManagedChildProcess: ManagedChildProcess {
    enum StartOutcome: Sendable {
        case succeed(Int32)
        case fail
    }

    private let startOutcome: StartOutcome
    private let suspendsStart: Bool
    private let suspendsAfterLaunch: Bool
    private let suspendsTerminationStatus: Bool
    private let startGate: AsyncStream<Void>
    private let startGateContinuation: AsyncStream<Void>.Continuation
    private let postLaunchGate: AsyncStream<Void>
    private let postLaunchGateContinuation: AsyncStream<Void>.Continuation
    private let terminationStatusGate: AsyncStream<Void>
    private let terminationStatusGateContinuation:
        AsyncStream<Void>.Continuation
    private let terminationStatusCalled: AsyncStream<Void>
    private let terminationStatusCalledContinuation:
        AsyncStream<Void>.Continuation
    private var isRunning = false
    private var positiveLaunchProduced = false
    private var status: Int32?
    private var startCalls = 0
    private var didSuspendTerminationStatus = false
    private var terminationHandler: (@Sendable (Int32) -> Void)?

    init(
        startOutcome: StartOutcome = .succeed(4_242),
        suspendsStart: Bool = false,
        suspendsAfterLaunch: Bool = false,
        suspendsTerminationStatus: Bool = false
    ) {
        self.startOutcome = startOutcome
        self.suspendsStart = suspendsStart
        self.suspendsAfterLaunch = suspendsAfterLaunch
        self.suspendsTerminationStatus = suspendsTerminationStatus
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        startGate = pair.stream
        startGateContinuation = pair.continuation
        let postLaunchPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        postLaunchGate = postLaunchPair.stream
        postLaunchGateContinuation = postLaunchPair.continuation
        let terminationStatusPair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        terminationStatusGate = terminationStatusPair.stream
        terminationStatusGateContinuation =
            terminationStatusPair.continuation
        let terminationStatusCalledPair =
            AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        terminationStatusCalled = terminationStatusCalledPair.stream
        terminationStatusCalledContinuation =
            terminationStatusCalledPair.continuation
    }

    func start(
        configuration: ManagedProcessConfiguration,
        standardInput: Pipe,
        standardOutput: Pipe,
        standardError: Pipe,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) async throws -> Int32 {
        startCalls += 1
        terminationHandler = onTermination
        if suspendsStart {
            var iterator = startGate.makeAsyncIterator()
            _ = await iterator.next()
        }
        if suspendsAfterLaunch,
           case .succeed(let processIdentifier) = startOutcome {
            isRunning = processIdentifier > 0
            positiveLaunchProduced = processIdentifier > 0
            var iterator = postLaunchGate.makeAsyncIterator()
            _ = await iterator.next()
            return processIdentifier
        }
        try Task.checkCancellation()
        switch startOutcome {
        case .succeed(let processIdentifier):
            isRunning = processIdentifier > 0
            return processIdentifier
        case .fail:
            throw JSONRPCError.transportClosed
        }
    }

    func terminationStatusIfExited() async -> Int32? {
        if suspendsTerminationStatus, !didSuspendTerminationStatus {
            didSuspendTerminationStatus = true
            terminationStatusCalledContinuation.yield()
            terminationStatusCalledContinuation.finish()
            var iterator = terminationStatusGate.makeAsyncIterator()
            _ = await iterator.next()
        }
        return isRunning ? nil : status
    }

    func waitUntilTerminationStatusCalled() async throws {
        var iterator = terminationStatusCalled.makeAsyncIterator()
        guard await iterator.next() != nil else {
            throw TransportTestProbeError.conditionNotReached(
                "Termination-status query did not begin"
            )
        }
    }

    func releaseTerminationStatus() {
        terminationStatusGateContinuation.yield()
        terminationStatusGateContinuation.finish()
    }

    func confirmExit(status: Int32) {
        guard isRunning else {
            return
        }
        isRunning = false
        self.status = status
        terminationHandler?(status)
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
            "Child start was not called"
        )
    }

    func releaseStart() {
        startGateContinuation.yield()
        startGateContinuation.finish()
    }

    func waitUntilPositiveLaunch(maximumYields: Int = 10_000) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if positiveLaunchProduced {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Child did not produce a positive launch"
        )
    }

    func releasePostLaunch() {
        postLaunchGateContinuation.yield()
        postLaunchGateContinuation.finish()
    }
}

private struct FakeManagedChildProcessFactory: ManagedChildProcessFactory {
    let child: FakeManagedChildProcess

    func makeProcess() -> any ManagedChildProcess {
        child
    }
}

private actor ScriptedProcessSignaler: ProcessSignaling {
    enum Event: Equatable, Sendable {
        case terminate(Int32)
        case forceTerminate(Int32)
    }

    enum Action: Sendable {
        case reportSuccess
        case reportFailure
        case confirmExit(Int32)
    }

    private let child: FakeManagedChildProcess
    private var terminateActions: [Action]
    private var forceActions: [Action]
    private var events: [Event] = []
    private var forceCalls = 0

    init(
        child: FakeManagedChildProcess,
        terminateActions: [Action],
        forceActions: [Action]
    ) {
        self.child = child
        self.terminateActions = terminateActions
        self.forceActions = forceActions
    }

    func terminate(processIdentifier: Int32) async -> Bool {
        events.append(.terminate(processIdentifier))
        guard !terminateActions.isEmpty else {
            return false
        }
        return await execute(terminateActions.removeFirst())
    }

    func forceTerminate(processIdentifier: Int32) async -> Bool {
        events.append(.forceTerminate(processIdentifier))
        forceCalls += 1
        guard !forceActions.isEmpty else {
            return false
        }
        return await execute(forceActions.removeFirst())
    }

    func forceCallCount() -> Int {
        forceCalls
    }

    func recordedEvents() -> [Event] {
        events
    }

    func waitUntilEventCount(
        _ count: Int,
        maximumYields: Int = 10_000
    ) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if events.count >= count {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Expected process signal event was not recorded"
        )
    }

    private func execute(_ action: Action) async -> Bool {
        switch action {
        case .reportSuccess:
            return true
        case .reportFailure:
            return false
        case .confirmExit(let status):
            await child.confirmExit(status: status)
            return true
        }
    }
}

private actor BlockingProcessSignaler: ProcessSignaling {
    private let child: FakeManagedChildProcess
    private let gate: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var terminateCalls = 0

    init(child: FakeManagedChildProcess) {
        self.child = child
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        gate = pair.stream
        continuation = pair.continuation
    }

    func terminate(processIdentifier: Int32) async -> Bool {
        terminateCalls += 1
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        await child.confirmExit(status: 0)
        return true
    }

    func forceTerminate(processIdentifier: Int32) async -> Bool {
        await child.confirmExit(status: 9)
        return true
    }

    func waitUntilTerminateCalled(maximumYields: Int = 10_000) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if terminateCalls > 0 {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Terminate signal was not requested"
        )
    }

    func releaseTermination() {
        continuation.yield()
        continuation.finish()
    }

    func terminateCallCount() -> Int {
        terminateCalls
    }
}

private actor ControlledProcessInputSink {
    private let closeUnblocksWrite: Bool
    private let abortUnblocksWrite: Bool
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var writeCalls = 0
    private var completedWrites = 0
    private var writeCompletions = 0
    private var closeCalls = 0
    private var abortCalls = 0

    init(
        closeUnblocksWrite: Bool = true,
        abortUnblocksWrite: Bool = true
    ) {
        self.closeUnblocksWrite = closeUnblocksWrite
        self.abortUnblocksWrite = abortUnblocksWrite
    }

    func write(_ data: Data) async throws {
        writeCalls += 1
        await withCheckedContinuation { continuation in
            writeContinuation = continuation
        }
        writeCompletions += 1
        try Task.checkCancellation()
        completedWrites += 1
    }

    func close() {
        closeCalls += 1
        if closeUnblocksWrite {
            resumeWrite()
        }
    }

    func abort() {
        abortCalls += 1
        if abortUnblocksWrite {
            resumeWrite()
        }
    }

    func releaseWrite() {
        resumeWrite()
    }

    func waitUntilWriteCalled(
        count: Int,
        maximumYields: Int = 10_000
    ) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if writeCalls >= count {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Input write was not called"
        )
    }

    func writeCallCount() -> Int {
        writeCalls
    }

    func completedWriteCount() -> Int {
        completedWrites
    }

    func closeCallCount() -> Int {
        closeCalls
    }

    func abortCallCount() -> Int {
        abortCalls
    }

    func writeCompletionCount() -> Int {
        writeCompletions
    }

    func waitUntilCloseCalled(maximumYields: Int = 10_000) async throws {
        for _ in 0..<maximumYields {
            try Task.checkCancellation()
            if closeCalls > 0 {
                return
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Input close was not requested"
        )
    }

    private func resumeWrite() {
        let continuation = writeContinuation
        writeContinuation = nil
        continuation?.resume()
    }
}

private actor ControlledShutdownStartGate {
    private let gate: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var enteredContinuations:
        [CheckedContinuation<Void, Never>] = []
    private var didEnter = false

    init() {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        gate = pair.stream
        continuation = pair.continuation
    }

    func wait() async {
        didEnter = true
        let continuations = enteredContinuations
        enteredContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilEntered() async {
        if didEnter {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func release() {
        continuation.yield()
        continuation.finish()
    }
}

private enum OuterTimeoutOutcome: Sendable {
    case completed
    case failed(JSONRPCError)
    case timedOut
}

private enum OuterValueTimeoutOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}
