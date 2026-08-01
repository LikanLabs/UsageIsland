import Foundation

struct CodexAccountResponse: Sendable {
    private enum Account: Sendable {
        case chatGPT
        case unsupported(CodexAccountMode)
        case absent
    }

    private static let supportedPlanTypes: Set<String> = [
        "free",
        "go",
        "plus",
        "pro",
        "prolite",
        "team",
        "self_serve_business_usage_based",
        "business",
        "enterprise_cbp_usage_based",
        "enterprise",
        "edu",
        "unknown"
    ]

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

    func validateAuthenticatedChatGPT() throws {
        switch account {
        case .chatGPT:
            return
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
                  case .string(let planType) = object["planType"],
                  supportedPlanTypes.contains(planType)
            else {
                throw CodexUsageError.invalidAccountResponse
            }
            return .chatGPT
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
    let durationMinutes: Int64?
    let usedPercent: Int
    let reset: CodexResetValue

    init(validating value: JSONValue) throws {
        guard case .object(let object) = value,
              let usedPercentValue = object["usedPercent"]
        else {
            throw CodexUsageError.invalidRateLimitResponse
        }

        durationMinutes = try Self.parseOptionalInteger(
            object["windowDurationMins"]
        )
        usedPercent = try Self.parseCanonicalPercent(usedPercentValue)
        reset = Self.parseReset(object["resetsAt"])
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

    private static func parseOptionalInteger(_ value: JSONValue?) throws -> Int64? {
        guard let value, value != .null else {
            return nil
        }
        guard case .integer(let integer) = value else {
            throw CodexUsageError.invalidRateLimitResponse
        }
        return integer
    }

    private static func parseReset(_ value: JSONValue?) -> CodexResetValue {
        guard let value, value != .null else {
            return .absentOrNull
        }
        switch value {
        case .integer(let integer):
            return .number(Double(integer))
        case .number(let number):
            return .number(number)
        default:
            return .invalid
        }
    }
}

enum CodexResetValue: Equatable, Sendable {
    case absentOrNull
    case number(Double)
    case invalid
}

struct CodexRateLimitSnapshot: Sendable {
    let windows: [CodexRateLimitWindow]

    init(validating value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw CodexUsageError.invalidRateLimitResponse
        }

        var windows: [CodexRateLimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let value = object[key], value != .null else {
                continue
            }
            windows.append(try CodexRateLimitWindow(validating: value))
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
}

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }
}
