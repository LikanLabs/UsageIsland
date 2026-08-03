import Foundation
import XCTest

@testable import UsageIslandPrototype

final class CodexUsageMapperTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_234)
    private let maximumReset = 253_402_300_799.0

    func testLocalSchemaPlanTypesAreNormalizedAndFutureValuesAreSanitized() throws {
        let cases: [(String, CodexPlanType)] = [
            ("free", .free),
            ("go", .go),
            ("plus", .plus),
            ("pro", .pro),
            ("prolite", .proLite),
            ("team", .team),
            ("self_serve_business_usage_based", .selfServeBusinessUsageBased),
            ("business", .business),
            ("enterprise_cbp_usage_based", .enterpriseCBPUsageBased),
            ("enterprise", .enterprise),
            ("edu", .education),
            ("unknown", .unknown),
            ("future-private-plan", .unknown)
        ]

        for (rawValue, expected) in cases {
            let plan = try CodexUsageMapper.validateAccount(
                chatGPTAccount(planType: rawValue)
            )
            XCTAssertEqual(plan, expected)
            if rawValue == "future-private-plan" {
                XCTAssertFalse(String(describing: plan).contains(rawValue))
            }
        }
    }

    func testValidChatGPTAccountAcceptsNullableEmailAndFutureFields() throws {
        let plan = try CodexUsageMapper.validateAccount(
            .object([
                "requiresOpenaiAuth": .bool(true),
                "account": .object([
                    "type": .string("chatgpt"),
                    "email": .null,
                    "planType": .string("plus"),
                    "future": .string("ignored")
                ]),
                "future": .bool(true)
            ])
        )

        XCTAssertEqual(plan, .plus)
    }

    func testAccountClassification() {
        let cases: [(JSONValue, CodexUsageError)] = [
            (
                .object(["requiresOpenaiAuth": .bool(true), "account": .null]),
                .notAuthenticated
            ),
            (
                .object(["requiresOpenaiAuth": .bool(false), "account": .null]),
                .unsupportedAccountMode(.noAccount)
            ),
            (account(type: "apiKey"), .unsupportedAccountMode(.apiKey)),
            (
                account(type: "amazonBedrock"),
                .unsupportedAccountMode(.amazonBedrock)
            ),
            (
                account(type: "future-provider-private-value"),
                .unsupportedAccountMode(.unknown)
            )
        ]

        for (value, expected) in cases {
            XCTAssertThrowsError(try CodexUsageMapper.validateAccount(value)) {
                XCTAssertEqual($0 as? CodexUsageError, expected)
                XCTAssertFalse(
                    ($0 as? LocalizedError)?.errorDescription?
                        .contains("future-provider-private-value") == true
                )
            }
        }
    }

    func testMalformedAccountPayloadsAreRejectedWithoutPersonalDataInError() {
        let privateEmail = "private.person@example.test"
        let malformed: [JSONValue] = [
            .null,
            .object(["account": .null]),
            .object(["requiresOpenaiAuth": .string("yes")]),
            .object([
                "requiresOpenaiAuth": .bool(true),
                "account": .object(["type": .integer(1)])
            ]),
            .object([
                "requiresOpenaiAuth": .bool(true),
                "account": .object([
                    "type": .string("chatgpt"),
                    "email": .string(privateEmail)
                ])
            ]),
            .object([
                "requiresOpenaiAuth": .bool(true),
                "account": .object([
                    "type": .string("chatgpt"),
                    "email": .string(privateEmail),
                    "planType": .integer(1)
                ])
            ])
        ]

        for value in malformed {
            XCTAssertThrowsError(try CodexUsageMapper.validateAccount(value)) {
                XCTAssertEqual($0 as? CodexUsageError, .invalidAccountResponse)
                XCTAssertFalse(String(describing: $0).contains(privateEmail))
                XCTAssertFalse(
                    ($0 as? LocalizedError)?.errorDescription?
                        .contains(privateEmail) == true
                )
            }
        }
    }

    func testSamePlanCanExposeDifferentCapabilities() throws {
        let accountPlan = try CodexUsageMapper.validateAccount(
            chatGPTAccount(planType: "plus")
        )
        let both = try map(
            primary: window(duration: 300, used: 20, reset: 1_000),
            secondary: window(duration: 10_080, used: 40, reset: 2_000),
            planType: "plus"
        )
        let weeklyOnly = try map(
            primary: window(duration: 10_080, used: 40, reset: 2_000),
            secondary: .null,
            planType: "plus"
        )
        let proWeeklyOnly = try map(
            primary: window(duration: 10_080, used: 45, reset: nil),
            secondary: .null,
            planType: "pro"
        )
        let proBoth = try map(
            primary: window(duration: 300, used: 25, reset: nil),
            secondary: window(duration: 10_080, used: 45, reset: nil),
            planType: "pro"
        )

        XCTAssertEqual(accountPlan, .plus)
        XCTAssertEqual(both.preferredWindow.durationMinutes, 300)
        XCTAssertEqual(weeklyOnly.preferredWindow.durationMinutes, 10_080)
        XCTAssertNil(weeklyOnly.shortWindow)
        XCTAssertEqual(proWeeklyOnly.windows.map(\.durationMinutes), [10_080])
        XCTAssertEqual(proBoth.windows.map(\.durationMinutes), [300, 10_080])
    }

    func testAccountAndBucketPlanDifferenceDoesNotInvalidateWindows() throws {
        XCTAssertEqual(
            try CodexUsageMapper.validateAccount(chatGPTAccount(planType: "pro")),
            .pro
        )
        let response = response(
            fallback: snapshot(primary: nil, secondary: nil),
            buckets: .object([
                "codex": snapshot(
                    primary: window(duration: 300, used: 25, reset: 1_000),
                    secondary: window(
                        duration: 10_080,
                        used: 50,
                        reset: 2_000
                    ),
                    planType: "plus"
                )
            ])
        )

        let parsed = try CodexRateLimitsResponse(validating: response)
        let result = try CodexUsageMapper.mapRateLimits(
            response,
            capturedAt: capturedAt
        )

        XCTAssertEqual(parsed.planType, .plus)
        XCTAssertEqual(result.windows.map(\.durationMinutes), [300, 10_080])
    }

    func testUnknownBucketPlanDoesNotPreventValidSnapshot() throws {
        let value = response(
            fallback: snapshot(primary: nil, secondary: nil),
            buckets: .object([
                "codex": snapshot(
                    primary: window(duration: 15, used: 25, reset: nil),
                    secondary: .null,
                    planType: "future-private-plan"
                )
            ])
        )

        XCTAssertEqual(
            try CodexRateLimitsResponse(validating: value).planType,
            .unknown
        )
        XCTAssertEqual(
            try CodexUsageMapper.mapRateLimits(
                value,
                capturedAt: capturedAt
            ).preferredWindow.durationMinutes,
            15
        )
    }

    func testCodexBucketIsPreferredWithoutMixingFallbackWindows() throws {
        let value = response(
            fallback: snapshot(
                primary: window(duration: 300, used: 91, reset: 1_000),
                secondary: window(duration: 10_080, used: 92, reset: 2_000)
            ),
            buckets: .object([
                "codex": snapshot(
                    primary: window(duration: 10_080, used: 21, reset: 3_000),
                    secondary: .null
                ),
                "unknown": .string("ignored")
            ])
        )

        let result = try CodexUsageMapper.mapRateLimits(
            value,
            capturedAt: capturedAt
        )

        XCTAssertEqual(result.windows.map(\.durationMinutes), [10_080])
        XCTAssertEqual(result.preferredWindow.usedPercent, 21)
        XCTAssertEqual(
            result.preferredWindow.resetsAt?.timeIntervalSince1970,
            3_000
        )
    }

    func testFallbackIsUsedOnlyWhenCodexKeyIsAbsent() throws {
        let fallback = snapshot(
            primary: window(duration: 300, used: 32, reset: 4_000),
            secondary: window(duration: 10_080, used: 44, reset: nil)
        )

        for buckets in [nil, JSONValue.null, .object(["other": .null])] {
            let result = try CodexUsageMapper.mapRateLimits(
                response(fallback: fallback, buckets: buckets),
                capturedAt: capturedAt
            )
            XCTAssertEqual(result.preferredWindow.usedPercent, 32)
            XCTAssertEqual(result.weeklyUsedPercent, 44)
        }
    }

    func testPresentInvalidCodexBucketNeverFallsBack() {
        let validFallback = snapshot(
            primary: window(duration: 300, used: 1, reset: 1),
            secondary: .null
        )
        let invalidBuckets: [JSONValue] = [
            .object(["codex": .null]),
            .object(["codex": .string("malformed")]),
            .object([
                "codex": snapshot(
                    primary: window(
                        duration: 300,
                        used: .string("private"),
                        reset: nil
                    ),
                    secondary: .null
                )
            ]),
            .object([
                "codex": snapshot(
                    primary: window(duration: 300, used: 1, reset: nil),
                    secondary: .null,
                    planType: JSONValue.integer(1)
                )
            ])
        ]

        for buckets in invalidBuckets {
            XCTAssertThrowsError(
                try CodexUsageMapper.mapRateLimits(
                    response(fallback: validFallback, buckets: buckets),
                    capturedAt: capturedAt
                )
            ) {
                XCTAssertEqual($0 as? CodexUsageError, .invalidCodexBucket)
            }
        }
    }

    func testPreferredWindowSelectionUsesAvailabilityAndProtocolOrder() throws {
        let cases: [(JSONValue?, JSONValue?, Int, [Int])] = [
            (
                window(duration: 300, used: 20, reset: nil),
                window(duration: 10_080, used: 40, reset: nil),
                300,
                [300, 10_080]
            ),
            (window(duration: 300, used: 20, reset: nil), .null, 300, [300]),
            (
                window(duration: 10_080, used: 40, reset: nil),
                .null,
                10_080,
                [10_080]
            ),
            (window(duration: 15, used: 20, reset: nil), .null, 15, [15]),
            (
                window(duration: 15, used: 20, reset: nil),
                window(duration: 10_080, used: 40, reset: nil),
                10_080,
                [10_080, 15]
            ),
            (
                window(duration: 10_080, used: 40, reset: nil),
                window(duration: 300, used: 20, reset: nil),
                300,
                [300, 10_080]
            ),
            (
                window(duration: 15, used: 20, reset: nil),
                window(duration: 90, used: 40, reset: nil),
                15,
                [15, 90]
            )
        ]

        for (primary, secondary, preferred, orderedDurations) in cases {
            let result = try map(primary: primary, secondary: secondary)
            XCTAssertEqual(result.preferredWindow.durationMinutes, preferred)
            XCTAssertEqual(
                result.windows.map(\.durationMinutes),
                orderedDurations
            )
        }
    }

    func testInvalidDurationIsIgnoredWhenAnotherWindowIsValid() throws {
        let invalidDurations: [JSONValue?] = [
            nil,
            .null,
            .integer(0),
            .integer(-1),
            .number(15.5),
            .number(.infinity),
            .number(-Double(Int.min)),
            .string("invalid")
        ]

        for duration in invalidDurations {
            let result = try map(
                primary: window(
                    duration: duration,
                    used: .string("ignored-with-unusable-duration"),
                    reset: .string("ignored-with-unusable-duration")
                ),
                secondary: window(duration: 15, used: 25, reset: nil)
            )
            XCTAssertEqual(result.windows.map(\.durationMinutes), [15])
        }
    }

    func testNoUsableWindowsReturnsUnavailableWithoutSnapshot() {
        XCTAssertThrowsError(
            try map(
                primary: window(duration: nil, used: 20, reset: nil),
                secondary: window(duration: -1, used: 30, reset: nil)
            )
        ) {
            XCTAssertEqual($0 as? CodexUsageError, .rateLimitsUnavailable)
        }
    }

    func testDuplicateDurationsAreRejected() {
        for duration in [15, 300, 10_080] {
            XCTAssertThrowsError(
                try map(
                    primary: window(duration: Int64(duration), used: 10, reset: 10),
                    secondary: window(duration: Int64(duration), used: 20, reset: 20)
                )
            ) {
                XCTAssertEqual(
                    $0 as? CodexUsageError,
                    .duplicateWindowDuration(duration)
                )
            }
        }
    }

    func testIntegralNumericDurationAndUnknownPositiveDurationArePreserved() throws {
        let result = try map(
            primary: window(
                duration: .number(75.0),
                used: .integer(20),
                reset: nil
            ),
            secondary: .null
        )

        XCTAssertEqual(result.preferredWindow.durationMinutes, 75)
    }

    func testResetMayBeNullAndValidTimestampBecomesAbsoluteDate() throws {
        let result = try map(
            primary: window(
                duration: 300,
                used: 20,
                reset: .number(maximumReset)
            ),
            secondary: window(duration: 10_080, used: 40, reset: nil)
        )

        XCTAssertEqual(
            result.preferredWindow.resetsAt?.timeIntervalSince1970,
            maximumReset
        )
        XCTAssertNil(result.weeklyWindow?.resetsAt)
    }

    func testInvalidResetIsRejectedWithoutPartialSnapshot() {
        let invalid: [JSONValue] = [
            .integer(-1),
            .number(253_402_300_800),
            .number(.infinity),
            .number(-.infinity),
            .string("private")
        ]

        for reset in invalid {
            XCTAssertThrowsError(
                try map(
                    primary: window(duration: 300, used: 20, reset: reset),
                    secondary: window(
                        duration: 10_080,
                        used: 40,
                        reset: nil
                    )
                )
            ) {
                XCTAssertEqual($0 as? CodexUsageError, .invalidResetTimestamp)
            }
        }
    }

    func testPercentagesRoundThenUseCanonicalClamp() throws {
        let values: [(JSONValue, Int)] = [
            (.integer(42), 42),
            (.integer(-7), 0),
            (.integer(Int64.min), 0),
            (.integer(150), 100),
            (.number(48.0), 48),
            (.number(48.4), 48),
            (.number(48.5), 49),
            (.number(48.6), 49),
            (.number(-0.6), 0),
            (.number(100.6), 100)
        ]

        for (value, expected) in values {
            let result = try map(
                primary: window(duration: 300, used: value, reset: nil),
                secondary: .null
            )
            XCTAssertEqual(result.preferredWindow.usedPercent, expected)
        }
    }

    func testFractionalWeeklyPercentageUsesApprovedRounding() throws {
        let result = try map(
            primary: window(duration: 10_080, used: .number(48.5), reset: nil),
            secondary: .null
        )

        XCTAssertEqual(result.preferredWindow.usedPercent, 49)
        XCTAssertEqual(result.weeklyRemainingPercent, 51)
    }

    func testInvalidPercentagesFailWithoutPartialSnapshot() {
        let intUpperBoundExclusive = -Double(Int.min)
        let values: [JSONValue] = [
            .string("42"),
            .bool(true),
            .number(.nan),
            .number(.infinity),
            .number(-.infinity),
            .number(intUpperBoundExclusive),
            .number(Double(Int.min).nextDown),
            .number(.greatestFiniteMagnitude)
        ]

        for value in values {
            XCTAssertThrowsError(
                try map(
                    primary: window(duration: 300, used: value, reset: nil),
                    secondary: .null
                )
            ) {
                XCTAssertEqual($0 as? CodexUsageError, .invalidRateLimitResponse)
            }
        }
    }

    func testSnapshotMetadataAndNonUsageFieldsRemainCanonical() throws {
        let value: JSONValue = .object([
            "rateLimits": .object([
                "primary": .object([
                    "windowDurationMins": .integer(10_080),
                    "usedPercent": .integer(35),
                    "resetsAt": .null,
                    "future": .string("ignored")
                ]),
                "secondary": .null,
                "credits": .object(["balance": .string("not-usage")]),
                "individualLimit": .object(["used": .string("not-spend")])
            ]),
            "future": .array([])
        ])

        let result = try CodexUsageMapper.mapRateLimits(
            value,
            capturedAt: capturedAt
        )

        XCTAssertEqual(result.provider, .codex)
        XCTAssertEqual(result.capturedAt, capturedAt)
        XCTAssertEqual(result.freshness, .fresh)
        XCTAssertFalse(result.isActivelyUsed)
        XCTAssertNil(result.shortWindow)
        XCTAssertEqual(result.weeklyUsedPercent, 35)
        XCTAssertNil(result.weeklySpend)
    }

    private func chatGPTAccount(planType: String) -> JSONValue {
        .object([
            "requiresOpenaiAuth": .bool(true),
            "account": .object([
                "type": .string("chatgpt"),
                "email": .null,
                "planType": .string(planType)
            ])
        ])
    }

    private func account(type: String) -> JSONValue {
        .object([
            "requiresOpenaiAuth": .bool(true),
            "account": .object(["type": .string(type)])
        ])
    }

    private func map(
        primary: JSONValue?,
        secondary: JSONValue?,
        planType: JSONValue? = nil
    ) throws -> UsageSnapshot {
        try CodexUsageMapper.mapRateLimits(
            response(
                fallback: snapshot(
                    primary: primary,
                    secondary: secondary,
                    planType: planType
                )
            ),
            capturedAt: capturedAt
        )
    }

    private func map(
        primary: JSONValue?,
        secondary: JSONValue?,
        planType: String
    ) throws -> UsageSnapshot {
        try map(
            primary: primary,
            secondary: secondary,
            planType: .string(planType)
        )
    }

    private func response(
        fallback: JSONValue,
        buckets: JSONValue? = nil
    ) -> JSONValue {
        var object = ["rateLimits": fallback]
        if let buckets {
            object["rateLimitsByLimitId"] = buckets
        }
        return .object(object)
    }

    private func snapshot(
        primary: JSONValue?,
        secondary: JSONValue?,
        planType: String
    ) -> JSONValue {
        snapshot(
            primary: primary,
            secondary: secondary,
            planType: .string(planType)
        )
    }

    private func snapshot(
        primary: JSONValue?,
        secondary: JSONValue?,
        planType: JSONValue? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let primary {
            object["primary"] = primary
        }
        if let secondary {
            object["secondary"] = secondary
        }
        if let planType {
            object["planType"] = planType
        }
        return .object(object)
    }

    private func window(
        duration: Int64,
        used: Int64,
        reset: Int64
    ) -> JSONValue {
        window(
            duration: .integer(duration),
            used: .integer(used),
            reset: .integer(reset)
        )
    }

    private func window(
        duration: Int64,
        used: Int64,
        reset: JSONValue?
    ) -> JSONValue {
        window(
            duration: .integer(duration),
            used: .integer(used),
            reset: reset
        )
    }

    private func window(
        duration: Int64,
        used: JSONValue,
        reset: JSONValue?
    ) -> JSONValue {
        window(duration: .integer(duration), used: used, reset: reset)
    }

    private func window(
        duration: JSONValue?,
        used: Int64,
        reset: JSONValue?
    ) -> JSONValue {
        window(duration: duration, used: .integer(used), reset: reset)
    }

    private func window(
        duration: JSONValue?,
        used: JSONValue,
        reset: JSONValue?
    ) -> JSONValue {
        var object: [String: JSONValue] = ["usedPercent": used]
        if let duration {
            object["windowDurationMins"] = duration
        }
        if let reset {
            object["resetsAt"] = reset
        }
        return .object(object)
    }
}
