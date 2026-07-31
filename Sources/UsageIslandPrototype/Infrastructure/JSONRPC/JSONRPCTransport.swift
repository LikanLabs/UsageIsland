import Foundation

public protocol JSONRPCTransport: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    func incomingBytes() async -> AsyncThrowingStream<Data, Error>
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
