import Foundation
import XCTest

@testable import UsageIslandPrototype

final class CodexUsageMapperTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_234)
    private let shortReset = 253_402_300_799.0

    func testValidChatGPTAccountAcceptsNullableEmailAndAdditionalFields() throws {
        try CodexUsageMapper.validateAccount(
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
            (
                account(type: "apiKey"),
                .unsupportedAccountMode(.apiKey)
            ),
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
                    "planType": .string("private-plan")
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

    func testCodexBucketIsPreferredWithoutMixingFallbackWindows() throws {
        let value = response(
            fallback: snapshot(
                primary: window(duration: 300, used: 91, reset: 1_000),
                secondary: window(duration: 10_080, used: 92, reset: 2_000)
            ),
            buckets: .object([
                "codex": snapshot(
                    primary: window(duration: 300, used: 21, reset: 3_000),
                    secondary: .null
                ),
                "unknown": .string("ignored")
            ])
        )

        let result = try CodexUsageMapper.mapRateLimits(
            value,
            capturedAt: capturedAt
        )

        XCTAssertEqual(result.shortWindow.usedPercent, 21)
        XCTAssertEqual(result.weeklyUsedPercent, nil)
        XCTAssertEqual(result.shortWindow.resetsAt.timeIntervalSince1970, 3_000)
    }

    func testFallbackIsUsedOnlyWhenCodexKeyIsAbsent() throws {
        let fallback = snapshot(
            primary: window(duration: 300, used: 32, reset: 4_000),
            secondary: window(duration: 10_080, used: 44, reset: .null)
        )

        for buckets in [nil, JSONValue.null, .object(["other": .null])] {
            let result = try CodexUsageMapper.mapRateLimits(
                response(fallback: fallback, buckets: buckets),
                capturedAt: capturedAt
            )
            XCTAssertEqual(result.shortWindow.usedPercent, 32)
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
                    primary: .object([
                        "windowDurationMins": .integer(300),
                        "usedPercent": .string("private")
                    ]),
                    secondary: .null
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

    func testInvalidTopLevelBucketMapAndUnavailableFallbackAreTyped() {
        XCTAssertThrowsError(
            try CodexUsageMapper.mapRateLimits(
                .object([
                    "rateLimits": validShortSnapshot(),
                    "rateLimitsByLimitId": .string("malformed")
                ]),
                capturedAt: capturedAt
            )
        ) {
            XCTAssertEqual($0 as? CodexUsageError, .invalidRateLimitResponse)
        }

        XCTAssertThrowsError(
            try CodexUsageMapper.mapRateLimits(
                .object(["rateLimitsByLimitId": .object([:])]),
                capturedAt: capturedAt
            )
        ) {
            XCTAssertEqual($0 as? CodexUsageError, .rateLimitsUnavailable)
        }
    }

    func testWindowsAreClassifiedByDurationInEitherPosition() throws {
        let normal = try map(
            primary: window(duration: 300, used: 25, reset: 5_000),
            secondary: window(duration: 10_080, used: 75, reset: 6_000)
        )
        let inverted = try map(
            primary: window(duration: 10_080, used: 75, reset: 6_000),
            secondary: window(duration: 300, used: 25, reset: 5_000)
        )

        XCTAssertEqual(normal, inverted)
        XCTAssertEqual(normal.shortWindow.usedPercent, 25)
        XCTAssertEqual(normal.weeklyUsedPercent, 75)
    }

    func testOptionalOrUnknownWindowsDoNotPreventShortSnapshot() throws {
        let cases: [(JSONValue?, JSONValue?)] = [
            (window(duration: 300, used: 30, reset: 5_000), nil),
            (.null, window(duration: 300, used: 30, reset: 5_000)),
            (
                window(duration: 999, used: 88, reset: .null),
                window(duration: 300, used: 30, reset: 5_000)
            )
        ]

        for (primary, secondary) in cases {
            let result = try map(primary: primary, secondary: secondary)
            XCTAssertEqual(result.shortWindow.usedPercent, 30)
            XCTAssertNil(result.weeklyUsedPercent)
        }
    }

    func testMissingShortAndDuplicateRecognizedWindowsAreRejected() {
        XCTAssertThrowsError(
            try map(
                primary: window(duration: 10_080, used: 20, reset: .null),
                secondary: .null
            )
        ) {
            XCTAssertEqual($0 as? CodexUsageError, .missingShortWindow)
        }

        let duplicateCases: [(Int64, CodexWindowKind)] = [
            (300, .short),
            (10_080, .weekly)
        ]
        for (duration, kind) in duplicateCases {
            XCTAssertThrowsError(
                try map(
                    primary: window(duration: duration, used: 10, reset: 10),
                    secondary: window(duration: duration, used: 20, reset: 20)
                )
            ) {
                XCTAssertEqual(
                    $0 as? CodexUsageError,
                    .duplicateRecognizedWindow(kind)
                )
            }
        }
    }

    func testPercentagesRoundThenUseCanonicalClampWithoutInt32Restriction() throws {
        let values: [(JSONValue, Int)] = [
            (.integer(42), 42),
            (.integer(-7), 0),
            (.integer(Int64.min), 0),
            (.integer(150), 100),
            (.integer(Int64(Int32.max) + 1), 100),
            (.number(48.0), 48),
            (.number(48.4), 48),
            (.number(48.5), 49),
            (.number(48.6), 49),
            (.number(-0.6), 0),
            (.number(100.6), 100)
        ]

        for (value, expected) in values {
            let result = try map(
                primary: window(duration: 300, used: value, reset: 1_000),
                secondary: .null
            )
            XCTAssertEqual(result.shortWindow.usedPercent, expected)
        }
    }

    func testFractionalWeeklyAndRemainingPercentagesUseRoundedValues() throws {
        let result = try map(
            primary: window(
                duration: 300,
                used: .number(48.5),
                reset: 1_000
            ),
            secondary: window(
                duration: 10_080,
                used: .number(48.4),
                reset: .null
            )
        )

        XCTAssertEqual(result.shortWindow.usedPercent, 49)
        XCTAssertEqual(result.shortWindow.remainingPercent, 51)
        XCTAssertEqual(result.weeklyUsedPercent, 48)
        XCTAssertEqual(result.weeklyRemainingPercent, 52)
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
            .number(.greatestFiniteMagnitude),
            .integer(Int64.max)
        ]

        for value in values {
            XCTAssertThrowsError(
                try map(
                    primary: window(duration: 300, used: value, reset: 1_000),
                    secondary: .null
                )
            ) {
                XCTAssertEqual($0 as? CodexUsageError, .invalidRateLimitResponse)
            }
        }
    }

    func testShortResetValidationAndAbsoluteDate() throws {
        let valid = try map(
            primary: window(
                duration: 300,
                used: 20,
                reset: .number(shortReset)
            ),
            secondary: .null
        )
        XCTAssertEqual(
            valid.shortWindow.resetsAt.timeIntervalSince1970,
            shortReset
        )

        let invalid: [JSONValue?] = [
            nil,
            .null,
            .integer(-1),
            .number(253_402_300_800),
            .number(.infinity),
            .string("private")
        ]
        for reset in invalid {
            XCTAssertThrowsError(
                try map(
                    primary: window(duration: 300, used: 20, reset: reset),
                    secondary: .null
                )
            ) {
                XCTAssertEqual(
                    $0 as? CodexUsageError,
                    .invalidResetTimestamp(.short)
                )
            }
        }
    }

    func testWeeklyResetMayBeNullButInvalidNumericResetIsRejected() throws {
        let valid = try map(
            primary: window(duration: 300, used: 20, reset: 1_000),
            secondary: window(duration: 10_080, used: 60, reset: .null)
        )
        XCTAssertEqual(valid.weeklyUsedPercent, 60)

        for reset in [JSONValue.number(-1), .string("invalid")] {
            XCTAssertThrowsError(
                try map(
                    primary: window(duration: 300, used: 20, reset: 1_000),
                    secondary: window(
                        duration: 10_080,
                        used: 60,
                        reset: reset
                    )
                )
            ) {
                XCTAssertEqual(
                    $0 as? CodexUsageError,
                    .invalidResetTimestamp(.weekly)
                )
            }
        }
    }

    func testSnapshotMetadataAndFutureFieldsAreCanonical() throws {
        let value: JSONValue = .object([
            "rateLimits": .object([
                "primary": .object([
                    "windowDurationMins": .integer(300),
                    "usedPercent": .integer(35),
                    "resetsAt": .integer(7_000),
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
        XCTAssertNil(result.weeklyUsedPercent)
        XCTAssertNil(result.weeklySpend)
    }

    private func account(type: String) -> JSONValue {
        .object([
            "requiresOpenaiAuth": .bool(true),
            "account": .object(["type": .string(type)])
        ])
    }

    private func map(
        primary: JSONValue?,
        secondary: JSONValue?
    ) throws -> UsageSnapshot {
        try CodexUsageMapper.mapRateLimits(
            response(fallback: snapshot(primary: primary, secondary: secondary)),
            capturedAt: capturedAt
        )
    }

    private func validShortSnapshot() -> JSONValue {
        snapshot(
            primary: window(duration: 300, used: 20, reset: 1_000),
            secondary: .null
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
        secondary: JSONValue?
    ) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let primary {
            object["primary"] = primary
        }
        if let secondary {
            object["secondary"] = secondary
        }
        return .object(object)
    }

    private func window(
        duration: Int64,
        used: Int64,
        reset: Int64
    ) -> JSONValue {
        window(duration: duration, used: .integer(used), reset: .integer(reset))
    }

    private func window(
        duration: Int64,
        used: Int64,
        reset: JSONValue?
    ) -> JSONValue {
        window(duration: duration, used: .integer(used), reset: reset)
    }

    private func window(
        duration: Int64,
        used: JSONValue,
        reset: Int64
    ) -> JSONValue {
        window(duration: duration, used: used, reset: .integer(reset))
    }

    private func window(
        duration: Int64,
        used: JSONValue,
        reset: JSONValue?
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "windowDurationMins": .integer(duration),
            "usedPercent": used
        ]
        if let reset {
            object["resetsAt"] = reset
        }
        return .object(object)
    }
}
