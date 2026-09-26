import Foundation

enum CodexUsageMapper {
    private static let shortWindowDuration = 300
    private static let weeklyWindowDuration = 10_080

    @discardableResult
    static func validateAccount(_ value: JSONValue) throws -> CodexPlanType {
        try CodexAccountResponse(validating: value)
            .validateAuthenticatedChatGPT()
    }

    static func mapRateLimits(
        _ value: JSONValue,
        capturedAt: Date
    ) throws -> UsageSnapshot {
        let response = try CodexRateLimitsResponse(validating: value)
        var durations = Set<Int>()
        var windows: [UsageWindow] = []

        for window in response.windows {
            guard durations.insert(window.durationMinutes).inserted else {
                throw CodexUsageError.duplicateWindowDuration(
                    window.durationMinutes
                )
            }
            do {
                windows.append(
                    try UsageWindow(
                        durationMinutes: window.durationMinutes,
                        usedPercent: window.usedPercent,
                        resetsAt: window.resetsAt
                    )
                )
            } catch {
                throw CodexUsageError.invalidRateLimitResponse
            }
        }

        guard !windows.isEmpty else {
            throw CodexUsageError.rateLimitsUnavailable
        }

        let preferredIndex = windows.firstIndex {
            $0.durationMinutes == shortWindowDuration
        } ?? windows.firstIndex {
            $0.durationMinutes == weeklyWindowDuration
        } ?? windows.startIndex

        let preferredWindow = windows[preferredIndex]
        var additionalWindows = windows.enumerated().compactMap { index, window in
            index == preferredIndex ? nil : window
        }
        // Separate named buckets appear after the main windows, labelled by
        // the backend's own name; a bad bucket never hides the main limits.
        for bucket in response.additionalBuckets {
            var seen = Set<Int>()
            for window in bucket.windows where seen.insert(window.durationMinutes).inserted {
                if let scoped = try? UsageWindow(
                    durationMinutes: window.durationMinutes,
                    usedPercent: window.usedPercent,
                    resetsAt: window.resetsAt,
                    scope: bucket.name
                ) {
                    additionalWindows.append(scoped)
                }
            }
        }

        do {
            return try UsageSnapshot(
                provider: .codex,
                preferredWindow: preferredWindow,
                additionalWindows: additionalWindows,
                weeklySpend: nil,
                freshness: .fresh,
                isActivelyUsed: false,
                capturedAt: capturedAt
            )
        } catch {
            throw CodexUsageError.invalidRateLimitResponse
        }
    }
}
