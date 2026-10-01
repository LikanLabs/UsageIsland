import Foundation

enum ClaudeUsageError: Error, Equatable, Sendable {
    /// No reading yet.
    case notConnected
    case invalidRecord
    /// No `claude` executable was found.
    case cliNotFound
    /// The CLI answered that this account has no plan limits.
    case noPlanLimits
    /// The CLI ran but gave no usable answer (often: not signed in).
    case queryFailed
    /// Plan limits apply but none were available this time.
    case temporarilyUnavailable
}

extension ClaudeUsageError: ProviderIssueReporting {
    var issue: ProviderIssue {
        switch self {
        case .cliNotFound: .notInstalled
        case .noPlanLimits: .noPlanLimits
        case .queryFailed: .notSignedIn
        case .notConnected, .invalidRecord, .temporarilyUnavailable: .unavailable
        }
    }
}

/// Claude plan limits from the installed Claude Code CLI's structured
/// `/usage` answer, which covers every surface (terminal, desktop app,
/// claude.ai). Claude's usage service throttles frequent reads, so the CLI is
/// asked at most once per `queryInterval`, and after failed answers the wait
/// doubles (up to `maximumBackoff`) until one succeeds. Nothing is estimated
/// and no credentials are read.
actor ClaudeUsageProvider: UsageProvider {
    nonisolated let id: ProviderID = .claude
    private static let shortWindowDuration = 300

    private let clock: any UsageClock
    /// A reading older than this may miss recent usage, so it is stale.
    private let freshnessInterval: TimeInterval
    private let queryInterval: TimeInterval
    private let maximumBackoff: TimeInterval
    private var consecutiveFailures = 0
    private let makeQuery: @Sendable () -> (any ClaudeUsageQuerying)?
    private var lastQueryAttempt: Date?
    private var queried: (limits: ClaudeUsageResponseParser.Limits, capturedAt: Date)?
    private var inFlightQuery: Task<Void, Never>?
    /// Why the last CLI query produced nothing, reported when no reading exists.
    private var lastQueryError: ClaudeUsageError?

    init(
        clock: any UsageClock,
        freshnessInterval: TimeInterval = 15 * 60,
        queryInterval: TimeInterval = 300,
        maximumBackoff: TimeInterval = 3_600,
        makeQuery: @escaping @Sendable () -> (any ClaudeUsageQuerying)? = { nil }
    ) {
        self.clock = clock
        self.freshnessInterval = freshnessInterval
        self.queryInterval = queryInterval
        self.maximumBackoff = max(queryInterval, maximumBackoff)
        self.makeQuery = makeQuery
    }

    /// Locates `claude` on each query, so installing or moving it later works.
    static func cliQuery(locator: ExecutableLocator) -> @Sendable () -> (any ClaudeUsageQuerying)? {
        { (try? locator.locate("claude")).map { ClaudeUsageCommand(executableURL: $0) } }
    }

    func fetchUsage() async throws -> UsageSnapshot {
        await refreshQueryIfDue()
        guard let queried else { throw lastQueryError ?? ClaudeUsageError.notConnected }
        return try Self.snapshot(
            windows: queried.limits.windows,
            capturedAt: queried.capturedAt,
            lastActivityAt: nil,
            now: clock.now(),
            freshnessInterval: freshnessInterval
        )
    }

    private func refreshQueryIfDue() async {
        if let inFlightQuery { return await inFlightQuery.value }
        let now = clock.now()
        if let lastQueryAttempt, now.timeIntervalSince(lastQueryAttempt) < currentWait { return }
        lastQueryAttempt = now
        guard let query = makeQuery() else {
            lastQueryError = .cliNotFound
            return
        }
        let task = Task {
            do {
                let limits = try ClaudeUsageResponseParser.limits(from: await query.queryUsage())
                self.store(limits)
            } catch let failure as ClaudeUsageResponseParser.Failure {
                switch failure {
                case .limitsUnavailable: self.noteQueryFailure(.noPlanLimits)
                case .temporarilyUnavailable: self.noteQueryFailure(.temporarilyUnavailable)
                case .noResponse, .requestFailed: self.noteQueryFailure(.queryFailed)
                }
            } catch {
                self.noteQueryFailure(.queryFailed)
            }
        }
        inFlightQuery = task
        await task.value
        inFlightQuery = nil
    }

    /// The wait before the next query: the normal interval, doubled for
    /// each failed answer in a row, capped at `maximumBackoff`.
    var currentWait: TimeInterval {
        min(queryInterval * pow(2, Double(min(consecutiveFailures, 10))), maximumBackoff)
    }

    private func store(_ limits: ClaudeUsageResponseParser.Limits) {
        queried = (limits, clock.now())
        lastQueryError = nil
        consecutiveFailures = 0
    }

    private func noteQueryFailure(_ error: ClaudeUsageError) {
        lastQueryError = error
        consecutiveFailures += 1
    }

    static func snapshot(
        windows limits: [ClaudeUsageResponseParser.Limits.Window],
        capturedAt: Date,
        lastActivityAt: Date?,
        now: Date,
        freshnessInterval: TimeInterval
    ) throws -> UsageSnapshot {
        let windows = try limits.map { limit in
            guard let used = UsagePercent.canonical(limit.usedPercentage) else { throw ClaudeUsageError.invalidRecord }
            return try UsageWindow(durationMinutes: limit.durationMinutes, usedPercent: used,
                                   resetsAt: limit.resetsAt, scope: limit.scope)
        }
        // The pill shows the session when there is one, else the weekly limit.
        let preferredIndex = windows.firstIndex { $0.durationMinutes == shortWindowDuration && $0.scope == nil }
            ?? windows.firstIndex { $0.scope == nil }
            ?? windows.startIndex
        guard windows.indices.contains(preferredIndex) else { throw ClaudeUsageError.invalidRecord }
        var others = windows
        let preferred = others.remove(at: preferredIndex)

        var snapshot = try UsageSnapshot(
            provider: .claude,
            preferredWindow: preferred,
            additionalWindows: others,
            weeklySpend: nil,
            freshness: now.timeIntervalSince(capturedAt) <= freshnessInterval ? .fresh : .stale,
            isActivelyUsed: false,
            capturedAt: capturedAt
        )
        snapshot.lastActivityAt = lastActivityAt
        return snapshot
    }
}
