import Foundation

public enum ProviderID: String, CaseIterable, Hashable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    public var compactSymbol: String {
        switch self {
        case .codex: "◈"
        case .claude: "✳"
        }
    }
}

/// Converts a provider's floating-point usage into the domain's integer
/// percent. Values strictly between 99 and 100 stay at 99 so a nearly spent
/// window is never reported as exhausted while quota remains.
public enum UsagePercent {
    public static func canonical(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        if value > 99 && value < 100 { return 99 }
        return Int(min(max(value, -1), 101).rounded(.toNearestOrAwayFromZero))
    }
}

public enum DataFreshness: Equatable, Sendable {
    case fresh
    case stale
    case unavailable
}

/// Why a provider has no usage to show, in terms the user can act on.
public enum ProviderIssue: Equatable, Sendable {
    /// The provider's CLI is not installed.
    case notInstalled
    /// The CLI is installed but not signed in to a subscription.
    case notSignedIn
    /// Signed in, but the account has no plan limits (for example an API
    /// key or usage-based billing).
    case noPlanLimits
    /// Anything else, usually temporary.
    case unavailable
}

/// Adopted by provider errors that know which `ProviderIssue` they mean.
public protocol ProviderIssueReporting: Error {
    var issue: ProviderIssue { get }
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

public struct UsageWindow: Equatable, Sendable, Identifiable {
    public let durationMinutes: Int
    public let usedPercent: Int
    public let resetsAt: Date?
    /// Set for a limit that applies to only part of the plan, as named by the
    /// provider (for example a single model's weekly limit); nil for the
    /// plan-wide window of that duration.
    public let scope: String?

    public var id: String { "\(durationMinutes)|\(scope ?? "")" }

    public var remainingPercent: Int {
        Self.clamp(100 - usedPercent)
    }

    /// True once the window's reset time has passed, meaning this reading
    /// describes a previous window and no longer reflects current usage.
    public func hasReset(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public init(
        durationMinutes: Int,
        usedPercent: Int,
        resetsAt: Date?,
        scope: String? = nil
    ) throws {
        guard durationMinutes > 0 else {
            throw UsageDomainError.invalidWindowDuration(durationMinutes)
        }
        self.init(
            validatedDurationMinutes: durationMinutes,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            scope: scope
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
        resetsAt: Date?,
        scope: String? = nil
    ) {
        self.durationMinutes = durationMinutes
        self.usedPercent = Self.clamp(usedPercent)
        self.resetsAt = resetsAt
        self.scope = scope
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
    /// When the provider last observed the user consuming quota, if it can
    /// tell. Providers that cannot leave this nil.
    public var lastActivityAt: Date?
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
        windows.first { $0.durationMinutes == 10_080 && $0.scope == nil }
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
        var windowIDs = Set<String>()
        for window in [preferredWindow] + additionalWindows {
            guard windowIDs.insert(window.id).inserted else {
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
