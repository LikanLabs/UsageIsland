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
        let transport = FakeJSONRPCTransport(suspendsSend: true)
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "cancelled")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let requestID = try XCTUnwrap(outbound.id)

        await transport.releaseSend()
        await client.waitForActiveSendQuiescence()
        requestTask.task.cancel()

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected cancellation")
        } catch {
            guard case .requestCancelled = error as? JSONRPCError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        await transport.emit(
            try successResponse(id: requestID, result: .string("late"))
        )

        try await transport.waitUntilShutdownCalled()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
        do {
            _ = try await client.request(method: "after/cancellation")
            XCTFail("Expected fail-closed client")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let sentCount = await transport.sentMessageCount()
        XCTAssertEqual(sentCount, 1)
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

    func testCancellationOfNonCooperativeSendFailsClosedWithoutReusingCapacity() async throws {
        let transport = NonCooperativeSendJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumPendingRequests: 1
        )
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "cancel/non-cooperative-send")
        }
        _ = try await transport.dataSent(at: 0)

        requestTask.task.cancel()
        try await transport.waitUntilShutdownCalled()

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
        do {
            _ = try await client.request(method: "must/not/reuse/slot")
            XCTFail("Expected fail-closed client")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let sentCount = await transport.sentMessageCount()
        XCTAssertEqual(sentCount, 1)
        try await client.shutdown()
    }

    func testCancelledNonCooperativeNotificationSendFailsClosed() async throws {
        let transport = NonCooperativeSendJSONRPCTransport(
            returnsNormallyAfterShutdown: true
        )
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler()
        )
        try await client.start()
        let notificationTask = makeTrackedTask {
            try await client.sendNotification(
                method: "cancel/non-cooperative-notification"
            )
        }
        _ = try await transport.dataSent(at: 0)

        notificationTask.task.cancel()
        try await transport.waitUntilShutdownCalled()

        do {
            try await boundedValue(of: notificationTask)
            XCTFail("Expected fail-closed notification cancellation")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let inFlight = await transport.sendsCurrentlyInFlight()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(inFlight, 0)
        XCTAssertEqual(shutdownCalls, 1)
        do {
            _ = try await client.request(method: "after/notification-cancel")
            XCTFail("Expected closed client")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        try await client.shutdown()
    }

    func testShutdownWaitsForRequestAndNotificationSendsToUnwind() async throws {
        let transport = NonCooperativeSendJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let notifications = await client.notifications()
        let responseBarrierTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        let requestTask = makeTrackedTask {
            try await client.request(method: "shutdown/request")
        }
        let requestOutbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        var responseAndBarrier = try successResponse(
            id: XCTUnwrap(requestOutbound.id),
            result: .string("resolved-before-shutdown")
        )
        responseAndBarrier.append(
            Data(#"{"method":"shutdown/response-handled"}"#.utf8)
        )
        responseAndBarrier.append(0x0A)
        await transport.emit(responseAndBarrier)
        let responseBarrier = try await boundedValue(of: responseBarrierTask)
        XCTAssertEqual(
            responseBarrier?.method,
            "shutdown/response-handled"
        )
        let notificationTask = makeTrackedTask {
            try await client.sendNotification(method: "shutdown/notification")
        }
        _ = try await transport.dataSent(at: 1)
        let shutdownTask = makeTrackedTask {
            try await client.shutdown()
        }

        try await boundedValue(of: shutdownTask)

        let requestResult = try await boundedResult(of: requestTask)
        let notificationResult = try await boundedResult(of: notificationTask)
        let sendsInFlight = await transport.sendsCurrentlyInFlight()
        XCTAssertEqual(sendsInFlight, 0)
        switch requestResult {
        case .success:
            XCTFail("Shutdown must beat a buffered response")
        case .failure(let error):
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        switch notificationResult {
        case .success:
            XCTFail("Expected notification send failure")
        case .failure(let error):
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
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

    func testRemoteErrorAllowsExtraFieldsWithoutRetainingPayload() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "failure/with/extras")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        await transport.emit(
            try arbitraryErrorResponse(
                id: XCTUnwrap(outbound.id),
                payload: .object([
                    "code": .integer(-32_123),
                    "message": .string("private-payload-marker"),
                    "data": .object(["future": .bool(true)]),
                    "extension": .string("ignored")
                ])
            )
        )

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected remote error")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .remoteError(code: -32_123)
            )
            XCTAssertFalse(
                error.localizedDescription.contains("private-payload-marker")
            )
        }
        try await client.shutdown()
    }

    func testResponseRejectsResultAndErrorTogetherBeforeErrorDecoding() async throws {
        let errorPayloads: [JSONValue] = [
            .object([
                "code": .integer(-32_000),
                "message": .string("secret-valid-error")
            ]),
            .string("secret-malformed-error")
        ]

        for payload in errorPayloads {
            try await assertAmbiguousResponseIsMalformed(error: payload)
        }
    }

    func testRemoteErrorRequiresStringMessage() async throws {
        let invalidPayloads: [JSONValue] = [
            .object(["code": .integer(-1)]),
            .object(["code": .integer(-1), "message": .null]),
            .object(["code": .integer(-1), "message": .integer(7)])
        ]

        for payload in invalidPayloads {
            try await assertMalformedRemoteError(payload)
        }
    }

    func testRemoteErrorRequiresIntegerCode() async throws {
        let invalidPayloads: [JSONValue] = [
            .object(["message": .string("missing")]),
            .object([
                "code": .string("-32000"),
                "message": .string("wrong type")
            ])
        ]

        for payload in invalidPayloads {
            try await assertMalformedRemoteError(payload)
        }
    }

    func testInvalidPendingLimitFailsBeforeStartingTransport() async {
        for limit in [0, -1] {
            let transport = FakeJSONRPCTransport()
            let client = JSONRPCClient(
                transport: transport,
                maximumPendingRequests: limit
            )
            let notifications = await client.notifications()

            do {
                try await client.start()
                XCTFail("Expected invalid configuration")
            } catch {
                XCTAssertEqual(
                    error as? JSONRPCError,
                    .invalidPendingRequestLimit
                )
            }
            var iterator = notifications.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                XCTFail("Expected notification channel termination")
            } catch {
                XCTAssertEqual(
                    error as? JSONRPCError,
                    .invalidPendingRequestLimit
                )
            }
            let startCalls = await transport.startCallCount()
            XCTAssertEqual(startCalls, 0)
        }
    }

    func testInvalidDefaultTimeoutFailsBeforeStartingTransport() async {
        for timeout: Duration in [.zero, .seconds(-1)] {
            let transport = FakeJSONRPCTransport()
            let client = JSONRPCClient(
                transport: transport,
                defaultRequestTimeout: timeout
            )
            let notifications = await client.notifications()

            do {
                try await client.start()
                XCTFail("Expected invalid configuration")
            } catch {
                XCTAssertEqual(
                    error as? JSONRPCError,
                    .invalidRequestTimeout
                )
            }
            var iterator = notifications.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                XCTFail("Expected notification channel termination")
            } catch {
                XCTAssertEqual(
                    error as? JSONRPCError,
                    .invalidRequestTimeout
                )
            }
            let startCalls = await transport.startCallCount()
            XCTAssertEqual(startCalls, 0)
        }
    }

    func testInvalidRequestTimeoutOverrideIsRejectedBeforeSend() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()

        for timeout: Duration in [.zero, .seconds(-1)] {
            do {
                _ = try await client.request(
                    method: "invalid/timeout",
                    timeout: timeout
                )
                XCTFail("Expected invalid timeout")
            } catch {
                XCTAssertEqual(
                    error as? JSONRPCError,
                    .invalidRequestTimeout
                )
            }
        }
        let sent = await transport.sentMessageCount()
        XCTAssertEqual(sent, 0)
        try await client.shutdown()
    }

    func testDefaultPendingRequestLimitIs64AndRejectsBeforeSend() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        var requests: [(
            task: Task<JSONValue, Error>,
            state: TrackedTaskState
        )] = []

        for index in 0..<64 {
            let request = makeTrackedTask {
                try await client.request(method: "pending/\(index)")
            }
            requests.append(request)
            _ = try await transport.dataSent(at: index)
        }

        do {
            _ = try await client.request(method: "over/capacity")
            XCTFail("Expected pending request limit")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .pendingRequestLimitExceeded(limit: 64)
            )
        }
        let sent = await transport.sentMessageCount()
        XCTAssertEqual(sent, 64)

        try await client.shutdown()
        for request in requests {
            await assertTask(request, throws: .transportClosed)
        }
    }

    func testResponseAndRemoteErrorEachReleasePendingSlot() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumPendingRequests: 1
        )
        try await client.start()

        let successTask = makeTrackedTask {
            try await client.request(method: "slot/success")
        }
        let successOutbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        do {
            _ = try await client.request(method: "slot/rejected")
            XCTFail("Expected pending request limit")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .pendingRequestLimitExceeded(limit: 1)
            )
        }
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(successOutbound.id),
                result: .string("released")
            )
        )
        let successResult = try await boundedValue(of: successTask)
        XCTAssertEqual(successResult, .string("released"))

        let failureTask = makeTrackedTask {
            try await client.request(method: "slot/failure")
        }
        let failureOutbound = try decodeOutbound(
            try await transport.dataSent(at: 1)
        )
        await transport.emit(
            try errorResponse(
                id: XCTUnwrap(failureOutbound.id),
                code: -32_001,
                message: "discarded"
            )
        )
        await assertTask(
            failureTask,
            throws: .remoteError(code: -32_001)
        )

        let finalTask = makeTrackedTask {
            try await client.request(method: "slot/reused")
        }
        let finalOutbound = try decodeOutbound(
            try await transport.dataSent(at: 2)
        )
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(finalOutbound.id),
                result: .bool(true)
            )
        )
        let finalResult = try await boundedValue(of: finalTask)
        XCTAssertEqual(finalResult, .bool(true))
        try await client.shutdown()
    }

    func testResponseDoesNotReleaseCapacityUntilPhysicalSendUnwinds() async throws {
        let transport = NonCooperativeSendJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumPendingRequests: 1
        )
        try await client.start()
        let notifications = await client.notifications()
        let notificationTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        let firstTask = makeTrackedTask {
            try await client.request(method: "slot/blocked-send")
        }
        let firstOutbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        var responseAndBarrier = try successResponse(
            id: XCTUnwrap(firstOutbound.id),
            result: .string("first")
        )
        responseAndBarrier.append(
            Data(#"{"method":"response/handled"}"#.utf8)
        )
        responseAndBarrier.append(0x0A)

        await transport.emit(responseAndBarrier)
        let barrierNotification = try await boundedValue(
            of: notificationTask
        )
        XCTAssertEqual(barrierNotification?.method, "response/handled")
        do {
            _ = try await client.request(method: "must/not/overlap")
            XCTFail("Expected request slot to remain owned")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .pendingRequestLimitExceeded(limit: 1)
            )
        }
        let sentBeforeRelease = await transport.sentMessageCount()
        XCTAssertEqual(sentBeforeRelease, 1)

        await transport.releaseSends()
        let firstResult = try await boundedValue(of: firstTask)
        XCTAssertEqual(firstResult, .string("first"))

        let secondTask = makeTrackedTask {
            try await client.request(method: "slot/after-completion")
        }
        let secondOutbound = try decodeOutbound(
            try await transport.dataSent(at: 1)
        )
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(secondOutbound.id),
                result: .string("second")
            )
        )
        await transport.releaseSends()
        let secondResult = try await boundedValue(of: secondTask)
        XCTAssertEqual(secondResult, .string("second"))
        try await client.shutdown()
    }

    func testCancellationBeatsBufferedResponseWhileSendIsBlocked() async throws {
        let transport = NonCooperativeSendJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler(),
            maximumPendingRequests: 1
        )
        try await client.start()
        let notifications = await client.notifications()
        let responseBarrierTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        let requestTask = makeTrackedTask {
            try await client.request(method: "buffered/cancel")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let requestID = try XCTUnwrap(outbound.id)
        var responseAndBarrier = try successResponse(
            id: requestID,
            result: .string("must-not-win")
        )
        responseAndBarrier.append(
            Data(#"{"method":"buffered/cancel/received"}"#.utf8)
        )
        responseAndBarrier.append(0x0A)
        await transport.emit(responseAndBarrier)
        let barrier = try await boundedValue(of: responseBarrierTask)
        XCTAssertEqual(barrier?.method, "buffered/cancel/received")

        requestTask.task.cancel()
        try await transport.waitUntilShutdownCalled()

        let result = try await boundedResult(of: requestTask)
        switch result {
        case .success:
            XCTFail("Buffered success must not beat cancellation")
        case .failure(let error):
            XCTAssertEqual(
                error as? JSONRPCError,
                .requestCancelled(requestID)
            )
        }
        let sendsInFlight = await transport.sendsCurrentlyInFlight()
        XCTAssertEqual(sendsInFlight, 0)
        let shutdownTask = makeTrackedTask {
            try await client.shutdown()
        }
        try await boundedValue(of: shutdownTask)
    }

    func testTimeoutBeatsBufferedResponseWhileSendIsBlocked() async throws {
        let transport = NonCooperativeSendJSONRPCTransport()
        let scheduler = ManualTimeoutScheduler()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: scheduler,
            maximumPendingRequests: 1
        )
        try await client.start()
        let notifications = await client.notifications()
        let responseBarrierTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        let requestTask = makeTrackedTask {
            try await client.request(method: "buffered/timeout")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let requestID = try XCTUnwrap(outbound.id)
        try await scheduler.waitUntilScheduled()
        var responseAndBarrier = try successResponse(
            id: requestID,
            result: .string("must-not-win")
        )
        responseAndBarrier.append(
            Data(#"{"method":"buffered/timeout/received"}"#.utf8)
        )
        responseAndBarrier.append(0x0A)
        await transport.emit(responseAndBarrier)
        let barrier = try await boundedValue(of: responseBarrierTask)
        XCTAssertEqual(barrier?.method, "buffered/timeout/received")

        await scheduler.fire()
        try await transport.waitUntilShutdownCalled()

        await assertTask(
            requestTask,
            throws: .requestTimedOut(requestID)
        )
        let sendsInFlight = await transport.sendsCurrentlyInFlight()
        XCTAssertEqual(sendsInFlight, 0)
        let shutdownTask = makeTrackedTask {
            try await client.shutdown()
        }
        try await boundedValue(of: shutdownTask)
    }

    func testBufferedResponseCompletesWhenSendSettlesBeforeDeadline() async throws {
        let transport = NonCooperativeSendJSONRPCTransport()
        let scheduler = ManualTimeoutScheduler()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: scheduler
        )
        try await client.start()
        let notifications = await client.notifications()
        let responseBarrierTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        let requestTask = makeTrackedTask {
            try await client.request(method: "buffered/settled")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        try await scheduler.waitUntilScheduled()
        var responseAndBarrier = try successResponse(
            id: XCTUnwrap(outbound.id),
            result: .string("settled")
        )
        responseAndBarrier.append(
            Data(#"{"method":"buffered/settled/received"}"#.utf8)
        )
        responseAndBarrier.append(0x0A)
        await transport.emit(responseAndBarrier)
        let barrier = try await boundedValue(of: responseBarrierTask)
        XCTAssertEqual(barrier?.method, "buffered/settled/received")

        await transport.releaseSends()

        let result = try await boundedValue(of: requestTask)
        XCTAssertEqual(result, .string("settled"))
        try await scheduler.waitUntilWaitCompleted()
        await scheduler.fire()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 0)
        try await client.shutdown()
    }

    func testNotificationSendUsesDefaultTimeoutAndFailsClosed() async throws {
        let transport = NonCooperativeSendJSONRPCTransport()
        let scheduler = ManualTimeoutScheduler()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: scheduler,
            defaultRequestTimeout: .seconds(7)
        )
        try await client.start()
        let notificationTask = makeTrackedTask {
            try await client.sendNotification(method: "notification/timeout")
        }
        _ = try await transport.dataSent(at: 0)
        try await scheduler.waitUntilScheduled()
        let durations = await scheduler.scheduledDurations()
        XCTAssertEqual(durations, [.seconds(7)])

        await scheduler.fire()
        try await transport.waitUntilShutdownCalled()

        do {
            try await boundedValue(of: notificationTask)
            XCTFail("Expected notification timeout")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .notificationTimedOut)
        }
        let sendsInFlight = await transport.sendsCurrentlyInFlight()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(sendsInFlight, 0)
        XCTAssertEqual(shutdownCalls, 1)
        do {
            _ = try await client.request(method: "after/notification-timeout")
            XCTFail("Expected fail-closed client")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        try await client.shutdown()
    }

    func testNotificationSendLimitRejectsNPlusOneConcurrentCallerBeforeWrite() async throws {
        let limit = 3
        let transport = NonCooperativeSendJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler(),
            maximumPendingRequests: limit
        )
        try await client.start()
        var sends: [(
            task: Task<Void, Error>,
            state: TrackedTaskState
        )] = []

        for index in 0..<limit {
            let send = makeTrackedTask {
                try await client.sendNotification(
                    method: "notification/concurrent/\(index)"
                )
            }
            sends.append(send)
            _ = try await transport.dataSent(at: index)
        }

        do {
            try await client.sendNotification(
                method: "notification/concurrent/over-limit"
            )
            XCTFail("Expected notification send limit")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .notificationSendLimitExceeded(limit: limit)
            )
        }
        let sentBeforeRelease = await transport.sentMessageCount()
        XCTAssertEqual(sentBeforeRelease, limit)

        await transport.releaseSends()
        for send in sends {
            try await boundedValue(of: send)
        }
        let sendsInFlight = await transport.sendsCurrentlyInFlight()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(sendsInFlight, 0)
        XCTAssertEqual(shutdownCalls, 0)
        try await client.shutdown()
    }

    func testNotificationSendSlotIsReleasedAfterCompletion() async throws {
        let transport = NonCooperativeSendJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler(),
            maximumPendingRequests: 1
        )
        try await client.start()
        let first = makeTrackedTask {
            try await client.sendNotification(method: "notification/first")
        }
        _ = try await transport.dataSent(at: 0)

        await transport.releaseSends()
        try await boundedValue(of: first)

        let second = makeTrackedTask {
            try await client.sendNotification(method: "notification/second")
        }
        _ = try await transport.dataSent(at: 1)
        await transport.releaseSends()
        try await boundedValue(of: second)

        let sentCount = await transport.sentMessageCount()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(sentCount, 2)
        XCTAssertEqual(shutdownCalls, 0)
        try await client.shutdown()
    }

    func testRequestAndNotificationLimitsAreIndependent() async throws {
        let transport = NonCooperativeSendJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: ControlledTimeoutScheduler(),
            maximumPendingRequests: 1
        )
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "mixed/request")
        }
        let requestOutbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let notificationTask = makeTrackedTask {
            try await client.sendNotification(method: "mixed/notification")
        }
        _ = try await transport.dataSent(at: 1)

        do {
            _ = try await client.request(method: "mixed/request/over-limit")
            XCTFail("Expected independent request limit")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .pendingRequestLimitExceeded(limit: 1)
            )
        }
        do {
            try await client.sendNotification(
                method: "mixed/notification/over-limit"
            )
            XCTFail("Expected independent notification limit")
        } catch {
            XCTAssertEqual(
                error as? JSONRPCError,
                .notificationSendLimitExceeded(limit: 1)
            )
        }
        let sentAtCapacity = await transport.sentMessageCount()
        XCTAssertEqual(sentAtCapacity, 2)

        await transport.emit(
            try successResponse(
                id: XCTUnwrap(requestOutbound.id),
                result: .string("request-complete")
            )
        )
        await transport.releaseSends()

        let requestResult = try await boundedValue(of: requestTask)
        XCTAssertEqual(requestResult, .string("request-complete"))
        try await boundedValue(of: notificationTask)
        let sendsInFlight = await transport.sendsCurrentlyInFlight()
        XCTAssertEqual(sendsInFlight, 0)
        try await client.shutdown()
    }

    func testDefaultTimeoutIs30SecondsAndOverrideTakesPrecedence() async throws {
        let defaultTransport = FakeJSONRPCTransport()
        let defaultScheduler = ManualTimeoutScheduler()
        let defaultClient = JSONRPCClient(
            transport: defaultTransport,
            timeoutScheduler: defaultScheduler
        )
        try await defaultClient.start()
        let defaultTask = makeTrackedTask {
            try await defaultClient.request(method: "default/timeout")
        }
        let defaultOutbound = try decodeOutbound(
            try await defaultTransport.dataSent(at: 0)
        )
        try await defaultScheduler.waitUntilScheduled()
        let defaultDurations = await defaultScheduler.scheduledDurations()
        XCTAssertEqual(defaultDurations, [.seconds(30)])
        await defaultTransport.emit(
            try successResponse(
                id: XCTUnwrap(defaultOutbound.id),
                result: .null
            )
        )
        let defaultResult = try await boundedValue(of: defaultTask)
        XCTAssertEqual(defaultResult, .null)
        try await defaultScheduler.waitUntilWaitCompleted()
        await defaultScheduler.fire()
        let shutdownCallsAfterLateTimeout =
            await defaultTransport.shutdownCallCount()
        XCTAssertEqual(shutdownCallsAfterLateTimeout, 0)
        try await defaultClient.shutdown()

        let overrideTransport = FakeJSONRPCTransport()
        let overrideScheduler = ManualTimeoutScheduler()
        let overrideClient = JSONRPCClient(
            transport: overrideTransport,
            timeoutScheduler: overrideScheduler
        )
        try await overrideClient.start()
        let overrideTask = makeTrackedTask {
            try await overrideClient.request(
                method: "override/timeout",
                timeout: .seconds(3)
            )
        }
        let overrideOutbound = try decodeOutbound(
            try await overrideTransport.dataSent(at: 0)
        )
        try await overrideScheduler.waitUntilScheduled()
        let overrideDurations = await overrideScheduler.scheduledDurations()
        XCTAssertEqual(overrideDurations, [.seconds(3)])
        await overrideTransport.emit(
            try successResponse(
                id: XCTUnwrap(overrideOutbound.id),
                result: .null
            )
        )
        let overrideResult = try await boundedValue(of: overrideTask)
        XCTAssertEqual(overrideResult, .null)
        try await overrideClient.shutdown()
    }

    func testTimeoutReleasesSlotAndLateResponseIsIgnored() async throws {
        let transport = FakeJSONRPCTransport(suspendsSend: true)
        let scheduler = ManualTimeoutScheduler()
        let client = JSONRPCClient(
            transport: transport,
            timeoutScheduler: scheduler,
            maximumPendingRequests: 1
        )
        try await client.start()
        let timedOutTask = makeTrackedTask {
            try await client.request(method: "timeout/first")
        }
        let timedOutOutbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let timedOutID = try XCTUnwrap(timedOutOutbound.id)
        try await scheduler.waitUntilScheduled()
        await transport.releaseSend()
        await client.waitForActiveSendQuiescence()

        await scheduler.fire()
        await assertTask(
            timedOutTask,
            throws: .requestTimedOut(timedOutID)
        )
        await transport.emit(
            try successResponse(
                id: timedOutID,
                result: .string("late")
            )
        )

        let currentTask = makeTrackedTask {
            try await client.request(method: "timeout/current")
        }
        let currentOutbound = try decodeOutbound(
            try await transport.dataSent(at: 1)
        )
        await transport.emit(
            try successResponse(
                id: XCTUnwrap(currentOutbound.id),
                result: .string("current")
            )
        )
        let currentResult = try await boundedValue(of: currentTask)
        XCTAssertEqual(currentResult, .string("current"))
        let shutdownCallsBeforeExplicitShutdown =
            await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCallsBeforeExplicitShutdown, 0)
        try await client.shutdown()
    }

    func testMultibyteScalarCanBeSplitAcrossChunks() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "utf8/split")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let response = try successResponse(
            id: XCTUnwrap(outbound.id),
            result: .string("before🧪after")
        )
        let scalarRange = try XCTUnwrap(
            response.range(of: Data("🧪".utf8))
        )
        let split = response.index(after: scalarRange.lowerBound)

        await transport.emit(response[..<split])
        await transport.emit(response[split...])

        let result = try await boundedValue(of: requestTask)
        XCTAssertEqual(result, .string("before🧪after"))
        try await client.shutdown()
    }

    func testSeveralMultibyteScalarsSurviveEveryByteBoundary() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "utf8/all-boundaries")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        let response = try successResponse(
            id: XCTUnwrap(outbound.id),
            result: .string("é€🧪")
        )

        for byte in response {
            await transport.emit(Data([byte]))
        }

        let result = try await boundedValue(of: requestTask)
        XCTAssertEqual(result, .string("é€🧪"))
        try await client.shutdown()
    }

    func testValidFinalLineWithoutNewlineIsDecodedAtEndOfStream() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "final/no-newline")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        var response = try successResponse(
            id: XCTUnwrap(outbound.id),
            result: .string("complete")
        )
        response.removeLast()

        await transport.emit(response)
        await transport.finish(throwing: JSONRPCError.transportClosed)

        let result = try await boundedValue(of: requestTask)
        XCTAssertEqual(result, .string("complete"))
    }

    func testMultipleLinesInOneChunkDecodeFinalLineWithoutNewline() async throws {
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
                {"method":"first/final"}
                {"method":"second/final"}
                """.utf8
            )
        )
        await transport.finish(throwing: JSONRPCError.transportClosed)

        let received = try await boundedValue(of: notificationTask)
        XCTAssertEqual(received.0?.method, "first/final")
        XCTAssertEqual(received.1?.method, "second/final")
    }

    func testInvalidUTF8FailsWithMalformedJSON() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "invalid/utf8")
        }
        _ = try await transport.dataSent(at: 0)

        await transport.emit(Data([0x7B, 0xFF, 0x7D, 0x0A]))

        await assertTask(requestTask, throws: .malformedJSON)
    }

    func testEmptyChunksDoNotProduceMessages() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let notifications = await client.notifications()
        let notificationTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }

        await transport.emit(Data())
        await transport.emit(Data())
        await transport.emitLine(#"{"method":"only/message"}"#)

        let received = try await boundedValue(of: notificationTask)
        XCTAssertEqual(received?.method, "only/message")
        try await client.shutdown()
    }

    func testLineAtExactByteLimitIsAccepted() async throws {
        let line = Data(#"{"method":"exact/limit"}"#.utf8)
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumLineSize: line.count
        )
        try await client.start()
        let notifications = await client.notifications()
        let notificationTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        var framedLine = line
        framedLine.append(0x0A)

        await transport.emit(framedLine)

        let received = try await boundedValue(of: notificationTask)
        XCTAssertEqual(received?.method, "exact/limit")
        try await client.shutdown()
    }

    func testLineOneByteOverLimitFailsWithTypedError() async throws {
        let line = Data(#"{"method":"over/limit"}"#.utf8)
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumLineSize: line.count - 1
        )
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "pending/over-limit")
        }
        _ = try await transport.dataSent(at: 0)
        var framedLine = line
        framedLine.append(0x0A)

        await transport.emit(framedLine)

        await assertTask(
            requestTask,
            throws: .responseTooLarge(limit: line.count - 1)
        )
    }

    func testCRLFLineAtExactByteLimitExcludesCarriageReturn() async throws {
        let line = Data(#"{"method":"crlf/exact"}"#.utf8)
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumLineSize: line.count
        )
        try await client.start()
        let notifications = await client.notifications()
        let notificationTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        var framedLine = line
        framedLine.append(contentsOf: [0x0D, 0x0A])

        await transport.emit(framedLine)

        let received = try await boundedValue(of: notificationTask)
        XCTAssertEqual(received?.method, "crlf/exact")
        try await client.shutdown()
    }

    func testCRLFLineOneContentByteOverLimitFails() async throws {
        let line = Data(#"{"method":"crlf/over"}"#.utf8)
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumLineSize: line.count - 1
        )
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "pending/crlf-over")
        }
        _ = try await transport.dataSent(at: 0)
        var framedLine = line
        framedLine.append(contentsOf: [0x0D, 0x0A])

        await transport.emit(framedLine)

        await assertTask(
            requestTask,
            throws: .responseTooLarge(limit: line.count - 1)
        )
    }

    func testEOFFinalCarriageReturnAtExactByteLimitIsExcluded() async throws {
        let line = Data(#"{"method":"eof-cr/exact"}"#.utf8)
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumLineSize: line.count
        )
        try await client.start()
        let notifications = await client.notifications()
        let notificationTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        var finalLine = line
        finalLine.append(0x0D)

        await transport.emit(finalLine)
        await transport.finish(throwing: JSONRPCError.transportClosed)

        let received = try await boundedValue(of: notificationTask)
        XCTAssertEqual(received?.method, "eof-cr/exact")
    }

    func testEOFFinalCarriageReturnOneContentByteOverLimitFails() async throws {
        let line = Data(#"{"method":"eof-cr/over"}"#.utf8)
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(
            transport: transport,
            maximumLineSize: line.count - 1
        )
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "pending/eof-cr-over")
        }
        _ = try await transport.dataSent(at: 0)
        var finalLine = line
        finalLine.append(0x0D)

        await transport.emit(finalLine)
        await transport.finish(throwing: JSONRPCError.transportClosed)

        await assertTask(
            requestTask,
            throws: .responseTooLarge(limit: line.count - 1)
        )
    }

    func testNotificationStreamIsSharedSingleConsumerNotBroadcast() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let firstNotificationsCall = await client.notifications()
        let secondNotificationsCall = await client.notifications()
        var firstIterator = firstNotificationsCall.makeAsyncIterator()
        var secondIterator = secondNotificationsCall.makeAsyncIterator()

        await transport.emitLine(#"{"method":"first/consumer"}"#)
        let first = try await firstIterator.next()
        await transport.emitLine(#"{"method":"second/consumer"}"#)
        let second = try await secondIterator.next()

        XCTAssertEqual(first?.method, "first/consumer")
        XCTAssertEqual(second?.method, "second/consumer")
        try await client.shutdown()
    }

    func testCancelledNotificationWaiterFailsClientClosed() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let notifications = await client.notifications()
        let notificationTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        try await notificationTask.state.waitUntilBegan()

        notificationTask.task.cancel()
        let notificationResult = try await boundedResult(of: notificationTask)
        switch notificationResult {
        case .success(let notification):
            XCTAssertNil(notification)
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }

        try await transport.waitUntilShutdownCalled()
        await transport.emitLine(#"{"method":"after/cancellation"}"#)
        let notificationsAfterCancellation = await client.notifications()
        let postCancellationTask = makeTrackedTask {
            var iterator = notificationsAfterCancellation.makeAsyncIterator()
            return try await iterator.next()
        }
        let postCancellationValue = try await boundedValue(
            of: postCancellationTask
        )
        XCTAssertNil(postCancellationValue)
        do {
            _ = try await client.request(method: "must/not/blackhole")
            XCTFail("Expected fail-closed client")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let sentCount = await transport.sentMessageCount()
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(sentCount, 0)
        XCTAssertEqual(shutdownCalls, 1)
        try await client.shutdown()
    }

    func testShutdownFinishesSharedStreamsWithoutRegisteredWaiters() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let firstNotificationsCall = await client.notifications()
        let secondNotificationsCall = await client.notifications()

        try await client.shutdown()

        var firstIterator = firstNotificationsCall.makeAsyncIterator()
        var secondIterator = secondNotificationsCall.makeAsyncIterator()
        do {
            _ = try await firstIterator.next()
            XCTFail("Expected first stream termination")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
        let secondTerminalValue = try await secondIterator.next()
        XCTAssertNil(secondTerminalValue)
        let shutdownCalls = await transport.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
    }

    func testShutdownFinishesNotificationStreamAndRejectsPostShutdownDelivery() async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let notifications = await client.notifications()
        let notificationTask = makeTrackedTask {
            var iterator = notifications.makeAsyncIterator()
            return try await iterator.next()
        }
        try await notificationTask.state.waitUntilBegan()

        try await client.shutdown()
        await transport.emitLine(#"{"method":"after/shutdown"}"#)

        do {
            _ = try await boundedValue(of: notificationTask)
            XCTFail("Expected stream termination")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .transportClosed)
        }
    }

    private func assertMalformedRemoteError(
        _ payload: JSONValue
    ) async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "malformed/remote-error")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        await transport.emit(
            try arbitraryErrorResponse(
                id: XCTUnwrap(outbound.id),
                payload: payload
            )
        )

        await assertTask(requestTask, throws: .malformedJSON)
    }

    private func assertAmbiguousResponseIsMalformed(
        error errorPayload: JSONValue
    ) async throws {
        let transport = FakeJSONRPCTransport()
        let client = JSONRPCClient(transport: transport)
        try await client.start()
        let requestTask = makeTrackedTask {
            try await client.request(method: "ambiguous/response")
        }
        let outbound = try decodeOutbound(
            try await transport.dataSent(at: 0)
        )
        await transport.emit(
            try ambiguousResponse(
                id: XCTUnwrap(outbound.id),
                result: .string("secret-result"),
                error: errorPayload
            )
        )

        do {
            _ = try await boundedValue(of: requestTask)
            XCTFail("Expected ambiguous response rejection")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .malformedJSON)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
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

private struct ArbitraryErrorResponse: Encodable {
    let id: JSONRPCRequestID
    let error: JSONValue
}

private struct AmbiguousResponse: Encodable {
    let id: JSONRPCRequestID
    let result: JSONValue
    let error: JSONValue
}

private func arbitraryErrorResponse(
    id: JSONRPCRequestID,
    payload: JSONValue
) throws -> Data {
    var data = try JSONEncoder().encode(
        ArbitraryErrorResponse(id: id, error: payload)
    )
    data.append(0x0A)
    return data
}

private func ambiguousResponse(
    id: JSONRPCRequestID,
    result: JSONValue,
    error: JSONValue
) throws -> Data {
    var data = try JSONEncoder().encode(
        AmbiguousResponse(id: id, result: result, error: error)
    )
    data.append(0x0A)
    return data
}
