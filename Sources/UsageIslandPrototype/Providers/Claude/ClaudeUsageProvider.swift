import Foundation

enum ClaudeUsageError: Error, Equatable, Sendable {
    /// No record yet: the bridge is not installed or Claude Code has not
    /// reported limits since it was.
    case notConnected
    case invalidRecord
}

/// Reads the plan limits that the Claude Code status line bridge stored.
/// Values are Claude Code's own official percentages; nothing is estimated.
struct ClaudeUsageProvider: UsageProvider {
    let id: ProviderID = .claude
    private static let shortWindowDuration = 300
    private static let weeklyWindowDuration = 10_080

    let recordURL: URL
    let clock: any UsageClock
    /// A reading older than this may miss usage from other devices or from
    /// claude.ai, so it is presented as stale.
    let freshnessInterval: TimeInterval

    init(
        recordURL: URL = ClaudeStatuslineBridge.defaultRecordURL,
        clock: any UsageClock,
        freshnessInterval: TimeInterval = 15 * 60
    ) {
        self.recordURL = recordURL
        self.clock = clock
        self.freshnessInterval = freshnessInterval
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: recordURL)
        } catch {
            throw ClaudeUsageError.notConnected
        }
        guard let record = try? JSONDecoder().decode(ClaudeRateLimitRecord.self, from: data) else {
            throw ClaudeUsageError.invalidRecord
        }
        return try Self.snapshot(from: record, now: clock.now(), freshnessInterval: freshnessInterval)
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
        let capturedAt = Date(timeIntervalSince1970: record.capturedAt)
        let windows = try [
            record.fiveHour.map { try window($0, duration: shortWindowDuration) },
            record.sevenDay.map { try window($0, duration: weeklyWindowDuration) },
        ].compactMap { $0 }
        guard let preferred = windows.first else { throw ClaudeUsageError.invalidRecord }

        let isFresh = now.timeIntervalSince(capturedAt) <= freshnessInterval
        var snapshot = try UsageSnapshot(
            provider: .claude,
            preferredWindow: preferred,
            additionalWindows: Array(windows.dropFirst()),
            weeklySpend: nil,
            freshness: isFresh ? .fresh : .stale,
            isActivelyUsed: false,
            capturedAt: capturedAt
        )
        // Claude Code reports limits after each response, so the record's
        // time is the last moment Claude was in use.
        snapshot.lastActivityAt = capturedAt
        return snapshot
    }

    private static func window(_ window: ClaudeRateLimitRecord.Window, duration: Int) throws -> UsageWindow {
        guard let used = UsagePercent.canonical(window.usedPercentage),
              window.resetsAt.isFinite, window.resetsAt > 0 else {
            throw ClaudeUsageError.invalidRecord
        }
        return try UsageWindow(
            durationMinutes: duration,
            usedPercent: used,
            resetsAt: Date(timeIntervalSince1970: window.resetsAt)
        )
    }
}
