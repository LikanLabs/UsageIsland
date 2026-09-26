import Foundation

/// Rate limits that Claude Code hands to its status line command, reduced to
/// the fields Usage Island needs. Nothing else from the status line input
/// (paths, model, session or cost data) is kept.
struct ClaudeRateLimitRecord: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let usedPercentage: Double
        let resetsAt: Double
    }

    static let currentVersion = 1

    let version: Int
    /// Unix seconds when Claude Code last reported these limits.
    let capturedAt: Double
    let fiveHour: Window?
    let sevenDay: Window?
}

/// Runs as Claude Code's status line command
/// (`UsageIslandPrototype --claude-statusline`): stores the official plan
/// limits for the app and prints a short status line.
enum ClaudeStatuslineBridge {
    static let argument = "--claude-statusline"

    static var defaultRecordURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Usage Island", isDirectory: true)
            .appendingPathComponent("claude-rate-limits.json", isDirectory: false)
    }

    /// Returns the status line text. Input without rate limits (API key
    /// users, or before the first response) leaves the stored record alone.
    @discardableResult
    static func run(input: Data, recordURL: URL = defaultRecordURL, now: Date = Date()) -> String {
        guard let record = record(from: input, now: now) else { return "" }
        try? write(record, to: recordURL)
        return statusText(for: record)
    }

    static func record(from input: Data, now: Date) -> ClaudeRateLimitRecord? {
        guard let status = try? JSONDecoder().decode(StatusLineInput.self, from: input),
              let limits = status.rateLimits else { return nil }
        let fiveHour = limits.fiveHour.flatMap(Self.window)
        let sevenDay = limits.sevenDay.flatMap(Self.window)
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeRateLimitRecord(
            version: ClaudeRateLimitRecord.currentVersion,
            capturedAt: now.timeIntervalSince1970,
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    static func statusText(for record: ClaudeRateLimitRecord) -> String {
        var parts: [String] = []
        if let fiveHour = record.fiveHour, let used = UsagePercent.canonical(fiveHour.usedPercentage) {
            parts.append("5h \(min(max(used, 0), 100))%")
        }
        if let sevenDay = record.sevenDay, let used = UsagePercent.canonical(sevenDay.usedPercentage) {
            parts.append("7d \(min(max(used, 0), 100))%")
        }
        return parts.joined(separator: " · ")
    }

    static func write(_ record: ClaudeRateLimitRecord, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic replacement: the app never reads a half-written record.
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    private static func window(_ window: StatusLineInput.Window) -> ClaudeRateLimitRecord.Window? {
        guard let used = window.usedPercentage, used.isFinite,
              let resets = window.resetsAt, resets.isFinite, resets > 0 else { return nil }
        return .init(usedPercentage: used, resetsAt: resets)
    }
}

/// The subset of Claude Code's documented status line input that is read.
private struct StatusLineInput: Decodable {
    struct Window: Decodable {
        let usedPercentage: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    struct RateLimits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    let rateLimits: RateLimits?

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}
