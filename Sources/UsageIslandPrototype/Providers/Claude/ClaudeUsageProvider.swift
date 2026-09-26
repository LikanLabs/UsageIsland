import Foundation

enum ClaudeUsageError: Error, Equatable, Sendable {
    /// No reading yet from either source.
    case notConnected
    case invalidRecord
    /// No `claude` executable was found.
    case cliNotFound
    /// The CLI answered that this account has no plan limits.
    case noPlanLimits
    /// The CLI ran but gave no usable answer (often: not signed in).
    case queryFailed
}

extension ClaudeUsageError: ProviderIssueReporting {
    var issue: ProviderIssue {
        switch self {
        case .cliNotFound: .notInstalled
        case .noPlanLimits: .noPlanLimits
        case .queryFailed: .notSignedIn
        case .notConnected, .invalidRecord: .unavailable
        }
    }
}

/// Claude plan limits from two official sources, whichever is newest:
/// - the Claude Code CLI's structured `/usage` answer, which covers every
///   surface (terminal, desktop app, claude.ai) and is queried at most once
///   per `queryInterval`;
/// - the status line bridge record, written after each terminal reply.
/// Nothing is estimated and no credentials are read.
actor ClaudeUsageProvider: UsageProvider {
    nonisolated let id: ProviderID = .claude
    private static let shortWindowDuration = 300
    private static let weeklyWindowDuration = 10_080

    private let recordURL: URL
    private let clock: any UsageClock
    /// A reading older than this may miss usage elsewhere, so it is stale.
    private let freshnessInterval: TimeInterval
    private let queryInterval: TimeInterval
    private let makeQuery: @Sendable () -> (any ClaudeUsageQuerying)?
    private var lastQueryAttempt: Date?
    private var queried: (limits: ClaudeUsageResponseParser.Limits, capturedAt: Date)?
    private var inFlightQuery: Task<Void, Never>?
    /// Why the last CLI query produced nothing, reported when no reading exists.
    private var lastQueryError: ClaudeUsageError?

    init(
        recordURL: URL = ClaudeStatuslineBridge.defaultRecordURL,
        clock: any UsageClock,
        freshnessInterval: TimeInterval = 15 * 60,
        queryInterval: TimeInterval = 120,
        makeQuery: @escaping @Sendable () -> (any ClaudeUsageQuerying)? = { nil }
    ) {
        self.recordURL = recordURL
        self.clock = clock
        self.freshnessInterval = freshnessInterval
        self.queryInterval = queryInterval
        self.makeQuery = makeQuery
    }

    /// Locates `claude` on each query, so installing or moving it later works.
    static func cliQuery(locator: ExecutableLocator) -> @Sendable () -> (any ClaudeUsageQuerying)? {
        { (try? locator.locate("claude")).map { ClaudeUsageCommand(executableURL: $0) } }
    }

    func fetchUsage() async throws -> UsageSnapshot {
        await refreshQueryIfDue()
        let now = clock.now()
        let recordResult = Result { try readRecord() }
        let record = try? recordResult.get()
        let recordActivity = record.map { Date(timeIntervalSince1970: $0.capturedAt) }

        if let queried, (recordActivity.map { $0 <= queried.capturedAt } ?? true) {
            return try Self.snapshot(
                windows: queried.limits.windows,
                capturedAt: queried.capturedAt,
                lastActivityAt: recordActivity,
                now: now,
                freshnessInterval: freshnessInterval
            )
        }
        guard let record else {
            // A damaged record is worth reporting as such; a missing one
            // just means the CLI's answer (or its absence) is all there is.
            if case .failure(ClaudeUsageError.invalidRecord) = recordResult { throw ClaudeUsageError.invalidRecord }
            throw lastQueryError ?? ClaudeUsageError.notConnected
        }
        // The status line has only the plan-wide windows; keep the CLI's
        // per-model limits alongside them while they are still current.
        let scoped = (queried?.limits.windows ?? []).filter { window in
            window.scope != nil && !(window.resetsAt.map { $0 <= now } ?? false)
        }
        return try Self.snapshot(from: record, extraWindows: scoped, now: now, freshnessInterval: freshnessInterval)
    }

    private func refreshQueryIfDue() async {
        if let inFlightQuery { return await inFlightQuery.value }
        let now = clock.now()
        if let lastQueryAttempt, now.timeIntervalSince(lastQueryAttempt) < queryInterval { return }
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
                self.noteQueryFailure(failure == .limitsUnavailable ? .noPlanLimits : .queryFailed)
            } catch {
                self.noteQueryFailure(.queryFailed)
            }
        }
        inFlightQuery = task
        await task.value
        inFlightQuery = nil
    }

    private func store(_ limits: ClaudeUsageResponseParser.Limits) {
        queried = (limits, clock.now())
        lastQueryError = nil
    }

    private func noteQueryFailure(_ error: ClaudeUsageError) {
        lastQueryError = error
    }

    private func readRecord() throws -> ClaudeRateLimitRecord {
        let data: Data
        do {
            data = try Data(contentsOf: recordURL)
        } catch {
            throw ClaudeUsageError.notConnected
        }
        guard let record = try? JSONDecoder().decode(ClaudeRateLimitRecord.self, from: data) else {
            throw ClaudeUsageError.invalidRecord
        }
        return record
    }

    static func snapshot(
        from record: ClaudeRateLimitRecord,
        extraWindows: [ClaudeUsageResponseParser.Limits.Window] = [],
        now: Date,
        freshnessInterval: TimeInterval
    ) throws -> UsageSnapshot {
        guard record.version == ClaudeRateLimitRecord.currentVersion,
              record.capturedAt.isFinite, record.capturedAt > 0 else {
            throw ClaudeUsageError.invalidRecord
        }
        func window(_ window: ClaudeRateLimitRecord.Window?, duration: Int) throws -> ClaudeUsageResponseParser.Limits.Window? {
            guard let window else { return nil }
            guard window.resetsAt.isFinite, window.resetsAt > 0 else { throw ClaudeUsageError.invalidRecord }
            return .init(durationMinutes: duration, scope: nil, usedPercentage: window.usedPercentage,
                         resetsAt: Date(timeIntervalSince1970: window.resetsAt))
        }
        let capturedAt = Date(timeIntervalSince1970: record.capturedAt)
        let windows = try [
            window(record.fiveHour, duration: shortWindowDuration),
            window(record.sevenDay, duration: weeklyWindowDuration),
        ].compactMap { $0 } + extraWindows
        // Claude Code reports limits after each terminal reply, so the
        // record's time is the last moment Claude was in use.
        return try snapshot(
            windows: windows,
            capturedAt: capturedAt,
            lastActivityAt: capturedAt,
            now: now,
            freshnessInterval: freshnessInterval
        )
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
