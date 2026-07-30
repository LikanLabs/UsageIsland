import XCTest

@testable import UsageIslandPrototype

final class UsageIslandPrototypeTests: XCTestCase {
  func testPriorityMakesCriticalProviderFirst() {
    let now = Date.now
    let normal = ProviderUsage(
      id: .codex,
      shortWindow: .init(remainingPercent: 60, resetsAt: now),
      weeklyRemainingPercent: 60,
      weeklySpend: nil,
      freshness: .fresh,
      isCurrentlyActive: true
    )
    let critical = ProviderUsage(
      id: .claude,
      shortWindow: .init(remainingPercent: 8, resetsAt: now),
      weeklyRemainingPercent: 30,
      weeklySpend: nil,
      freshness: .fresh,
      isCurrentlyActive: false
    )

    XCTAssertGreaterThan(critical.priorityScore, normal.priorityScore)
  }

  func testResetFormatting() {
    let now = Date(timeIntervalSince1970: 1_000)
    let reset = now.addingTimeInterval(3_660)
    XCTAssertEqual(UsageFormatting.resetText(until: reset, now: now), "1h 1m")
  }
  @MainActor
  func testUnifiedLayoutKeepsBodyContainedAndFooterSpaceAvailable() {
    let layout = UnifiedIslandLayout()
    layout.update(notchWidth: 150, leftWingWidth: 142, rightWingWidth: 72)

    XCTAssertEqual(layout.naturalTopWidth, 364)
    XCTAssertGreaterThanOrEqual(layout.bodyWidth, 386)
    XCTAssertGreaterThanOrEqual(layout.collapsedBodyHeight, 236)
    XCTAssertGreaterThan(layout.expandedBodyHeight, layout.collapsedBodyHeight)
  }

}
