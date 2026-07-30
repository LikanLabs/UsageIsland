import Foundation

public enum AgentStatus: String, Sendable {
    case running
    case waitingForApproval
    case waitingForInput
    case completed
    case failed
    case idle
}

public struct AgentSession: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var provider: ProviderID
    public var status: AgentStatus
    public var project: String
    public var source: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        provider: ProviderID,
        status: AgentStatus,
        project: String,
        source: String,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.provider = provider
        self.status = status
        self.project = project
        self.source = source
        self.updatedAt = updatedAt
    }
}

public enum WingPresentationMode: String, CaseIterable, Sendable {
    case automatic
    case full
    case compact
    case minimal
    case hidden
}

public enum DemoScenario: String, CaseIterable, Sendable {
    case normal
    case critical
    case waiting
    case error
}

public enum BeaconPolicy: String, CaseIterable, Sendable {
    case automatic
    case always
    case never
}
