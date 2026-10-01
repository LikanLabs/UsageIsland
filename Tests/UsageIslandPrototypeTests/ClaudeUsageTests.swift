import Foundation
import XCTest
@testable import UsageIslandPrototype

@MainActor
final class ActiveProviderTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_700_000_000)

    func testPillStartsWithMostCriticalProviderAndIgnoresActivityBeforeLaunch() async throws {
        let clock = SteppingClaudeClock(launch)
        let codex = ScriptedUsageProvider(id: .codex)
        let claude = ScriptedUsageProvider(id: .claude)
        await codex.set(try snapshot(.codex, used: 20, at: launch))
        var oldClaude = try snapshot(.claude, used: 80, at: launch.addingTimeInterval(-3_600))
        oldClaude.lastActivityAt = launch.addingTimeInterval(-3_600)
        await claude.set(oldClaude)
        let model = try AppModel(providerAdapters: [codex, claude], clock: clock, initialSnapshots: [])

        await model.refreshUsage()
        XCTAssertEqual(model.displayedProviderID, .claude, "most critical wins without recent activity")

        await claude.set(try snapshot(.claude, used: 10, at: launch.addingTimeInterval(-3_000)))
        await model.refreshUsage()
        XCTAssertEqual(model.displayedProviderID, .claude, "keeps previous choice without activity")
    }

    func testPillFollowsTheProviderInUse() async throws {
        let clock = SteppingClaudeClock(launch)
        let codex = ScriptedUsageProvider(id: .codex)
        let claude = ScriptedUsageProvider(id: .claude)
        await codex.set(try snapshot(.codex, used: 20, at: launch))
        await claude.set(try snapshot(.claude, used: 90, at: launch))
        let model = try AppModel(providerAdapters: [codex, claude], clock: clock, initialSnapshots: [])
        await model.refreshUsage()
        XCTAssertEqual(model.displayedProviderID, .claude)

        // Codex usage rises: the user is working in Codex now.
        clock.advance(60)
        await codex.set(try snapshot(.codex, used: 21, at: clock.now()))
        await model.refreshUsage()
        XCTAssertEqual(model.displayedProviderID, .codex)

        // Claude Code reports a reply after that.
        clock.advance(30)
        var active = try snapshot(.claude, used: 90, at: clock.now())
        active.lastActivityAt = clock.now()
        await claude.set(active)
        await model.refreshUsage(for: .claude)
        XCTAssertEqual(model.displayedProviderID, .claude)
        XCTAssertEqual(model.displayedSnapshot?.id, .claude)

        // An unchanged Codex reading is not activity.
        clock.advance(60)
        await codex.set(try snapshot(.codex, used: 21, at: clock.now()))
        await model.refreshUsage()
        XCTAssertEqual(model.displayedProviderID, .claude)
    }

    func testOlderReadingNeverReplacesNewerOne() async throws {
        let clock = SteppingClaudeClock(launch)
        let claude = ScriptedUsageProvider(id: .claude)
        await claude.set(try snapshot(.claude, used: 40, at: launch.addingTimeInterval(10)))
        let model = try AppModel(providerAdapters: [claude], clock: clock, initialSnapshots: [])
        await model.refreshUsage(for: .claude)

        await claude.set(try snapshot(.claude, used: 30, at: launch))
        await model.refreshUsage()
        XCTAssertEqual(model.snapshot(for: .claude)?.preferredWindow.usedPercent, 40)
    }

    func testClearingProviderFallsBackToRemainingOne() async throws {
        let clock = SteppingClaudeClock(launch)
        let codex = ScriptedUsageProvider(id: .codex)
        let claude = ScriptedUsageProvider(id: .claude)
        await codex.set(try snapshot(.codex, used: 20, at: launch))
        await claude.set(try snapshot(.claude, used: 90, at: launch))
        let model = try AppModel(providerAdapters: [codex, claude], clock: clock, initialSnapshots: [])
        await model.refreshUsage()

        model.clearUsage(for: .claude)
        XCTAssertNil(model.snapshot(for: .claude))
        XCTAssertEqual(model.displayedProviderID, .codex)
        XCTAssertEqual(model.connectionStates[.claude], .disconnected)
    }

    private func snapshot(_ id: ProviderID, used: Int, at date: Date) throws -> UsageSnapshot {
        try UsageSnapshot(
            provider: id,
            preferredWindow: UsageWindow(durationMinutes: 300, usedPercent: used, resetsAt: date.addingTimeInterval(3_600)),
            additionalWindows: [],
            weeklySpend: nil,
            freshness: .fresh,
            isActivelyUsed: false,
            capturedAt: date
        )
    }
}

private actor ScriptedUsageProvider: UsageProvider {
    nonisolated let id: ProviderID
    private var next: UsageSnapshot?

    init(id: ProviderID) { self.id = id }

    func set(_ snapshot: UsageSnapshot) { next = snapshot }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let next else { throw ClaudeUsageError.notConnected }
        return next
    }
}

private struct FixedClaudeClock: UsageClock {
    let value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { value }
}

private final class SteppingClaudeClock: UsageClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-island-claude-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readJSON(_ url: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func assertThrows<E: Error & Equatable>(
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? E, expected, file: file, line: line)
    }
}

/// Synthetic `get_usage` stream-json output, mirroring the CLI's shape.
private func usageOutput(five: Double, week: Double, requestID: String = "usage-island") -> Data {
    Data("""
    {"type":"system","subtype":"init"}
    {"type":"control_response","response":{"subtype":"success","request_id":"\(requestID)","response":{"session":{"total_cost_usd":0},"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":\(five),"resets_at":"2023-11-14T23:13:20.141375+00:00"},"seven_day":{"utilization":\(week),"resets_at":"2023-11-20T11:46:40+00:00"},"seven_day_opus":null,"limits":[]},"behaviors":null}}}

    """.utf8)
}

/// Synthetic rows in the CLI's `limits` shape, with an unknown kind and a
/// malformed row that must be skipped.
private let scopedUsageOutput = Data("""
{"type":"control_response","response":{"subtype":"success","request_id":"usage-island","response":{"rate_limits_available":true,"rate_limits":{"five_hour":null,"seven_day":null,"limits":[{"kind":"session","group":"session","percent":12,"resets_at":"2023-11-14T23:13:20+00:00","scope":null},{"kind":"weekly_all","group":"weekly","percent":5,"resets_at":"2023-11-20T11:46:40+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":40,"resets_at":"2023-11-20T11:46:40+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},{"kind":"future_kind","percent":3},{"kind":42}]}}}}
""".utf8)

final class ClaudeUsageResponseParserTests: XCTestCase {
    func testParsesLegacyWindowsWhenLimitRowsAreAbsent() throws {
        let limits = try ClaudeUsageResponseParser.limits(from: usageOutput(five: 27, week: 4.5))
        XCTAssertEqual(limits.windows.map(\.durationMinutes), [300, 10_080])
        XCTAssertEqual(limits.windows[0].usedPercentage, 27)
        XCTAssertEqual(limits.windows[0].resetsAt?.timeIntervalSince1970 ?? 0, 1_700_003_600.141, accuracy: 0.01)
        XCTAssertEqual(limits.windows[1].usedPercentage, 4.5)
        XCTAssertEqual(limits.windows[1].resetsAt, Date(timeIntervalSince1970: 1_700_480_800))
        XCTAssertEqual(limits.windows.map(\.scope), [nil, nil])
    }

    func testOrderedLimitRowsIncludePerModelWeeklyLimits() throws {
        let limits = try ClaudeUsageResponseParser.limits(from: scopedUsageOutput)
        XCTAssertEqual(limits.windows.map(\.durationMinutes), [300, 10_080, 10_080])
        XCTAssertEqual(limits.windows.map(\.scope), [nil, nil, "Fable"])
        XCTAssertEqual(limits.windows.map(\.usedPercentage), [12, 5, 40])
        XCTAssertNotNil(limits.windows[2].resetsAt)
    }

    func testScopedLimitBecomesItsOwnWindow() async throws {
        let query = ScriptedUsageQuery(output: scopedUsageOutput)
        let provider = ClaudeUsageProvider(
            clock: FixedClaudeClock(Date(timeIntervalSince1970: 1_700_000_000)),
            makeQuery: { query }
        )
        let snapshot = try await provider.fetchUsage()
        XCTAssertEqual(snapshot.preferredWindow.durationMinutes, 300)
        XCTAssertEqual(snapshot.windows.map(\.id), ["300|", "10080|", "10080|Fable"])
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 5, "plan-wide week, not the model one")
    }

    func testRejectsMissingForeignAndUnavailableResponses() {
        XCTAssertThrowsError(try ClaudeUsageResponseParser.limits(from: Data())) {
            XCTAssertEqual($0 as? ClaudeUsageResponseParser.Failure, .noResponse)
        }
        XCTAssertThrowsError(try ClaudeUsageResponseParser.limits(from: usageOutput(five: 1, week: 1, requestID: "other"))) {
            XCTAssertEqual($0 as? ClaudeUsageResponseParser.Failure, .noResponse)
        }
        let apiKey = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"usage-island","response":{"rate_limits_available":false,"rate_limits":null}}}"#.utf8)
        XCTAssertThrowsError(try ClaudeUsageResponseParser.limits(from: apiKey)) {
            XCTAssertEqual($0 as? ClaudeUsageResponseParser.Failure, .limitsUnavailable)
        }
        let failed = Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"usage-island","error":"x"}}"#.utf8)
        XCTAssertThrowsError(try ClaudeUsageResponseParser.limits(from: failed)) {
            XCTAssertEqual($0 as? ClaudeUsageResponseParser.Failure, .requestFailed)
        }
    }

    func testCommandIsolatesTheCLIFromTheUsersSetup() {
        let arguments = ClaudeUsageCommand.arguments
        for flag in ["-p", "--restricted", "--strict-mcp-config", "--no-session-persistence"] {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "")
    }
}

final class ClaudeCLIProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testCLIAnswerBecomesTheSnapshot() async throws {
        let query = ScriptedUsageQuery(output: usageOutput(five: 27, week: 4))
        let provider = ClaudeUsageProvider(clock: FixedClaudeClock(now), makeQuery: { query })
        let snapshot = try await provider.fetchUsage()
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [27, 4])
        XCTAssertEqual(snapshot.freshness, .fresh)
        XCTAssertNil(snapshot.lastActivityAt, "activity comes from rising usage, as with Codex")
        let calls = await query.calls
        XCTAssertEqual(calls, 1)
    }

    func testCLIIsQueriedAtMostOncePerInterval() async throws {
        let clock = SteppingClaudeClock(now)
        let query = ScriptedUsageQuery(output: usageOutput(five: 27, week: 4))
        let provider = ClaudeUsageProvider(clock: clock, queryInterval: 120, makeQuery: { query })
        _ = try await provider.fetchUsage()
        clock.advance(60)
        _ = try await provider.fetchUsage()
        var calls = await query.calls
        XCTAssertEqual(calls, 1)
        clock.advance(61)
        _ = try await provider.fetchUsage()
        calls = await query.calls
        XCTAssertEqual(calls, 2)
    }

    func testOldAnswerTurnsStaleAndFailuresKeepTheLastReading() async throws {
        let clock = SteppingClaudeClock(now)
        let query = ScriptedUsageQuery(output: usageOutput(five: 27, week: 4))
        let provider = ClaudeUsageProvider(clock: clock, freshnessInterval: 900, queryInterval: 120, makeQuery: { query })
        _ = try await provider.fetchUsage()

        await query.set(Data("garbage".utf8))
        clock.advance(901)
        let snapshot = try await provider.fetchUsage()
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [27, 4], "last valid answer is kept")
        XCTAssertEqual(snapshot.freshness, .stale)
    }

    func testMissingCLIOrBadAnswerExplainsWhy() async throws {
        let missing = ClaudeUsageProvider(clock: FixedClaudeClock(now))
        await assertThrows(ClaudeUsageError.cliNotFound) { _ = try await missing.fetchUsage() }

        let query = ScriptedUsageQuery(output: Data("garbage".utf8))
        let broken = ClaudeUsageProvider(clock: FixedClaudeClock(now), makeQuery: { query })
        await assertThrows(ClaudeUsageError.queryFailed) { _ = try await broken.fetchUsage() }
    }
}

final class ClaudeLegacyBridgeCleanupTests: XCTestCase {
    private let path = "/Applications/Usage Island.app/Contents/MacOS/UsageIslandPrototype"

    func testRemovesOnlyOurStatusLineInBothOldFormatsAndItsRecord() throws {
        for command in ["'\(path)' --claude-statusline",
                        "[ -x '\(path)' ] && exec '\(path)' --claude-statusline || true"] {
            let directory = try temporaryDirectory()
            let file = ClaudeSettingsFile(claudeDirectory: directory)
            let settings: [String: Any] = ["model": "opus", "statusLine": ["type": "command", "command": command, "padding": 0]]
            try JSONSerialization.data(withJSONObject: settings).write(to: file.settingsURL)
            let recordDirectory = try temporaryDirectory()
            let record = recordDirectory.appendingPathComponent("claude-rate-limits.json")
            try Data("{}".utf8).write(to: record)

            XCTAssertTrue(ClaudeLegacyBridge.removeIfInstalled(settings: file, recordURL: record))

            let updated = try readJSON(file.settingsURL)
            XCTAssertNil(updated["statusLine"])
            XCTAssertEqual(updated["model"] as? String, "opus")
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: recordDirectory.path), "empty folder removed")
        }
    }

    func testNeverTouchesAUsersOwnStatusLineOrUnreadableSettings() throws {
        for original in [#"{"statusLine":{"type":"command","command":"~/bin/my-status"}}"#,
                         #"{"statusLine":{"type":"command","command":"'/usr/bin/other' --claude-statusline"}}"#,
                         "{ not json"] {
            let directory = try temporaryDirectory()
            let file = ClaudeSettingsFile(claudeDirectory: directory)
            try Data(original.utf8).write(to: file.settingsURL)
            XCTAssertFalse(ClaudeLegacyBridge.removeIfInstalled(settings: file, recordURL: directory.appendingPathComponent("none.json")))
            XCTAssertEqual(try String(contentsOf: file.settingsURL, encoding: .utf8), original)
        }
    }

    func testMissingClaudeSetupIsANoOp() throws {
        let directory = try temporaryDirectory().appendingPathComponent(".claude")
        XCTAssertFalse(ClaudeLegacyBridge.removeIfInstalled(settings: ClaudeSettingsFile(claudeDirectory: directory),
                                                            recordURL: directory.appendingPathComponent("none.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTamperedCommandsAreNotOurs() {
        XCTAssertNil(ClaudeSettingsFile.executablePath(inCommand: "[ -x '/a/UsageIslandPrototype' ] && exec '/b/UsageIslandPrototype' --claude-statusline || true"))
        XCTAssertNil(ClaudeSettingsFile.executablePath(inCommand: "'/a/UsageIslandPrototype'; rm -rf x' --claude-statusline"))
        XCTAssertEqual(ClaudeSettingsFile.executablePath(inCommand: "'/Users/o'\\''neil/UsageIslandPrototype' --claude-statusline"),
                       "/Users/o'neil/UsageIslandPrototype")
    }
}

@MainActor
final class ClaudeDesktopActivityTests: XCTestCase {
    func testRisingClaudeUsageFromTheCLISwitchesThePill() async throws {
        let launch = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SteppingClaudeClock(launch)
        let query = ScriptedUsageQuery(output: usageOutput(five: 10, week: 5))
        let claude = ClaudeUsageProvider(clock: clock, queryInterval: 0, makeQuery: { query })
        let codex = ScriptedUsageProvider(id: .codex)
        await codex.set(try UsageSnapshot(
            provider: .codex,
            preferredWindow: UsageWindow(durationMinutes: 300, usedPercent: 50, resetsAt: nil),
            additionalWindows: [], weeklySpend: nil, freshness: .fresh, isActivelyUsed: false, capturedAt: launch
        ))
        let model = try AppModel(providerAdapters: [codex, claude], clock: clock, initialSnapshots: [])
        await model.refreshUsage()
        XCTAssertEqual(model.displayedProviderID, .codex)

        clock.advance(120)
        await query.set(usageOutput(five: 12, week: 5))
        await model.refreshUsage()
        XCTAssertEqual(model.displayedProviderID, .claude, "Claude desktop use shows up as rising CLI usage")
    }
}

private actor ScriptedUsageQuery: ClaudeUsageQuerying {
    private var output: Data
    private(set) var calls = 0
    init(output: Data) { self.output = output }
    func set(_ output: Data) { self.output = output }
    func queryUsage() async throws -> Data {
        calls += 1
        return output
    }
}

final class ProviderIssueTests: XCTestCase {
    func testClaudeReportsWhyThereIsNoReading() async throws {
        let apiKey = ScriptedUsageQuery(output: Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"usage-island","response":{"rate_limits_available":false,"rate_limits":null}}}"#.utf8))
        let provider = ClaudeUsageProvider(
            clock: FixedClaudeClock(Date(timeIntervalSince1970: 1_700_000_000)),
            makeQuery: { apiKey }
        )
        await assertThrows(ClaudeUsageError.noPlanLimits) { _ = try await provider.fetchUsage() }
        XCTAssertEqual(ClaudeUsageError.noPlanLimits.issue, .noPlanLimits)
        XCTAssertEqual(ClaudeUsageError.cliNotFound.issue, .notInstalled)
        XCTAssertEqual(ClaudeUsageError.queryFailed.issue, .notSignedIn)
    }

    func testCodexErrorsMapToIssues() {
        XCTAssertEqual(CodexUsageError.notAuthenticated.issue, .notSignedIn)
        XCTAssertEqual(CodexUsageError.unsupportedAccountMode(.apiKey).issue, .noPlanLimits)
        XCTAssertEqual(CodexUsageError.unsupportedAccountMode(.amazonBedrock).issue, .noPlanLimits)
        XCTAssertEqual(CodexUsageError.rateLimitsUnavailable.issue, .noPlanLimits)
        XCTAssertEqual(CodexUsageError.appServerFailure(.executableUnavailable).issue, .notInstalled)
        XCTAssertEqual(CodexUsageError.appServerFailure(.timeout).issue, .unavailable)
    }

    @MainActor
    func testModelPublishesIssuesAndClearsThemOnSuccess() async throws {
        let codex = ScriptedUsageProvider(id: .codex)
        let model = try AppModel(providerAdapters: [codex], clock: FixedClaudeClock(Date(timeIntervalSince1970: 1_700_000_000)), initialSnapshots: [])
        await model.refreshUsage()
        XCTAssertEqual(model.issues[.codex], .unavailable)

        await codex.set(try UsageSnapshot(
            provider: .codex,
            preferredWindow: UsageWindow(durationMinutes: 10_080, usedPercent: 3, resetsAt: nil),
            additionalWindows: [], weeklySpend: nil, freshness: .fresh, isActivelyUsed: false,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        await model.refreshUsage()
        XCTAssertNil(model.issues[.codex])
    }
}
