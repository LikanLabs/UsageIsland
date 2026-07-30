import Foundation

public protocol UsageClock: Sendable {
    func now() -> Date
}

public struct SystemUsageClock: UsageClock {
    public init() {}

    public func now() -> Date {
        .now
    }
}
