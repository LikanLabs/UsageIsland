import Foundation
import XCTest
@testable import UsageIslandPrototype

/// Synthetic Claude Code status line input: the documented shape, with
/// unrelated fields that must never be stored.
private let statusLineInput = Data("""
{
  "session_id": "synthetic-session",
  "cwd": "/Users/example/project",
  "model": { "id": "claude-synthetic", "display_name": "Synthetic" },
  "cost": { "total_cost_usd": 1.23 },
  "rate_limits": {
    "five_hour": { "used_percentage": 32.4, "resets_at": 1700003600 },
    "seven_day": { "used_percentage": 57.6, "resets_at": 1700500000 }
  }
}
""".utf8)

final class ClaudeStatuslineBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBridgeStoresOnlyRateLimitsAndPrintsShortStatus() throws {
        let url = try temporaryDirectory().appendingPathComponent("record.json")
        let text = ClaudeStatuslineBridge.run(input: statusLineInput, recordURL: url, now: now)

        XCTAssertEqual(text, "5h 32% · 7d 58%")
        let stored = try String(contentsOf: url, encoding: .utf8)
        for private_ in ["synthetic-session", "/Users/example", "claude-synthetic", "total_cost"] {
            XCTAssertFalse(stored.contains(private_), private_)
        }
        let record = try JSONDecoder().decode(ClaudeRateLimitRecord.self, from: Data(stored.utf8))
        XCTAssertEqual(record.capturedAt, now.timeIntervalSince1970)
        XCTAssertEqual(record.fiveHour, .init(usedPercentage: 32.4, resetsAt: 1_700_003_600))
        XCTAssertEqual(record.sevenDay, .init(usedPercentage: 57.6, resetsAt: 1_700_500_000))
    }

    func testInputWithoutRateLimitsKeepsPreviousRecord() throws {
        let url = try temporaryDirectory().appendingPathComponent("record.json")
        ClaudeStatuslineBridge.run(input: statusLineInput, recordURL: url, now: now)
        let before = try Data(contentsOf: url)

        for input in [#"{"session_id":"x"}"#, #"{"rate_limits":{}}"#, "not json", ""] {
            XCTAssertEqual(ClaudeStatuslineBridge.run(input: Data(input.utf8), recordURL: url, now: now.addingTimeInterval(60)), "")
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testPartialLimitsKeepAvailableWindow() {
        let input = Data(#"{"rate_limits":{"seven_day":{"used_percentage":99.6,"resets_at":1700500000}}}"#.utf8)
        let record = ClaudeStatuslineBridge.record(from: input, now: now)
        XCTAssertNil(record?.fiveHour)
        XCTAssertEqual(record.map(ClaudeStatuslineBridge.statusText), "7d 99%")
    }
}

final class ClaudeUsageProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testRecordMapsToSessionAndWeeklyWindows() throws {
        let record = ClaudeRateLimitRecord(
            version: 1, capturedAt: now.timeIntervalSince1970,
            fiveHour: .init(usedPercentage: 32.4, resetsAt: 1_700_003_600),
            sevenDay: .init(usedPercentage: 99.5, resetsAt: 1_700_500_000)
        )
        let snapshot = try ClaudeUsageProvider.snapshot(from: record, now: now, freshnessInterval: 900)

        XCTAssertEqual(snapshot.id, .claude)
        XCTAssertEqual(snapshot.preferredWindow.durationMinutes, 300)
        XCTAssertEqual(snapshot.preferredWindow.usedPercent, 32)
        XCTAssertEqual(snapshot.preferredWindow.resetsAt, Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertEqual(snapshot.weeklyUsedPercent, 99)
        XCTAssertEqual(snapshot.freshness, .fresh)
        XCTAssertEqual(snapshot.lastActivityAt, now)
        XCTAssertEqual(snapshot.capturedAt, now)
    }

    func testOldRecordIsStale() throws {
        let record = ClaudeRateLimitRecord(
            version: 1, capturedAt: now.timeIntervalSince1970 - 901,
            fiveHour: .init(usedPercentage: 10, resetsAt: 1_700_003_600), sevenDay: nil
        )
        let snapshot = try ClaudeUsageProvider.snapshot(from: record, now: now, freshnessInterval: 900)
        XCTAssertEqual(snapshot.freshness, .stale)
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    func testMissingOrInvalidRecordsFailWithoutInventingUsage() async throws {
        let directory = try temporaryDirectory()
        let missing = ClaudeUsageProvider(recordURL: directory.appendingPathComponent("none.json"), clock: FixedClaudeClock(now))
        await assertThrows(ClaudeUsageError.notConnected) { try await missing.fetchUsage() }

        let bad = directory.appendingPathComponent("bad.json")
        try Data(#"{"version":2,"capturedAt":1,"fiveHour":null,"sevenDay":null}"#.utf8).write(to: bad)
        let invalid = ClaudeUsageProvider(recordURL: bad, clock: FixedClaudeClock(now))
        await assertThrows(ClaudeUsageError.invalidRecord) { try await invalid.fetchUsage() }
    }

    func testBridgeOutputIsReadByProvider() async throws {
        let url = try temporaryDirectory().appendingPathComponent("record.json")
        ClaudeStatuslineBridge.run(input: statusLineInput, recordURL: url, now: now)
        let snapshot = try await ClaudeUsageProvider(recordURL: url, clock: FixedClaudeClock(now)).fetchUsage()
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [32, 58])
    }
}

final class ClaudeSettingsInstallerTests: XCTestCase {
    private let executable = "/Applications/Usage Island.app/Contents/MacOS/UsageIslandPrototype"

    func testMissingClaudeDirectoryIsReportedAndNeverCreated() throws {
        let directory = try temporaryDirectory().appendingPathComponent(".claude")
        let installer = ClaudeSettingsInstaller(claudeDirectory: directory, executablePath: executable)
        XCTAssertEqual(installer.status(), .claudeNotFound)
        XCTAssertThrowsError(try installer.install())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testInstallPreservesOtherSettingsAndUninstallRemovesOnlyTheBridge() throws {
        let directory = try temporaryDirectory()
        let installer = ClaudeSettingsInstaller(claudeDirectory: directory, executablePath: executable)
        try Data(#"{"model":"opus","permissions":{"allow":["Bash(ls)"]}}"#.utf8).write(to: installer.settingsURL)
        XCTAssertEqual(installer.status(), .notInstalled)

        try installer.install()
        XCTAssertEqual(installer.status(), .installed)
        var settings = try readJSON(installer.settingsURL)
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertNotNil(settings["permissions"])
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(
            statusLine["command"] as? String,
            "'/Applications/Usage Island.app/Contents/MacOS/UsageIslandPrototype' --claude-statusline"
        )

        try installer.uninstall()
        settings = try readJSON(installer.settingsURL)
        XCTAssertNil(settings["statusLine"])
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testCustomStatusLineIsNeverReplacedOrRemoved() throws {
        let directory = try temporaryDirectory()
        let installer = ClaudeSettingsInstaller(claudeDirectory: directory, executablePath: executable)
        let original = Data(#"{"statusLine":{"type":"command","command":"~/bin/my-status"}}"#.utf8)
        try original.write(to: installer.settingsURL)

        XCTAssertEqual(installer.status(), .otherStatusLine)
        XCTAssertThrowsError(try installer.install()) { XCTAssertEqual($0 as? ClaudeSettingsError, .otherStatusLine) }
        XCTAssertThrowsError(try installer.uninstall()) { XCTAssertEqual($0 as? ClaudeSettingsError, .otherStatusLine) }
        XCTAssertEqual(try Data(contentsOf: installer.settingsURL), original)
    }

    func testUnreadableSettingsAreLeftUntouched() throws {
        let directory = try temporaryDirectory()
        let installer = ClaudeSettingsInstaller(claudeDirectory: directory, executablePath: executable)
        let original = Data("{ not json".utf8)
        try original.write(to: installer.settingsURL)
        XCTAssertEqual(installer.status(), .unreadableSettings)
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try Data(contentsOf: installer.settingsURL), original)
    }

    func testRepairPointsBridgeAtThisAppOnlyWhenTheOldExecutableIsGone() throws {
        let directory = try temporaryDirectory()
        let old = ClaudeSettingsInstaller(claudeDirectory: directory, executablePath: "/Old/Usage Island.app/Contents/MacOS/UsageIslandPrototype")
        try old.install()

        let present = ClaudeSettingsInstaller(claudeDirectory: directory, executablePath: executable, executableExists: { _ in true })
        present.repairIfNeeded()
        XCTAssertEqual(try command(in: directory), old.command)

        let moved = ClaudeSettingsInstaller(claudeDirectory: directory, executablePath: executable, executableExists: { _ in false })
        moved.repairIfNeeded()
        XCTAssertEqual(try command(in: directory), moved.command)
    }

    func testShellQuotingRoundTripsApostrophes() {
        let path = "/Users/o'neil/Apps/Usage Island.app/Contents/MacOS/UsageIslandPrototype"
        let installer = ClaudeSettingsInstaller(claudeDirectory: URL(fileURLWithPath: "/tmp"), executablePath: path)
        XCTAssertEqual(ClaudeSettingsInstaller.executablePath(inCommand: installer.command), path)
        XCTAssertTrue(ClaudeSettingsInstaller.isBridge(["command": installer.command]))
    }

    private func command(in directory: URL) throws -> String? {
        let settings = try readJSON(directory.appendingPathComponent("settings.json"))
        return (settings["statusLine"] as? [String: Any])?["command"] as? String
    }
}

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
