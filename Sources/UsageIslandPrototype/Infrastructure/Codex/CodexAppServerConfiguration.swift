import Foundation

public struct CodexAppServerConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let clientVersion: String
    public let requestTimeout: Duration
    public let maximumLineSize: Int
    public let maximumBufferedNotifications: Int

    public init(
        executableURL: URL,
        clientVersion: String = "1.0",
        requestTimeout: Duration = .seconds(15),
        maximumLineSize: Int = 1_048_576,
        maximumBufferedNotifications: Int = 100
    ) {
        self.executableURL = executableURL
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout
        self.maximumLineSize = max(1, maximumLineSize)
        self.maximumBufferedNotifications = max(1, maximumBufferedNotifications)
    }
}

public protocol CodexProcessTransportFactory: Sendable {
    func makeTransport(
        configuration: ManagedProcessConfiguration
    ) async throws -> any JSONRPCTransport
}

public struct ManagedCodexProcessTransportFactory: CodexProcessTransportFactory {
    public init() {}

    public func makeTransport(
        configuration: ManagedProcessConfiguration
    ) async throws -> any JSONRPCTransport {
        ManagedProcess(configuration: configuration)
    }
}
