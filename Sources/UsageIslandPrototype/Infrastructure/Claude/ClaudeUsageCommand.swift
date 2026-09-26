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
/// no model request is made and no tokens are used.
struct ClaudeUsageCommand: ClaudeUsageQuerying {
    static let requestID = "usage-island"
    static let request = Data(#"{"type":"control_request","request_id":"usage-island","request":{"subtype":"get_usage","skip_behaviors":true}}"#.utf8 + [0x0A])
    static let arguments = [
        "-p", "--verbose", "--restricted", "--strict-mcp-config",
        "--no-session-persistence", "--tools", "",
        "--input-format", "stream-json", "--output-format", "stream-json",
    ]

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
            let usedPercentage: Double
            let resetsAt: Date
        }

        let fiveHour: Window?
        let sevenDay: Window?
    }

    enum Failure: Error, Equatable, Sendable {
        case noResponse
        case requestFailed
        /// API key or third-party provider sessions have no plan limits.
        case limitsUnavailable
    }

    static func limits(from output: Data) throws(Failure) -> Limits {
        for line in output.split(separator: 0x0A) {
            guard let message = try? JSONDecoder().decode(ControlMessage.self, from: Data(line)),
                  message.type == "control_response",
                  message.response?.requestID == ClaudeUsageCommand.requestID else { continue }
            guard message.response?.subtype == "success", let body = message.response?.response else {
                throw .requestFailed
            }
            guard body.rateLimitsAvailable, let limits = body.rateLimits else { throw .limitsUnavailable }
            let result = Limits(fiveHour: window(limits.fiveHour), sevenDay: window(limits.sevenDay))
            guard result.fiveHour != nil || result.sevenDay != nil else { throw .limitsUnavailable }
            return result
        }
        throw .noResponse
    }

    private static func window(_ window: ControlMessage.Window?) -> Limits.Window? {
        guard let window, let used = window.utilization, used.isFinite,
              let text = window.resetsAt, let resetsAt = date(text) else { return nil }
        return .init(usedPercentage: used, resetsAt: resetsAt)
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

    struct RateLimits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
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
