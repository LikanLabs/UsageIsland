import Foundation

public protocol JSONRPCTransport: Sendable {
    func start() async throws

    /// Sends one complete framed message. Implementations are not required to
    /// complete solely because the calling task is cancelled; `shutdown()` is
    /// the mandatory escape hatch for an in-flight send.
    func send(_ data: Data) async throws

    func incomingBytes() async -> AsyncThrowingStream<Data, Error>

    /// Closes the transport and, before returning or throwing, must unblock
    /// every in-flight `send(_:)` call. Repeated calls must be safe.
    func shutdown() async throws
}

public protocol JSONRPCTimeoutScheduler: Sendable {
    func wait(for duration: Duration) async throws
}

public struct ContinuousJSONRPCTimeoutScheduler: JSONRPCTimeoutScheduler {
    private let clock = ContinuousClock()

    public init() {}

    public func wait(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
