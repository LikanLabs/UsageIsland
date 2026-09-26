import Foundation

enum ClaudeUsageError: Error, Equatable, Sendable {
    /// No record yet: the bridge is not installed or Claude Code has not
    /// reported limits since it was.
    case notConnected
    case invalidRecord
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
        let record = try? readRecord()

        if let queried, record.map({ $0.capturedAt <= queried.capturedAt.timeIntervalSince1970 }) ?? true {
            return try Self.snapshot(
                fiveHour: queried.limits.fiveHour.map { ($0.usedPercentage, $0.resetsAt) },
                sevenDay: queried.limits.sevenDay.map { ($0.usedPercentage, $0.resetsAt) },
                capturedAt: queried.capturedAt,
                lastActivityAt: record.map { Date(timeIntervalSince1970: $0.capturedAt) },
                now: now,
                freshnessInterval: freshnessInterval
            )
        }
        guard let record else { throw ClaudeUsageError.notConnected }
        return try Self.snapshot(from: record, now: now, freshnessInterval: freshnessInterval)
    }

    private func refreshQueryIfDue() async {
        if let inFlightQuery { return await inFlightQuery.value }
        let now = clock.now()
        if let lastQueryAttempt, now.timeIntervalSince(lastQueryAttempt) < queryInterval { return }
        guard let query = makeQuery() else { return }
        lastQueryAttempt = now
        let task = Task {
            let limits = try? ClaudeUsageResponseParser.limits(from: await query.queryUsage())
            if let limits { self.store(limits) }
        }
        inFlightQuery = task
        await task.value
        inFlightQuery = nil
    }

    private func store(_ limits: ClaudeUsageResponseParser.Limits) {
        queried = (limits, clock.now())
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
        now: Date,
        freshnessInterval: TimeInterval
    ) throws -> UsageSnapshot {
        guard record.version == ClaudeRateLimitRecord.currentVersion,
              record.capturedAt.isFinite, record.capturedAt > 0 else {
            throw ClaudeUsageError.invalidRecord
        }
        func window(_ window: ClaudeRateLimitRecord.Window?) throws -> (Double, Date)? {
            guard let window else { return nil }
            guard window.resetsAt.isFinite, window.resetsAt > 0 else { throw ClaudeUsageError.invalidRecord }
            return (window.usedPercentage, Date(timeIntervalSince1970: window.resetsAt))
        }
        let capturedAt = Date(timeIntervalSince1970: record.capturedAt)
        // Claude Code reports limits after each terminal reply, so the
        // record's time is the last moment Claude was in use.
        return try snapshot(
            fiveHour: try window(record.fiveHour),
            sevenDay: try window(record.sevenDay),
            capturedAt: capturedAt,
            lastActivityAt: capturedAt,
            now: now,
            freshnessInterval: freshnessInterval
        )
    }

    static func snapshot(
        fiveHour: (used: Double, resetsAt: Date)?,
        sevenDay: (used: Double, resetsAt: Date)?,
        capturedAt: Date,
        lastActivityAt: Date?,
        now: Date,
        freshnessInterval: TimeInterval
    ) throws -> UsageSnapshot {
        func window(_ value: (used: Double, resetsAt: Date)?, duration: Int) throws -> UsageWindow? {
            guard let value else { return nil }
            guard let used = UsagePercent.canonical(value.used) else { throw ClaudeUsageError.invalidRecord }
            return try UsageWindow(durationMinutes: duration, usedPercent: used, resetsAt: value.resetsAt)
        }
        let windows = try [
            window(fiveHour, duration: shortWindowDuration),
            window(sevenDay, duration: weeklyWindowDuration),
        ].compactMap { $0 }
        guard let preferred = windows.first else { throw ClaudeUsageError.invalidRecord }

        var snapshot = try UsageSnapshot(
            provider: .claude,
            preferredWindow: preferred,
            additionalWindows: Array(windows.dropFirst()),
            weeklySpend: nil,
            freshness: now.timeIntervalSince(capturedAt) <= freshnessInterval ? .fresh : .stale,
            isActivelyUsed: false,
            capturedAt: capturedAt
        )
        snapshot.lastActivityAt = lastActivityAt
        return snapshot
    }
}
