import Foundation

enum ClaudeUsageCommandError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputTooLarge
}

/// Asks the installed Claude Code CLI for its structured `/usage` data
/// (`get_usage` control request) and returns the raw stream-json output.
protocol ClaudeUsageQuerying: Sendable {
    func queryUsage() async throws -> Data
}

/// One short-lived `claude -p` process per query, using the CLI's own
/// sign-in. It is isolated from the user's setup: `--restricted` ignores user,
/// project and local settings (so no hooks or status line run),
/// `--strict-mcp-config` starts no MCP servers, `--tools ""` offers no tools
/// and `--no-session-persistence` saves no transcript. No prompt is sent, so
/// no model request is made and no tokens are used. The app runs this every
/// couple of minutes, so the child also skips Claude Code's update checks
/// and non-essential traffic (telemetry, error reports).
struct ClaudeUsageCommand: ClaudeUsageQuerying {
    static let requestID = "usage-island"
    static let request = Data(#"{"type":"control_request","request_id":"usage-island","request":{"subtype":"get_usage","skip_behaviors":true}}"#.utf8 + [0x0A])
    static let arguments = [
        "-p", "--verbose", "--restricted", "--strict-mcp-config",
        "--no-session-persistence", "--tools", "",
        "--input-format", "stream-json", "--output-format", "stream-json",
    ]

    static func environment(from base: [String: String]) -> [String: String] {
        var environment = base
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    let executableURL: URL
    var timeout: TimeInterval = 20
    var maximumOutputBytes = 1_048_576

    func queryUsage() async throws -> Data {
        let executableURL = executableURL
        let timeout = timeout
        let limit = maximumOutputBytes
        return try await withCheckedThrowingContinuation { continuation in
            // Blocking pipe reads stay off the cooperative thread pool.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try Self.run(executableURL: executableURL, timeout: timeout, limit: limit)
                })
            }
        }
    }

    private static func run(executableURL: URL, timeout: TimeInterval, limit: Int) throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment(from: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Diagnostics only; never parsed.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ClaudeUsageCommandError.launchFailed }

        let timedOut = TimeoutFlag()
        let deadline = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }

        // Closing stdin after the request makes the CLI answer and exit.
        try? input.fileHandleForWriting.write(contentsOf: request)
        try? input.fileHandleForWriting.close()

        var data = Data()
        let reader = output.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit {
                process.terminate()
                process.waitUntilExit()
                throw ClaudeUsageCommandError.outputTooLarge
            }
        }
        process.waitUntilExit()
        if timedOut.isSet { throw ClaudeUsageCommandError.timedOut }
        return data
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Parses the `get_usage` control response. The CLI marks this shape as
/// experimental, so anything unexpected is rejected rather than guessed.
enum ClaudeUsageResponseParser {
    struct Limits: Equatable, Sendable {
        struct Window: Equatable, Sendable {
            let durationMinutes: Int
            /// Server label for a partial limit, such as a model name.
            let scope: String?
            let usedPercentage: Double
            let resetsAt: Date?
        }

        /// In the server's order: session first, then the weekly limits.
        let windows: [Window]
    }

    enum Failure: Error, Equatable, Sendable {
        case noResponse
        case requestFailed
        /// API key or third-party provider sessions have no plan limits.
        case limitsUnavailable
        /// Plan limits apply, but Claude Code had none to report this time
        /// (for example while its usage service is throttling requests).
        case temporarilyUnavailable
    }

    static func limits(from output: Data) throws(Failure) -> Limits {
        for line in output.split(separator: 0x0A) {
            guard let message = try? JSONDecoder().decode(ControlMessage.self, from: Data(line)),
                  message.type == "control_response",
                  message.response?.requestID == ClaudeUsageCommand.requestID else { continue }
            guard message.response?.subtype == "success", let body = message.response?.response else {
                throw .requestFailed
            }
            guard body.rateLimitsAvailable else { throw .limitsUnavailable }
            guard let limits = body.rateLimits else { throw .temporarilyUnavailable }
            let windows = rows(limits.limits) ?? legacyWindows(limits)
            guard !windows.isEmpty else { throw .temporarilyUnavailable }
            return Limits(windows: windows)
        }
        throw .noResponse
    }

    /// The server's ordered `limits` rows, classified by `kind` only. Kinds
    /// this version does not know are skipped rather than guessed.
    private static func rows(_ rows: [ControlMessage.Row]?) -> [Limits.Window]? {
        guard let rows, !rows.isEmpty else { return nil }
        var seen = Set<String>()
        let windows: [Limits.Window] = rows.compactMap { row in
            guard let percent = row.percent, percent.isFinite else { return nil }
            let duration: Int
            var scope: String?
            switch row.kind {
            case "session": duration = 300
            case "weekly_all": duration = 10_080
            case "weekly_scoped":
                duration = 10_080
                scope = row.scope?.model?.displayName ?? row.scope?.surface?.displayName
                guard let name = scope?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
                scope = String(name.prefix(24))
            default: return nil
            }
            guard seen.insert("\(duration)|\(scope ?? "")").inserted else { return nil }
            return .init(durationMinutes: duration, scope: scope, usedPercentage: percent,
                         resetsAt: row.resetsAt.flatMap(date))
        }
        return windows.isEmpty ? nil : windows
    }

    private static func legacyWindows(_ limits: ControlMessage.RateLimits) -> [Limits.Window] {
        [(300, limits.fiveHour), (10_080, limits.sevenDay)].compactMap { duration, window in
            guard let window, let used = window.utilization, used.isFinite,
                  let text = window.resetsAt, let resetsAt = date(text) else { return nil }
            return .init(durationMinutes: duration, scope: nil, usedPercentage: used, resetsAt: resetsAt)
        }
    }

    static func date(_ text: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

private struct ControlMessage: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct Named: Decodable {
        let displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }

    struct Scope: Decodable {
        let model: Named?
        let surface: Named?
    }

    struct Row: Decodable {
        let kind: String
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }
    }

    struct RateLimits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Row]?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? container.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? container.decodeIfPresent(Window.self, forKey: .sevenDay)
            // One malformed row must not hide the others.
            limits = (try? container.decodeIfPresent([FailableRow].self, forKey: .limits))?.compactMap(\.row)
        }
    }

    struct FailableRow: Decodable {
        let row: Row?
        init(from decoder: Decoder) throws { row = try? Row(from: decoder) }
    }

    struct Body: Decodable {
        let rateLimitsAvailable: Bool
        let rateLimits: RateLimits?
        enum CodingKeys: String, CodingKey {
            case rateLimitsAvailable = "rate_limits_available"
            case rateLimits = "rate_limits"
        }
    }

    struct Response: Decodable {
        let subtype: String
        let requestID: String
        let response: Body?
        enum CodingKeys: String, CodingKey {
            case subtype
            case requestID = "request_id"
            case response
        }
    }

    let type: String
    let response: Response?
}
