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

public enum UsageDomainError: Error, Equatable, Sendable {
    case invalidWindowDuration(Int)
    case duplicateWindowDuration(Int)
}

public struct UsageWindow: Equatable, Sendable {
    public let durationMinutes: Int
    public let usedPercent: Int
    public let resetsAt: Date?

    public var remainingPercent: Int {
        Self.clamp(100 - usedPercent)
    }

    public init(
        durationMinutes: Int,
        usedPercent: Int,
        resetsAt: Date?
    ) throws {
        guard durationMinutes > 0 else {
            throw UsageDomainError.invalidWindowDuration(durationMinutes)
        }
        self.init(
            validatedDurationMinutes: durationMinutes,
            usedPercent: usedPercent,
            resetsAt: resetsAt
        )
    }

    public init(
        durationMinutes: Int,
        remainingPercent: Int,
        resetsAt: Date?
    ) throws {
        try self.init(
            durationMinutes: durationMinutes,
            usedPercent: 100 - Self.clamp(remainingPercent),
            resetsAt: resetsAt
        )
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    // Fixed in-module fixtures use explicit, test-covered positive durations.
    init(
        validatedDurationMinutes durationMinutes: Int,
        usedPercent: Int,
        resetsAt: Date?
    ) {
        self.durationMinutes = durationMinutes
        self.usedPercent = Self.clamp(usedPercent)
        self.resetsAt = resetsAt
    }

    init(
        validatedDurationMinutes durationMinutes: Int,
        remainingPercent: Int,
        resetsAt: Date?
    ) {
        self.init(
            validatedDurationMinutes: durationMinutes,
            usedPercent: 100 - Self.clamp(remainingPercent),
            resetsAt: resetsAt
        )
    }
}

public struct UsageSnapshot: Identifiable, Equatable, Sendable {
    public var provider: ProviderID
    public let preferredWindow: UsageWindow
    public let additionalWindows: [UsageWindow]
    public var weeklySpend: Decimal?
    public var freshness: DataFreshness
    public var isActivelyUsed: Bool
    public var capturedAt: Date

    public var id: ProviderID { provider }

    public var windows: [UsageWindow] {
        [preferredWindow] + additionalWindows
    }

    public var shortWindow: UsageWindow? {
        windows.first { $0.durationMinutes == 300 }
    }

    public var weeklyWindow: UsageWindow? {
        windows.first { $0.durationMinutes == 10_080 }
    }

    public var weeklyUsedPercent: Int? {
        weeklyWindow?.usedPercent
    }

    public var weeklyRemainingPercent: Int? {
        weeklyWindow?.remainingPercent
    }

    public var isCurrentlyActive: Bool {
        get { isActivelyUsed }
        set { isActivelyUsed = newValue }
    }

    public var priorityScore: Int {
        let remaining = preferredWindow.remainingPercent
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
        preferredWindow: UsageWindow,
        additionalWindows: [UsageWindow],
        weeklySpend: Decimal?,
        freshness: DataFreshness,
        isActivelyUsed: Bool,
        capturedAt: Date
    ) throws {
        var durations = Set<Int>()
        for window in [preferredWindow] + additionalWindows {
            guard durations.insert(window.durationMinutes).inserted else {
                throw UsageDomainError.duplicateWindowDuration(
                    window.durationMinutes
                )
            }
        }

        self.init(
            validatedProvider: provider,
            preferredWindow: preferredWindow,
            additionalWindows: additionalWindows,
            weeklySpend: weeklySpend,
            freshness: freshness,
            isActivelyUsed: isActivelyUsed,
            capturedAt: capturedAt
        )
    }

    public init(
        id: ProviderID,
        preferredWindow: UsageWindow,
        additionalWindows: [UsageWindow],
        weeklySpend: Decimal?,
        freshness: DataFreshness,
        isCurrentlyActive: Bool,
        capturedAt: Date
    ) throws {
        try self.init(
            provider: id,
            preferredWindow: preferredWindow,
            additionalWindows: additionalWindows,
            weeklySpend: weeklySpend,
            freshness: freshness,
            isActivelyUsed: isCurrentlyActive,
            capturedAt: capturedAt
        )
    }
    // Fixed in-module fixtures use explicit, test-covered unique durations.
    init(
        validatedProvider provider: ProviderID,
        preferredWindow: UsageWindow,
        additionalWindows: [UsageWindow],
        weeklySpend: Decimal?,
        freshness: DataFreshness,
        isActivelyUsed: Bool,
        capturedAt: Date
    ) {
        self.provider = provider
        self.preferredWindow = preferredWindow
        self.additionalWindows = additionalWindows
        self.weeklySpend = weeklySpend
        self.freshness = freshness
        self.isActivelyUsed = isActivelyUsed
        self.capturedAt = capturedAt
    }
}

public typealias ProviderUsage = UsageSnapshot
