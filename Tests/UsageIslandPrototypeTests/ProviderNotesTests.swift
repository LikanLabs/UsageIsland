import Foundation
import XCTest

@testable import UsageIslandPrototype

/// What the providers report besides usage windows: Codex's saved resets
/// and workspace stops, and the end of the Claude Code sign-in.
final class ProviderNotesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Codex

    func testCodexSavedResetsCarryTheirCountAndEarliestExpiry() throws {
        let snapshot = try CodexUsageMapper.mapRateLimits(codexResponse(extra: [
            "rateLimitResetCredits": .object([
                "availableCount": .integer(3),
                "credits": .array([
                    credit(expiresAt: 1_700_900_000),
                    credit(expiresAt: 1_700_500_000),
                    credit(expiresAt: 1_700_100_000, status: "redeemed"),
                    credit(expiresAt: nil),
                    .string("not a credit"),
                ]),
            ]),
        ]), capturedAt: now)
        XCTAssertEqual(snapshot.savedResets?.count, 3)
        XCTAssertEqual(snapshot.savedResets?.nextExpiry, Date(timeIntervalSince1970: 1_700_500_000),
                       "only credits still available count toward the next expiry")
    }

    func testCodexSavedResetsWithoutDetailsKeepOnlyTheCount() throws {
        let snapshot = try CodexUsageMapper.mapRateLimits(codexResponse(extra: [
            "rateLimitResetCredits": .object(["availableCount": .integer(1), "credits": .null]),
        ]), capturedAt: now)
        XCTAssertEqual(snapshot.savedResets?.count, 1)
        XCTAssertNil(snapshot.savedResets?.nextExpiry)
    }

    func testMissingEmptyOrMalformedSavedResetsNeverHideTheLimits() throws {
        let cases: [JSONValue?] = [
            nil, .null, .string("3"), .array([]),
            .object(["availableCount": .integer(0)]),
            .object(["availableCount": .integer(-2)]),
            .object(["availableCount": .string("3")]),
            .object([:]),
        ]
        for value in cases {
            let snapshot = try CodexUsageMapper.mapRateLimits(
                codexResponse(extra: value.map { ["rateLimitResetCredits": $0] } ?? [:]), capturedAt: now)
            XCTAssertNil(snapshot.savedResets, "\(String(describing: value))")
            XCTAssertEqual(snapshot.windows.map(\.usedPercent), [40, 10])
        }
    }

    func testCodexWorkspaceStopsAreReportedAndOrdinaryLimitsAreNot() throws {
        let cases: [(JSONValue?, UsageBlock?)] = [
            (.string("workspace_owner_credits_depleted"), .workspaceCreditsDepleted),
            (.string("workspace_member_credits_depleted"), .workspaceCreditsDepleted),
            (.string("workspace_owner_usage_limit_reached"), .workspaceLimitReached),
            (.string("workspace_member_usage_limit_reached"), .workspaceLimitReached),
            (.string("rate_limit_reached"), nil),
            (.string("something_new"), nil),
            (.integer(4), nil),
            (.null, nil),
            (nil, nil),
        ]
        for (value, expected) in cases {
            let snapshot = try CodexUsageMapper.mapRateLimits(codexResponse(reached: value), capturedAt: now)
            XCTAssertEqual(snapshot.block, expected, "\(String(describing: value))")
        }
    }

    // MARK: Claude

    func testSignInEndIsReadOnlyFromASignedInAnswerThatHasIt() {
        let end = ClaudeAuthStatusParser.signInExpiry(Data(#"{"loggedIn":true,"loginExpiresAt":"2023-11-17T10:00:00.234Z"}"#.utf8))
        XCTAssertEqual(end, ClaudeUsageResponseParser.date("2023-11-17T10:00:00Z"))
        for answer in [#"{"loggedIn":true}"#, #"{"loggedIn":false,"loginExpiresAt":"2023-11-17T10:00:00Z"}"#,
                       #"{"loggedIn":true,"loginExpiresAt":"soon"}"#, #"{"loggedIn":true,"loginExpiresAt":null}"#, "", "garbage"] {
            XCTAssertNil(ClaudeAuthStatusParser.signInExpiry(Data(answer.utf8)), answer)
        }
    }

    func testClaudeSignInEndIsReadAfterAGoodReadingAndAtMostHourly() async throws {
        let clock = NotesClock(now)
        let query = NotesQuery(status: #"{"loggedIn":true,"loginExpiresAt":"2023-11-16T22:13:20Z"}"#)
        let provider = ClaudeUsageProvider(clock: clock, queryInterval: 300, makeQuery: { query })
        var snapshot = try await provider.fetchUsage()
        XCTAssertEqual(snapshot.signInExpiresAt, ClaudeUsageResponseParser.date("2023-11-16T22:13:20Z"))
        var checks = await query.statusCalls
        XCTAssertEqual(checks, 1)

        clock.advance(301)
        _ = try await provider.fetchUsage()
        checks = await query.statusCalls
        XCTAssertEqual(checks, 1, "not on every reading")

        await query.setStatus(#"{"loggedIn":true,"loginExpiresAt":"2023-12-14T22:13:20Z"}"#)
        clock.advance(3_600)
        snapshot = try await provider.fetchUsage()
        checks = await query.statusCalls
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(snapshot.signInExpiresAt, ClaudeUsageResponseParser.date("2023-12-14T22:13:20Z"), "signing in again moves the date")
    }

    func testClaudeVersionsWithoutASignInEndAreAskedOnlyOnceADay() async throws {
        let clock = NotesClock(now)
        let query = NotesQuery(status: #"{"loggedIn":true,"authMethod":"claude.ai"}"#)
        let provider = ClaudeUsageProvider(clock: clock, queryInterval: 300, makeQuery: { query })
        for _ in 0..<5 {
            let snapshot = try await provider.fetchUsage()
            XCTAssertNil(snapshot.signInExpiresAt)
            clock.advance(3_601)
        }
        var checks = await query.statusCalls
        XCTAssertEqual(checks, 1)
        clock.advance(86_400)
        _ = try await provider.fetchUsage()
        checks = await query.statusCalls
        XCTAssertEqual(checks, 2)
    }

    func testSignInEndIsNeverReadWhenTheReadingFails() async throws {
        let query = NotesQuery(status: #"{"loggedIn":true,"loginExpiresAt":"2023-11-16T22:13:20Z"}"#, usage: Data("garbage".utf8))
        let provider = ClaudeUsageProvider(clock: NotesClock(now), makeQuery: { query })
        _ = try? await provider.fetchUsage()
        let checks = await query.statusCalls
        XCTAssertEqual(checks, 0)
    }

    // MARK: Domain and card

    func testSignInEndIsShownOnlyDuringItsLastThreeDays() throws {
        var snapshot = try plainSnapshot()
        XCTAssertNil(snapshot.signInEnding(at: now))
        snapshot.signInExpiresAt = now.addingTimeInterval(3 * 86_400 + 60)
        XCTAssertNil(snapshot.signInEnding(at: now), "still far away")
        snapshot.signInExpiresAt = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(snapshot.signInEnding(at: now), snapshot.signInExpiresAt)
        snapshot.signInExpiresAt = now
        XCTAssertNil(snapshot.signInEnding(at: now), "an ended sign-in is the sign-in hint's job")
    }

    func testSavedResetsNeedAPositiveCount() {
        XCTAssertNil(SavedResets(count: 0, nextExpiry: nil))
        XCTAssertNil(SavedResets(count: -1, nextExpiry: nil))
        XCTAssertEqual(SavedResets(count: 500, nextExpiry: nil)?.count, 99)
    }

    func testEachNoteAddsOneLineToItsCard() throws {
        var snapshot = try plainSnapshot()
        let plain = CodexEdgeLayout.cardHeight(provider: .codex, snapshot: snapshot, now: now)
        XCTAssertEqual(CodexEdgeLayout.cardNotes(snapshot, now: now), [])

        snapshot.savedResets = SavedResets(count: 3, nextExpiry: nil)
        XCTAssertEqual(CodexEdgeLayout.cardHeight(provider: .codex, snapshot: snapshot, now: now),
                       plain + CodexEdgeLayout.forecastLineHeight)

        snapshot.block = .workspaceCreditsDepleted
        snapshot.signInExpiresAt = now.addingTimeInterval(86_400)
        XCTAssertEqual(CodexEdgeLayout.cardNotes(snapshot, now: now),
                       [.block(.workspaceCreditsDepleted), .signInEnding(now.addingTimeInterval(86_400)),
                        .savedResets(SavedResets(count: 3, nextExpiry: nil)!)],
                       "what stops work comes first")
        XCTAssertEqual(CodexEdgeLayout.cardHeight(provider: .codex, snapshot: snapshot, now: now),
                       plain + 3 * CodexEdgeLayout.forecastLineHeight)
    }

    @MainActor
    func testNotesReadAsSentencesInBothLanguages() throws {
        let english = try makePreferences(.english)
        let spanish = try makePreferences(.spanish)
        let expiry = now.addingTimeInterval(9 * 86_400)
        let day = { (preferences: AppPreferences) in
            expiry.formatted(.dateTime.day().month(.abbreviated).locale(preferences.locale))
        }
        let three = CodexEdgeLayout.CardNote.savedResets(SavedResets(count: 3, nextExpiry: expiry)!)
        XCTAssertEqual(CodexEdgeText.noteText(three, now: now, preferences: english), "3 saved resets · next one expires \(day(english))")
        XCTAssertEqual(CodexEdgeText.noteText(three, now: now, preferences: spanish), "3 reinicios guardados · el próximo vence el \(day(spanish))")
        let one = CodexEdgeLayout.CardNote.savedResets(SavedResets(count: 1, nextExpiry: expiry)!)
        XCTAssertEqual(CodexEdgeText.noteText(one, now: now, preferences: english), "1 saved reset · expires \(day(english))")
        XCTAssertEqual(CodexEdgeText.noteText(one, now: now, preferences: spanish), "1 reinicio guardado · vence el \(day(spanish))")
        // A date that is unknown or already past is left out.
        XCTAssertEqual(CodexEdgeText.noteText(three, now: expiry, preferences: spanish), "3 reinicios guardados")
        let bare = CodexEdgeLayout.CardNote.savedResets(SavedResets(count: 2, nextExpiry: nil)!)
        XCTAssertEqual(CodexEdgeText.noteText(bare, now: now, preferences: english), "2 saved resets")

        let ending = CodexEdgeLayout.CardNote.signInEnding(now.addingTimeInterval(2 * 86_400 + 4 * 3_600))
        XCTAssertEqual(CodexEdgeText.noteText(ending, now: now, preferences: english), "Your sign-in ends in 2d 4h: run claude auth login")
        XCTAssertEqual(CodexEdgeText.noteText(ending, now: now, preferences: spanish), "Tu sesión vence en 2d 4h: ejecuta claude auth login")

        XCTAssertEqual(CodexEdgeText.noteText(.block(.workspaceCreditsDepleted), now: now, preferences: spanish),
                       "Tu espacio de trabajo se quedó sin créditos")
        XCTAssertEqual(CodexEdgeText.noteText(.block(.workspaceLimitReached), now: now, preferences: english),
                       "Your workspace reached its usage limit")
    }

    // MARK: Fixtures

    private func plainSnapshot() throws -> UsageSnapshot {
        try CodexUsageMapper.mapRateLimits(codexResponse(), capturedAt: now)
    }

    private func codexResponse(reached: JSONValue? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var limits: [String: JSONValue] = [
            "primary": .object(["usedPercent": .integer(40), "windowDurationMins": .integer(300), "resetsAt": .integer(1_700_010_000)]),
            "secondary": .object(["usedPercent": .integer(10), "windowDurationMins": .integer(10_080), "resetsAt": .integer(1_700_500_000)]),
        ]
        if let reached { limits["rateLimitReachedType"] = reached }
        var object: [String: JSONValue] = ["rateLimits": .object(limits), "rateLimitsByLimitId": .object(["codex": .object(limits)])]
        object.merge(extra) { _, new in new }
        return .object(object)
    }

    private func credit(expiresAt: Int64?, status: String = "available") -> JSONValue {
        .object([
            "id": .string("synthetic"), "resetType": .string("codexRateLimits"), "status": .string(status),
            "grantedAt": .integer(1_699_000_000), "expiresAt": expiresAt.map(JSONValue.integer) ?? .null,
            "title": .string("Full reset"),
        ])
    }

    @MainActor
    private func makePreferences(_ language: AppLanguage) throws -> AppPreferences {
        let preferences = AppPreferences(defaults: TestDefaults.make())
        preferences.language = language
        return preferences
    }
}

private final class NotesClock: UsageClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private actor NotesQuery: ClaudeUsageQuerying {
    private var status: Data
    private let usage: Data
    private(set) var statusCalls = 0

    init(status: String, usage: Data? = nil) {
        self.status = Data(status.utf8)
        self.usage = usage ?? Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"usage-island","response":{"rate_limits_available":true,"rate_limits":{"limits":[{"kind":"session","percent":12,"resets_at":"2023-11-14T23:13:20+00:00","scope":null}]}}}}"#.utf8)
    }

    func setStatus(_ status: String) { self.status = Data(status.utf8) }
    func queryUsage() async throws -> Data { usage }
    func authStatus() async throws -> Data {
        statusCalls += 1
        return status
    }
}
