import Foundation

enum CodexAccountMode: Equatable, Sendable {
    case noAccount
    case apiKey
    case amazonBedrock
    case unknown
}

enum CodexAppServerFailure: Equatable, Sendable {
    case executableUnavailable
    case startup
    case timeout
    case capacity
    case transport
    case protocolViolation
    case remote
}

enum CodexUsageError: Error, Equatable, Sendable {
    case notAuthenticated
    case unsupportedAccountMode(CodexAccountMode)
    case invalidAccountResponse
    case rateLimitsUnavailable
    case invalidCodexBucket
    case invalidRateLimitResponse
    case duplicateWindowDuration(Int)
    case invalidResetTimestamp
    case appServerFailure(CodexAppServerFailure)
    case stopped
}

extension CodexUsageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Codex is not authenticated with ChatGPT."
        case .unsupportedAccountMode(let mode):
            switch mode {
            case .noAccount:
                "Codex did not return an account for this authentication mode."
            case .apiKey:
                "Codex API-key accounts are not supported for usage snapshots."
            case .amazonBedrock:
                "Amazon Bedrock accounts are not supported for usage snapshots."
            case .unknown:
                "The current Codex account mode is not supported."
            }
        case .invalidAccountResponse:
            "Codex returned an invalid account response."
        case .rateLimitsUnavailable:
            "Codex rate limits are unavailable."
        case .invalidCodexBucket:
            "Codex returned an invalid Codex rate-limit bucket."
        case .invalidRateLimitResponse:
            "Codex returned an invalid rate-limit response."
        case .duplicateWindowDuration:
            "Codex returned duplicate rate-limit window durations."
        case .invalidResetTimestamp:
            "Codex returned an invalid rate-limit reset timestamp."
        case .appServerFailure(let failure):
            failure.safeDescription
        case .stopped:
            "The Codex usage provider has stopped."
        }
    }
}

private extension CodexAppServerFailure {
    var safeDescription: String {
        switch self {
        case .executableUnavailable:
            "The Codex executable is unavailable."
        case .startup:
            "The Codex app server could not start."
        case .timeout:
            "The Codex app server request timed out."
        case .capacity:
            "The Codex app server reached a configured resource limit."
        case .transport:
            "The Codex app server transport failed."
        case .protocolViolation:
            "The Codex app server returned an invalid protocol response."
        case .remote:
            "The Codex app server rejected the request."
        }
    }
}
