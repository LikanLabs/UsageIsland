import Foundation
import XCTest

@testable import UsageIslandPrototype

final class JSONRPCClientTests: XCTestCase {
    func testAlreadyCancelledCallerDoesNotRegisterOrSendRequest() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()

        let requestTask = makeTrackedTask {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await client.request(method: "must/not/send")
        }

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected cancellation")
        } catch {
            guard case .requestCancelled = error as? JSONRPCError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let sentMessageCount = await transport.sentMessageCount()
        XCTAssertEqual(sentMessageCount, 0)
        try await client.shutdown()
    }

    func testShutdownDuringSuspendedStartWinsLifecycleRace() async throws {
        let transport = FakeJSONRPCTransport(suspendsStart: true)
        let client = JSONRPCClient(transport: transport)
        let startTask = makeTrackedTask {
            try await client.start()
        }
        try await transport.waitUntilStartCalled()

        try await client.shutdown()

        do {
            try await boundedValue(of: startTask)
            XCTFail("Expected startup cancellation")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let shutdownCallCount = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCallCount, 1)
        do {
            _ = try await client.request(method: "after/shutdown")
            XCTFail("Expected closed transport")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
    }

    func testResponsesAreCorrelatedByIDAcrossConcurrentRequests() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()

        let firstTask = makeTrackedTask {
            try await client.request(method: "first")
        }
        let first = try decodeOutbound(try await transport.dataSent(at: 0))
        let secondTask = makeTrackedTask {
            try await client.request(method: "second")
        }
        let second = try decodeOutbound(try await transport.dataSent(at: 1))
        let firstID = try XCTUnwrap(first.id)
        let secondID = try XCTUnwrap(second.id)

        await transport.emit(try successResponse(id: secondID, result: .string("second")))
        await transport.emit(try successResponse(id: firstID, result: .string("first")))

        let firstResult = try await boundedValue(of: firstTask)
        let secondResult = try await boundedValue(of: secondTask)
        XCTAssertEqual(firstResult, .string("first"))
        XCTAssertEqual(secondResult, .string("second"))
        XCTAssertNotEqual(firstID, secondID)
        try await client.shutdown()
    }

    func testUnknownFutureNotificationIsPublishedWithoutClosingTransport() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let notifications = await client.notifications()
        let notificationTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }

        await transport.emitLine(
            #"{"method":"future/event","params":{"state":"new"}}"#
        )

        let notification = try await boundedValue(of: notificationTask)
        XCTAssertEqual(
            notification,
            JSONRPCNotification(
                method: "future/event",
                params: .object(["state": .string("new")])
            )
        )

        let requestTask = makeTrackedTask {
            try await client.request(method: "still/alive")
        }
        let outbound = try decodeOutbound(try await transport.dataSent(at: 0))
        await transport.emit(
            try successResponse(id: XCTUnwrap(outbound.id), result: .bool(true))
        )
        let result = try await boundedValue(of: requestTask)
        XCTAssertEqual(result, .bool(true))
        try await client.shutdown()
    }

    func testRemoteErrorDiscardsSensitiveMessage() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "failure")
        }
        let outbound = try decodeOutbound(try await transport.dataSent(at: 0))

        await transport.emit(
            try errorResponse(
                id: XCTUnwrap(outbound.id),
                code: -32_001,
                message: "token=secret-personal-value"
            )
        )

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected remote error")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .remoteError(code: -32_001))
            XCTAssertFalse(error.localizedDescription.contains("secret-personal-value"))
        }
        try await client.shutdown()
    }

    func testMalformedJSONFailsEveryPendingRequestWithTypedError() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "pending")
        }
        _ = try await transport.dataSent(at: 0)

        await transport.emitLine(#"{"id":1,"result":"#)

        await assertTask(requestTask, throws: .malformedJSON)
    }

    func testOversizedLineFailsEveryPendingRequestWithTypedError() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport, maximumLineSize: 16)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "pending")
        }
        _ = try await transport.dataSent(at: 0)

        await transport.emit(Data(repeating: 0x61, count: 17))

        await assertTask(requestTask, throws: .responseTooLarge(limit: 16))
    }

    func testFragmentedJSONLineIsReassembledBeforeDecoding() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "fragmented")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let response = try successResponse(
            id: XCTUnwrap(outbound.id),
            result: .string("complete")
        )
        let splitIndex = response.index(response.startIndex, offsetBy: response.count / 2)

        await transport.emit(Data(response[..<splitIndex]))
        await transport.emit(Data(response[splitIndex...]))

        let result = try await boundedValue(of: requestTask)
        XCTAssertEqual(result, .string("complete"))
        try await client.shutdown()
    }

    func testMultipleJSONLinesInOneChunkDeliverEachNotification() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let notifications = await client.notifications()
        let notificationTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return (
                try await iterator.next(),
                try await iterator.next()
            )
        }

        await transport.emit(
            Data(
                """
                {"method":"first/event"}
                {"method":"second/event"}

                """.utf8
            )
        )

        let received = try await boundedValue(of: notificationTask)
        XCTAssertEqual(received.0?.method, "first/event")
        XCTAssertEqual(received.1?.method, "second/event")
        try await client.shutdown()
    }

    func testNotificationBufferOverflowFailsTransportExplicitly() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumBufferedNotifications: 1
        )
        try await client.start()
        let notifications = await client.notifications()

        await transport.emit(
            Data(
                """
                {"method":"first/event"}
                {"method":"overflow/event"}

                """.utf8
            )
        )
        try await transport.waitUntilShutdownCalled()

        var iterator = notifications.makeAsyncIterator()
        let firstNotification = try await iterator.next()
        XCTAssertEqual(firstNotification?.method, "first/event")
        do {
            _ = try await iterator.next()
            XCTFail("Expected notification overflow")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .notificationBufferOverflow(limit: 1)
            )
        }
        let shutdownCallCount = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCallCount, 1)
    }

    func testRequestTimeoutUsesInjectedSchedulerWithoutSleeping() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: ImmediateTimeoutScheduler()
        )
        try await client.start()

        let requestTask = makeTrackedTask {
            try await client.request(method: "slow", timeout: .seconds(30))
        }

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected timeout")
        } catch {
            guard case .requestTimedOut = error as? JSONRPCError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        try await client.shutdown()
    }

    func testCallerCancellationRemovesPendingRequest() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "cancel")
        }
        _ = try await transport.dataSent(at: 0)

        requestTask.task.cancel()

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected cancellation")
        } catch {
            guard case .requestCancelled = error as? JSONRPCError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        try await client.shutdown()
    }

    func testUnknownResponseIDFailsPendingRequests() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "pending")
        }
        _ = try await transport.dataSent(at: 0)

        await transport.emit(
            try successResponse(id: .integer(999), result: .null)
        )

        await assertTask(
            requestTask,
            throws: .unknownResponseID(.integer(999))
        )
    }

    func testUnexpectedExitResolvesEveryPendingRequest() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let first = makeTrackedTask {
            try await client.request(method: "first")
        }
        let second = makeTrackedTask {
            try await client.request(method: "second")
        }
        _ = try await transport.dataSent(at: 0)
        _ = try await transport.dataSent(at: 1)

        await transport.finish(throwing: JSONRPCError.processExited(status: 9))

        await assertTask(first, throws: .processExited(status: 9))
        await assertTask(second, throws: .processExited(status: 9))
    }

    func testShutdownIsCleanAndIdempotent() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()

        try await client.shutdown()
        try await client.shutdown()

        let shutdownCallCount = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCallCount, 1)
        do {
            _ = try await client.request(method: "after/shutdown")
            XCTFail("Expected closed transport")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
    }

    func testStandardErrorIsNeverParsedAsProtocolData() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "pending")
        }
        let outbound = try decodeOutbound(try await transport.dataSent(at: 0))

        await transport.emitStandardError(Data(#"{"id":1,"result":"wrong"}"#.utf8))
        await transport.emit(
            try successResponse(id: XCTUnwrap(outbound.id), result: .string("stdout"))
        )

        let result = try await boundedValue(of: requestTask)
        let standardErrorChunkCount = await transport.standardErrorChunkCount()
        XCTAssertEqual(result, .string("stdout"))
        XCTAssertEqual(standardErrorChunkCount, 1)
        try await client.shutdown()
    }

    func testCancellationAfterSendClosesTransportAndIgnoresLateResponse() async throws {
        let transport = FakeJSONRPCTransport(suspendsShutdown: true)
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "cancelled")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let requestID = try XCTUnwrap(outbound.id)

        requestTask.task.cancel()
        try await transport.waitUntilShutdownCalled()
        await transport.emit(
            try successResponse(id: requestID, result: .string("late"))
        )

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected cancellation")
        } catch {
            guard case .requestCancelled = error as? JSONRPCError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        do {
            _ = try await client.request(method: "must/not/reuse")
            XCTFail("Expected closed transport")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        await transport.releaseShutdown()
        try await client.shutdown()
    }

    func testPreCancelledStartupReturnsTypedErrorWithoutStartingTransport() async {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
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
        let startCalls = await transport.startCallCount()
        XCTAssertEqual(startCalls, 0)
    }

    func testCancellationDuringTransportStartReturnsTypedError() async throws {
        let transport = FakeJSONRPCTransport(suspendsStart: true)
        let client = JSONRPCClient(transport: transport)
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

    func testTimeoutClosesTransportAndBoundsSuspendedSend() async throws {
        let transport = FakeJSONRPCTransport(suspendsSend: true)
        let scheduler = ManualTimeoutScheduler()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: scheduler
        )
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(
                method: "blocked/send",
                timeout: .seconds(30)
            )
        }
        try await transport.waitUntilSendCalled()
        try await scheduler.waitUntilScheduled()

        await scheduler.fire()

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected timeout")
        } catch {
            guard case .requestTimedOut = error as? JSONRPCError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
        try await client.shutdown()
    }

    func testUncertainSendFailureClosesTransportAndIgnoresLateResponse() async throws {
        let transport = FakeJSONRPCTransport(
            sendError: .transportClosed,
            suspendsShutdown: true
        )
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "uncertain/send")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected send failure")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(outbound.id),
                result: .string("late")
            )
        )
        do {
            _ = try await client.request(method: "after/failure")
            XCTFail("Expected closed transport")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        await transport.releaseShutdown()
        try await client.shutdown()
    }

    func testUnknownStringResponseIDIsRedactedBeforeStorage() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "pending")
        }
        _ = try await transport.dataSent(at: 0)

        await transport.emit(
            try successResponse(
                id: .string("secret-response-identifier"),
                result: .null
            )
        )

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected unknown response ID")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .unknownResponseID(.string("<redacted>"))
            )
            XCTAssertFalse(
                error.localizedDescription.contains(
                    "secret-response-identifier"
                )
            )
        }
    }

    func testConcurrentShutdownCallsAwaitSameBarrier() async throws {
        let transport = FakeJSONRPCTransport(suspendsShutdown: true)
        let client = JSONRPCClient(transport: transport)
        try await client.start()
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

    func testCallerCancellationBoundsSuspendedSendAndLeavesNoSendTask() async throws {
        let transport = FakeJSONRPCTransport(suspendsSend: true)
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "cancel/suspended-send")
        }
        _ = try await transport.dataSent(at: 0)

        requestTask.task.cancel()

        let result = try await boundedResult(of: requestTask)
        switch result {
        case .success:
            XCTFail("Expected typed cancellation")
        case .failure(let error):
            guard case .requestCancelled = error as? JSONRPCError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let inFlight = await transport.sendsCurrentlyInFlight()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(inFlight, 0)
        XCTAssertEqual(shutdownCalls, 1)
        try await client.shutdown()
    }

    func testCancellationWhileIncomingBytesIsSuspendedNeverRunsClient() async throws {
        let transport = FakeJSONRPCTransport(suspendsIncomingBytes: true)
        let client = JSONRPCClient(transport: transport)
        let startTask = makeTrackedTask {
            try await client.start()
        }
        try await transport.waitUntilIncomingBytesCalled()

        startTask.task.cancel()

        let result = try await boundedResult(of: startTask)
        switch result {
        case .success:
            XCTFail("Expected startup cancellation")
        case .failure(let error):
            XCTAssertEqual(error as? JSONRPCError, .startupCancelled)
        }
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
        do {
            _ = try await client.request(method: "must/not/run")
            XCTFail("Cancelled startup must not publish running")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
    }

    func testOversizedRequestIsRejectedBeforeTransportSend() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumRequestSize: 64
        )
        try await client.start()

        do {
            _ = try await client.request(
                method: "oversized",
                params: .string(String(repeating: "x", count: 128))
            )
            XCTFail("Expected request size rejection")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .requestTooLarge(limit: 64))
        }
        let sent = await transport.sentMessageCount()
        XCTAssertEqual(sent, 0)
        try await client.shutdown()
    }

    private func assertTask(
        _ task: (
            task: Task<JSONValue, Error>,
            state: TrackedTaskState
        ),
        throws expectedError: JSONRPCError
    ) async {
        do {
            _ = try await boundedValue(of: task)
            XCTFail("Expected \(expectedError)")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, expectedError)
        }
    }
}
