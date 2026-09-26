import XCTest

@testable import UsageIslandPrototype

final class UsageIslandPrototypeTests: XCTestCase {
  func testProviderCatalogContainsCodexAndClaude() {
    XCTAssertEqual(ProviderID.allCases, [.codex, .claude])
    XCTAssertEqual(ProviderID.claude.displayName, "Claude")
  }

  func testPriorityMakesCriticalProviderFirst() throws {
    let now = Date.now
    let normal = try ProviderUsage(
      id: .codex,
      preferredWindow: .init(
        durationMinutes: 300,
        remainingPercent: 60,
        resetsAt: now
      ),
      additionalWindows: [],
      weeklySpend: nil,
      freshness: .fresh,
      isCurrentlyActive: true,
      capturedAt: now
    )
    let critical = try ProviderUsage(
      id: .codex,
      preferredWindow: .init(
        durationMinutes: 300,
        remainingPercent: 8,
        resetsAt: now
      ),
      additionalWindows: [],
      weeklySpend: nil,
      freshness: .fresh,
      isCurrentlyActive: false,
      capturedAt: now
    )

    XCTAssertGreaterThan(critical.priorityScore, normal.priorityScore)
  }
}
