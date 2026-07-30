import Foundation

public enum ProviderID: String, CaseIterable, Hashable, Identifiable, Sendable {
    case claude
    case codex
    case openCodeGo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .openCodeGo: "OpenCode Go"
        }
    }

    public var compactSymbol: String {
        switch self {
        case .claude: "✳"
        case .codex: "◈"
        case .openCodeGo: "○"
        }
    }
}

public enum DataFreshness: Equatable, Sendable {
    case fresh
    case stale
    case unavailable
}

public enum ProviderConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

public enum AppModelConfigurationError: Error, Equatable, Sendable {
    case duplicateProviderAdapter(ProviderID)
    case duplicateInitialSnapshot(ProviderID)
    case snapshotWithoutAdapter(ProviderID)
}

public struct UsageWindow: Equatable, Sendable {
    public private(set) var usedPercent: Int
    public var resetsAt: Date

    public var remainingPercent: Int {
        Self.clamp(100 - usedPercent)
    }

    public init(usedPercent: Int, resetsAt: Date) {
        self.usedPercent = Self.clamp(usedPercent)
        self.resetsAt = resetsAt
    }

    public init(remainingPercent: Int, resetsAt: Date) {
        self.init(usedPercent: 100 - Self.clamp(remainingPercent), resetsAt: resetsAt)
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }
}

public struct UsageSnapshot: Identifiable, Equatable, Sendable {
    public var provider: ProviderID
    public var shortWindow: UsageWindow
    public private(set) var weeklyUsedPercent: Int?
    public var weeklySpend: Decimal?
    public var freshness: DataFreshness
    public var isActivelyUsed: Bool
    public var capturedAt: Date

    public var id: ProviderID { provider }

    public var weeklyRemainingPercent: Int? {
        weeklyUsedPercent.map { min(max(100 - $0, 0), 100) }
    }

    public var isCurrentlyActive: Bool {
        get { isActivelyUsed }
        set { isActivelyUsed = newValue }
    }

    public var priorityScore: Int {
        let remaining = shortWindow.remainingPercent
        let thresholdScore: Int
        if remaining <= 10 {
            thresholdScore = 1_000
        } else if remaining <= 30 {
            thresholdScore = 500
        } else {
            thresholdScore = 0
        }

        return thresholdScore + (isActivelyUsed ? 250 : 0) + (100 - remaining)
    }

    public init(
        provider: ProviderID,
        shortWindow: UsageWindow,
        weeklyUsedPercent: Int?,
        weeklySpend: Decimal?,
        freshness: DataFreshness,
        isActivelyUsed: Bool,
        capturedAt: Date
    ) {
        self.provider = provider
        self.shortWindow = shortWindow
        self.weeklyUsedPercent = weeklyUsedPercent.map { min(max($0, 0), 100) }
        self.weeklySpend = weeklySpend
        self.freshness = freshness
        self.isActivelyUsed = isActivelyUsed
        self.capturedAt = capturedAt
    }

    public init(
        id: ProviderID,
        shortWindow: UsageWindow,
        weeklyRemainingPercent: Int?,
        weeklySpend: Decimal?,
        freshness: DataFreshness,
        isCurrentlyActive: Bool,
        capturedAt: Date
    ) {
        self.init(
            provider: id,
            shortWindow: shortWindow,
            weeklyUsedPercent: weeklyRemainingPercent.map { 100 - min(max($0, 0), 100) },
            weeklySpend: weeklySpend,
            freshness: freshness,
            isActivelyUsed: isCurrentlyActive,
            capturedAt: capturedAt
        )
    }
}

public typealias ProviderUsage = UsageSnapshot
