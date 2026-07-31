import Foundation
import XCTest

@testable import UsageIslandPrototype

final class CodexAppServerClientTests: XCTestCase {
    func testInitializeRemoteFailureClosesOuterClient() async throws {
        let transport = FakeJSONRPCTransport()
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        let initialize = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        await transport.emit(
            try errorResponse(
                id: XCTUnwrap(initialize.id),
                code: -32_010,
                message: "sensitive remote detail"
            )
        )

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected initialize failure")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .remoteError(code: -32_010))
        }
        let shutdownCallCount = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCallCount, 1)
    }

    func testInitializeTimeoutClosesOuterClientWithoutRealSleep() async {
        let transport = FakeJSONRPCTransport()
        let client = makeClient(
            transport: transport,
            scheduler: ImmediateTimeoutScheduler()
        )

        do {
            try await client.start()
            XCTFail("Expected initialize timeout")
        } catch {
            guard case .requestTimedOut = error as? JSONRPCError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let shutdownCallCount = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCallCount, 1)
    }

    func testProcessExitDuringInitializeIsPropagated() async throws {
        let transport = FakeJSONRPCTransport()
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        _ = try await transport.dataSent(at: 0)

        await transport.finish(
            throwing: JSONRPCError.processExited(status: 17)
        )

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected process exit")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .processExited(status: 17))
        }
    }

    func testShutdownDuringInitializePreventsInitializedNotification() async throws {
        let transport = FakeJSONRPCTransport()
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        _ = try await transport.dataSent(at: 0)

        try await client.shutdown()

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected shutdown to win")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let sentMessageCount = await transport.sentMessageCount()
        XCTAssertEqual(sentMessageCount, 1)
    }

    func testShutdownDuringSuspendedTransportStartupWins() async throws {
        let transport = FakeJSONRPCTransport(suspendsStart: true)
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        try await transport.waitUntilStartCalled()

        try await client.shutdown()

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected shutdown to win")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let sentMessageCount = await transport.sentMessageCount()
        let shutdownCallCount = await transport.shutdownCallCount()
        XCTAssertEqual(sentMessageCount, 0)
        XCTAssertEqual(shutdownCallCount, 1)
    }

    func testShutdownDuringSuspendedFactoryCreationDisposesNewTransport() async throws {
        let transport = FakeJSONRPCTransport()
        let factory = RecordingCodexTransportFactory(
            transport: transport,
            suspendsCreation: true
        )
        let client = CodexAppServerClient(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/test/codex")
            ),
            transportFactory: factory,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        try await factory.waitUntilCreationCalled()

        let firstShutdown = makeTrackedTask {
            try await client.shutdown()
        }
        let secondShutdown = makeTrackedTask {
            try await client.shutdown()
        }
        try await firstShutdown.state.waitUntilBegan()
        try await secondShutdown.state.waitUntilBegan()
        try await waitUntilStopped(client)
        let firstCompletedBeforeFactoryRelease =
            await firstShutdown.state.isCompleted()
        let secondCompletedBeforeFactoryRelease =
            await secondShutdown.state.isCompleted()
        XCTAssertFalse(firstCompletedBeforeFactoryRelease)
        XCTAssertFalse(secondCompletedBeforeFactoryRelease)

        await factory.releaseCreation()

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected shutdown to win")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        try await boundedValue(of: firstShutdown)
        try await boundedValue(of: secondShutdown)
        let shutdownCallCount = await transport.shutdownCallCount()
        let sentMessageCount = await transport.sentMessageCount()
        XCTAssertEqual(shutdownCallCount, 1)
        XCTAssertEqual(sentMessageCount, 0)
    }

    func testOuterShutdownIsIdempotent() async throws {
        let transport = FakeJSONRPCTransport()
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        let initialize = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(initialize.id),
                result: validInitializeResult()
            )
        )
        try await boundedValue(of: startTask)
        _ = try await transport.dataSent(at: 1)

        try await client.shutdown()
        try await client.shutdown()

        let shutdownCallCount = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCallCount, 1)
    }

    func testHandshakeUsesArgumentArrayAndSendsInitializedAfterResponse() async throws {
        let transport = FakeJSONRPCTransport()
        let factory = RecordingCodexTransportFactory(transport: transport)
        let scheduler = ControlledTimeoutScheduler()
        let executable = URL(fileURLWithPath: "/Users/test/.local/bin/codex")
        let client = CodexAppServerClient(
            configuration: .init(executableURL: executable, clientVersion: "2.0"),
            transportFactory: factory,
            timeoutScheduler: scheduler
        )

        let startTask = makeTrackedTask {
            try await client.start()
        }
        let initializeData = try await transport.dataSent(at: 0)
        let initialize = try decodeOutbound(initializeData)
        XCTAssertEqual(initialize.method, "initialize")
        XCTAssertEqual(
            initialize.params,
            .object([
                "clientInfo": .object([
                    "name": .string("Usage Island"),
                    "version": .string("2.0")
                ])
            ])
        )

        do {
            _ = try await client.request(method: "synthetic/pre-handshake")
            XCTFail("Expected pre-handshake rejection")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .notInitialized)
        }
        let sentMessageCountBeforeInitializeResponse = await transport.sentMessageCount()
        XCTAssertEqual(sentMessageCountBeforeInitializeResponse, 1)

        await transport.emit(
            try successResponse(
                id: XCTUnwrap(initialize.id),
                result: validInitializeResult()
            )
        )
        try await boundedValue(of: startTask)

        let initialized = try decodeOutbound(
            try await transport.dataSent(at: 1)
        )
        XCTAssertNil(initialized.id)
        XCTAssertEqual(initialized.method, "initialized")
        XCTAssertNil(initialized.params)

        let processConfiguration = await factory.configuration(at: 0)
        XCTAssertEqual(processConfiguration?.executableURL, executable)
        XCTAssertEqual(processConfiguration?.arguments, ["app-server"])
        XCTAssertFalse(processConfiguration?.arguments.contains("/bin/sh") == true)
        XCTAssertFalse(processConfiguration?.arguments.contains("-c") == true)
        try await client.shutdown()
    }

    func testInitializeResponseAcceptsUnknownFutureProperties() async throws {
        let transport = FakeJSONRPCTransport()
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        let initialize = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        var object = validInitializeObject()
        object["futureProperty"] = .object([
            "nested": .array([.integer(1), .bool(true)])
        ])
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(initialize.id),
                result: .object(object)
            )
        )

        try await boundedValue(of: startTask)
        let initialized = try decodeOutbound(
            try await transport.dataSent(at: 1)
        )
        XCTAssertEqual(initialized.method, "initialized")
        try await client.shutdown()
    }

    func testInitializeResponseRejectsMissingResult() async throws {
        try await assertInvalidInitializeResponse(result: nil)
    }

    func testMalformedInitializeResponsePreservesMalformedJSON() async throws {
        let transport = FakeJSONRPCTransport()
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        _ = try await transport.dataSent(at: 0)

        var malformed = Data(
            #"{"id":1,"result":"synthetic-private-value""#.utf8
        )
        malformed.append(0x0A)
        await transport.emit(malformed)

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected malformed initialize response")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .malformedJSON)
            XCTAssertFalse(
                error.localizedDescription.contains(
                    "synthetic-private-value"
                )
            )
        }
        let sentCount = await transport.sentMessageCount()
        let shutdownCount = await transport.shutdownCallCount()
        let sendsInFlight = await transport.sendsCurrentlyInFlight()
        XCTAssertEqual(sentCount, 1)
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(sendsInFlight, 0)
        do {
            _ = try await client.request(method: "must/not-be-ready")
            XCTFail("Malformed initialize response must never publish ready")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }

        try await client.shutdown()
        try await client.shutdown()
        let finalShutdownCount = await transport.shutdownCallCount()
        XCTAssertEqual(finalShutdownCount, 1)
    }

    func testInitializeResponseRejectsInvalidTopLevelShapes() async throws {
        let invalidResults: [JSONValue] = [
            .object([:]),
            .null,
            .string("synthetic-scalar"),
            .array([])
        ]

        for result in invalidResults {
            try await assertInvalidInitializeResponse(result: result)
        }
    }

    func testInitializeResponseRejectsEachMissingRequiredField() async throws {
        for field in CodexInitializeField.allCases {
            var object = validInitializeObject()
            object.removeValue(forKey: field.rawValue)
            try await assertInvalidInitializeResponse(
                result: .object(object)
            )
        }
    }

    func testInitializeResponseRejectsEachWrongRequiredFieldType() async throws {
        for field in CodexInitializeField.allCases {
            var object = validInitializeObject()
            object[field.rawValue] = .integer(17)
            try await assertInvalidInitializeResponse(
                result: .object(object)
            )
        }
    }

    func testInitializeIsExactlyOnce() async throws {
        let transport = FakeJSONRPCTransport()
        let factory = RecordingCodexTransportFactory(transport: transport)
        let client = CodexAppServerClient(
            configuration: .init(executableURL: URL(fileURLWithPath: "/test/codex")),
            transportFactory: factory,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        let initialize = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(initialize.id),
                result: validInitializeResult()
            )
        )
        try await boundedValue(of: startTask)
        _ = try await transport.dataSent(at: 1)

        do {
            try await client.start()
            XCTFail("Expected already initialized")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .alreadyInitialized)
        }
        try await client.shutdown()
    }

    func testNormalRequestIsAvailableAfterHandshake() async throws {
        let transport = FakeJSONRPCTransport()
        let client = CodexAppServerClient(
            configuration: .init(executableURL: URL(fileURLWithPath: "/test/codex")),
            transportFactory: RecordingCodexTransportFactory(transport: transport),
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        let initialize = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(initialize.id),
                result: validInitializeResult()
            )
        )
        try await boundedValue(of: startTask)
        _ = try await transport.dataSent(at: 1)

        let requestTask = makeTrackedTask {
            try await client.request(method: "synthetic/read")
        }
        let request = try decodeOutbound(
            try await transport.dataSent(at: 2)
        )
        await transport.emit(
            try successResponse(id: XCTUnwrap(request.id), result: .integer(42))
        )

        let result = try await boundedValue(of: requestTask)
        XCTAssertEqual(result, .integer(42))
        try await client.shutdown()
    }

    func testPreCancelledOuterStartupDoesNotCreateTransport() async {
        let transport = FakeJSONRPCTransport()
        let factory = RecordingCodexTransportFactory(transport: transport)
        let client = CodexAppServerClient(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/test/codex")
            ),
            transportFactory: factory,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try await client.start()
        }

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected startup cancellation")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .startupCancelled)
        }
        let creationCalls = await factory.creationCallCount()
        XCTAssertEqual(creationCalls, 0)
    }

    func testCancellationDuringFactoryCreationReturnsTypedStartupError() async throws {
        let transport = FakeJSONRPCTransport()
        let factory = RecordingCodexTransportFactory(
            transport: transport,
            suspendsCreation: true
        )
        let client = CodexAppServerClient(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/test/codex")
            ),
            transportFactory: factory,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        try await factory.waitUntilCreationCalled()

        startTask.task.cancel()

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected startup cancellation")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .startupCancelled)
        }
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
    }

    func testCancellationDuringTransportStartupReturnsTypedStartupError() async throws {
        let transport = FakeJSONRPCTransport(suspendsStart: true)
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        try await transport.waitUntilStartCalled()

        startTask.task.cancel()

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected startup cancellation")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .startupCancelled)
        }
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
    }

    func testConcurrentOuterShutdownCallsAwaitSameBarrier() async throws {
        let transport = FakeJSONRPCTransport(suspendsShutdown: true)
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        let initialize = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(initialize.id),
                result: validInitializeResult()
            )
        )
        try await boundedValue(of: startTask)
        _ = try await transport.dataSent(at: 1)

        let first = makeTrackedTask {
            try await client.shutdown()
        }
        try await transport.waitUntilShutdownCalled()
        let second = makeTrackedTask {
            try await client.shutdown()
        }
        try await second.state.waitUntilBegan()

        let secondCompleted = await second.state.isCompleted()
        XCTAssertFalse(secondCompleted)
        await transport.releaseShutdown()
        try await boundedValue(of: first)
        try await boundedValue(of: second)
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
    }

    func testCancellationDuringSuspendedInitializeCleansUpAndNeverPublishesReady() async throws {
        let transport = FakeJSONRPCTransport(suspendedSendIndex: 0)
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        _ = try await transport.dataSent(at: 0)

        startTask.task.cancel()

        let result = try await boundedResult(of: startTask)
        switch result {
        case .success:
            XCTFail("Expected initialize cancellation")
        case .failure(let error):
            XCTAssertEqual(error as? JSONRPCError, .startupCancelled)
        }
        let inFlight = await transport.sendsCurrentlyInFlight()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(inFlight, 0)
        XCTAssertEqual(shutdownCalls, 1)
        do {
            _ = try await client.request(method: "must/not/be-ready")
            XCTFail("Cancelled initialize must not publish ready")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
    }

    func testCancellationDuringSuspendedInitializedNotificationNeverPublishesReady() async throws {
        let transport = FakeJSONRPCTransport(suspendedSendIndex: 1)
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        let initialize = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(initialize.id),
                result: validInitializeResult()
            )
        )
        _ = try await transport.dataSent(at: 1)

        startTask.task.cancel()

        let result = try await boundedResult(of: startTask)
        switch result {
        case .success:
            XCTFail("Expected initialized notification cancellation")
        case .failure(let error):
            XCTAssertEqual(error as? JSONRPCError, .startupCancelled)
        }
        let inFlight = await transport.sendsCurrentlyInFlight()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(inFlight, 0)
        XCTAssertEqual(shutdownCalls, 1)
        do {
            _ = try await client.request(method: "must/not-be-ready")
            XCTFail("Cancelled notification must not publish ready")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
    }

    private func makeClient(
        transport: FakeJSONRPCTransport,
        scheduler: any JSONRPCTimeoutScheduler
    ) -> CodexAppServerClient {
        CodexAppServerClient(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/test/codex")
            ),
            transportFactory: RecordingCodexTransportFactory(
                transport: transport
            ),
            timeoutScheduler: scheduler
        )
    }

    private func assertInvalidInitializeResponse(
        result: JSONValue?
    ) async throws {
        let transport = FakeJSONRPCTransport()
        let client = makeClient(
            transport: transport,
            scheduler: ControlledTimeoutScheduler()
        )
        let startTask = makeTrackedTask {
            try await client.start()
        }
        let initialize = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let responseID = try XCTUnwrap(initialize.id)
        if let result {
            await transport.emit(
                try successResponse(id: responseID, result: result)
            )
        } else {
            await transport.emit(
                try responseWithoutResult(id: responseID)
            )
        }

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected invalid initialize response")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .invalidInitializeResponse
            )
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("codexHome"))
            XCTAssertFalse(description.contains("/synthetic/redacted"))
            XCTAssertFalse(description.contains("usage-island-test"))
        }
        let sentCount = await transport.sentMessageCount()
        let shutdownCount = await transport.shutdownCallCount()
        let sendsInFlight = await transport.sendsCurrentlyInFlight()
        XCTAssertEqual(sentCount, 1)
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(sendsInFlight, 0)
        do {
            _ = try await client.request(method: "must/not-be-ready")
            XCTFail("Invalid initialize response must never publish ready")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }

        try await client.shutdown()
        try await client.shutdown()
        let finalShutdownCount = await transport.shutdownCallCount()
        XCTAssertEqual(finalShutdownCount, 1)
    }

    private func validInitializeResult() -> JSONValue {
        .object(validInitializeObject())
    }

    private func validInitializeObject() -> [String: JSONValue] {
        [
            "codexHome": .string("/synthetic/redacted"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
            "userAgent": .string("usage-island-test")
        ]
    }

    private func responseWithoutResult(
        id: JSONRPCRequestID
    ) throws -> Data {
        var data = try JSONEncoder().encode(
            MissingResultResponse(id: id)
        )
        data.append(0x0A)
        return data
    }

    private func waitUntilStopped(
        _ client: CodexAppServerClient,
        maximumYields: Int = 10_000
    ) async throws {
        for _ in 0..<maximumYields {
            do {
                _ = try await client.request(method: "test/probe")
            } catch {
                if error as? JSONRPCError == .transportClosed {
                    return
                }
            }
            await Task.yield()
        }
        throw TransportTestProbeError.conditionNotReached(
            "Codex client did not enter stopped state"
        )
    }
}

private enum CodexInitializeField: String, CaseIterable {
    case codexHome
    case platformFamily
    case platformOs
    case userAgent
}

private struct MissingResultResponse: Encodable {
    let id: JSONRPCRequestID
}
