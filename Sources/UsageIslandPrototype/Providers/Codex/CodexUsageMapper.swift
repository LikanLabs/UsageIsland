import Foundation

enum CodexUsageMapper {
    private static let shortWindowDuration: Int64 = 300
    private static let weeklyWindowDuration: Int64 = 10_080
    private static let maximumShortResetTimestamp = 253_402_300_799.0

    static func validateAccount(_ value: JSONValue) throws {
        try CodexAccountResponse(validating: value)
            .validateAuthenticatedChatGPT()
    }

    static func mapRateLimits(
        _ value: JSONValue,
        capturedAt: Date
    ) throws -> UsageSnapshot {
        let response = try CodexRateLimitsResponse(validating: value)
        var shortWindow: CodexRateLimitWindow?
        var weeklyWindow: CodexRateLimitWindow?

        for window in response.windows {
            switch window.durationMinutes {
            case shortWindowDuration:
                guard shortWindow == nil else {
                    throw CodexUsageError.duplicateRecognizedWindow(.short)
                }
                shortWindow = window
            case weeklyWindowDuration:
                guard weeklyWindow == nil else {
                    throw CodexUsageError.duplicateRecognizedWindow(.weekly)
                }
                weeklyWindow = window
            default:
                guard window.reset != .invalid else {
                    throw CodexUsageError.invalidRateLimitResponse
                }
                continue
            }
        }

        guard let shortWindow else {
            throw CodexUsageError.missingShortWindow
        }
        let shortReset = try validatedShortReset(shortWindow.reset)
        if let weeklyWindow {
            try validateWeeklyReset(weeklyWindow.reset)
        }

        return UsageSnapshot(
            provider: .codex,
            shortWindow: UsageWindow(
                usedPercent: shortWindow.usedPercent,
                resetsAt: Date(timeIntervalSince1970: shortReset)
            ),
            weeklyUsedPercent: weeklyWindow?.usedPercent,
            weeklySpend: nil,
            freshness: .fresh,
            isActivelyUsed: false,
            capturedAt: capturedAt
        )
    }

    private static func validatedShortReset(_ reset: CodexResetValue) throws -> Double {
        guard case .number(let value) = reset,
              value.isFinite,
              value >= 0,
              value <= maximumShortResetTimestamp
        else {
            throw CodexUsageError.invalidResetTimestamp(.short)
        }
        return value
    }

    private static func validateWeeklyReset(_ reset: CodexResetValue) throws {
        guard case .number(let value) = reset else {
            guard reset == .absentOrNull else {
                throw CodexUsageError.invalidResetTimestamp(.weekly)
            }
            return
        }
        let represented = Date(timeIntervalSince1970: value)
            .timeIntervalSince1970
        guard value.isFinite, value >= 0, represented.isFinite else {
            throw CodexUsageError.invalidResetTimestamp(.weekly)
        }
    }
}
