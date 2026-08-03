import Foundation

enum CodexPlanType: Equatable, Sendable {
    case free
    case go
    case plus
    case pro
    case proLite
    case team
    case selfServeBusinessUsageBased
    case business
    case enterpriseCBPUsageBased
    case enterprise
    case education
    case unknown

    init(sanitizing value: String) {
        switch value {
        case "free": self = .free
        case "go": self = .go
        case "plus": self = .plus
        case "pro": self = .pro
        case "prolite": self = .proLite
        case "team": self = .team
        case "self_serve_business_usage_based":
            self = .selfServeBusinessUsageBased
        case "business": self = .business
        case "enterprise_cbp_usage_based":
            self = .enterpriseCBPUsageBased
        case "enterprise": self = .enterprise
        case "edu": self = .education
        case "unknown": self = .unknown
        default: self = .unknown
        }
    }
}

struct CodexAccountResponse: Sendable {
    private enum Account: Sendable {
        case chatGPT(CodexPlanType)
        case unsupported(CodexAccountMode)
        case absent
    }

    private let requiresOpenAIAuth: Bool
    private let account: Account

    init(validating value: JSONValue) throws {
        guard case .object(let object) = value,
              case .bool(let requiresOpenAIAuth) = object["requiresOpenaiAuth"]
        else {
            throw CodexUsageError.invalidAccountResponse
        }

        self.requiresOpenAIAuth = requiresOpenAIAuth
        account = try Self.parseAccount(object["account"])
    }

    func validateAuthenticatedChatGPT() throws -> CodexPlanType {
        switch account {
        case .chatGPT(let planType):
            return planType
        case .absent where requiresOpenAIAuth:
            throw CodexUsageError.notAuthenticated
        case .absent:
            throw CodexUsageError.unsupportedAccountMode(.noAccount)
        case .unsupported(let mode):
            throw CodexUsageError.unsupportedAccountMode(mode)
        }
    }

    private static func parseAccount(_ value: JSONValue?) throws -> Account {
        guard let value, value != .null else {
            return .absent
        }
        guard case .object(let object) = value,
              case .string(let type) = object["type"]
        else {
            throw CodexUsageError.invalidAccountResponse
        }

        switch type {
        case "chatgpt":
            guard let email = object["email"],
                  email == .null || email.stringValue != nil,
                  case .string(let planType) = object["planType"]
            else {
                throw CodexUsageError.invalidAccountResponse
            }
            return .chatGPT(CodexPlanType(sanitizing: planType))
        case "apiKey":
            return .unsupported(.apiKey)
        case "amazonBedrock":
            return .unsupported(.amazonBedrock)
        default:
            return .unsupported(.unknown)
        }
    }
}

struct CodexRateLimitWindow: Sendable {
    private static let maximumResetTimestamp = 253_402_300_799.0

    let durationMinutes: Int
    let usedPercent: Int
    let resetsAt: Date?

    static func parse(_ value: JSONValue) throws -> CodexRateLimitWindow? {
        guard case .object(let object) = value else {
            throw CodexUsageError.invalidRateLimitResponse
        }

        guard let durationMinutes = parsePositiveDuration(
            object["windowDurationMins"]
        ) else {
            return nil
        }
        guard let usedPercentValue = object["usedPercent"] else {
            throw CodexUsageError.invalidRateLimitResponse
        }

        return CodexRateLimitWindow(
            durationMinutes: durationMinutes,
            usedPercent: try parseCanonicalPercent(usedPercentValue),
            resetsAt: try parseReset(object["resetsAt"])
        )
    }

    private static func parseCanonicalPercent(_ value: JSONValue) throws -> Int {
        let number: Double
        switch value {
        case .integer(let integer):
            number = Double(integer)
        case .number(let value):
            number = value
        default:
            throw CodexUsageError.invalidRateLimitResponse
        }

        return try roundedCanonicalPercent(number)
    }

    private static func roundedCanonicalPercent(_ number: Double) throws -> Int {
        guard number.isFinite else {
            throw CodexUsageError.invalidRateLimitResponse
        }
        let rounded = number.rounded(.toNearestOrAwayFromZero)
        let intLowerBound = Double(Int.min)
        let intUpperBoundExclusive = -intLowerBound
        guard rounded >= intLowerBound,
              rounded < intUpperBoundExclusive else {
            throw CodexUsageError.invalidRateLimitResponse
        }

        // Codex uses f64 percentages, while the approved v26 domain stores Int.
        // Round only at this boundary so a future precise domain can retain f64.
        // Double(Int.max) rounds up to the exclusive bound, so derive it from Int.min.
        return Int(rounded)
    }

    private static func parsePositiveDuration(_ value: JSONValue?) -> Int? {
        guard let value, value != .null else {
            return nil
        }

        switch value {
        case .integer(let integer):
            guard integer > 0 else { return nil }
            return Int(integer)
        case .number(let number):
            let upperBoundExclusive = -Double(Int.min)
            guard number.isFinite,
                  number > 0,
                  number.rounded(.towardZero) == number,
                  number < upperBoundExclusive else {
                return nil
            }
            return Int(number)
        default:
            return nil
        }
    }

    private static func parseReset(_ value: JSONValue?) throws -> Date? {
        guard let value, value != .null else {
            return nil
        }

        let timestamp: Double
        switch value {
        case .integer(let integer):
            timestamp = Double(integer)
        case .number(let number):
            timestamp = number
        default:
            throw CodexUsageError.invalidResetTimestamp
        }

        guard timestamp.isFinite,
              timestamp >= 0,
              timestamp <= maximumResetTimestamp else {
            throw CodexUsageError.invalidResetTimestamp
        }
        return Date(timeIntervalSince1970: timestamp)
    }
}

struct CodexRateLimitSnapshot: Sendable {
    let windows: [CodexRateLimitWindow]
    let planType: CodexPlanType?

    init(validating value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw CodexUsageError.invalidRateLimitResponse
        }

        switch object["planType"] {
        case nil, .some(.null):
            planType = nil
        case .some(.string(let value)):
            planType = CodexPlanType(sanitizing: value)
        default:
            throw CodexUsageError.invalidRateLimitResponse
        }

        var windows: [CodexRateLimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let value = object[key], value != .null else {
                continue
            }
            if let window = try CodexRateLimitWindow.parse(value) {
                windows.append(window)
            }
        }
        self.windows = windows
    }
}

struct CodexRateLimitsResponse: Sendable {
    private let selectedSnapshot: CodexRateLimitSnapshot

    init(validating value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw CodexUsageError.invalidRateLimitResponse
        }

        if let bucketsValue = object["rateLimitsByLimitId"],
           bucketsValue != .null {
            guard case .object(let buckets) = bucketsValue else {
                throw CodexUsageError.invalidRateLimitResponse
            }
            if let codexBucket = buckets["codex"] {
                guard codexBucket != .null else {
                    throw CodexUsageError.invalidCodexBucket
                }
                do {
                    selectedSnapshot = try CodexRateLimitSnapshot(
                        validating: codexBucket
                    )
                } catch {
                    throw CodexUsageError.invalidCodexBucket
                }
                return
            }
        }

        guard let fallback = object["rateLimits"], fallback != .null else {
            throw CodexUsageError.rateLimitsUnavailable
        }
        selectedSnapshot = try CodexRateLimitSnapshot(validating: fallback)
    }

    var windows: [CodexRateLimitWindow] {
        selectedSnapshot.windows
    }

    var planType: CodexPlanType? {
        selectedSnapshot.planType
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }
}
