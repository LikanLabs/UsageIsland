import XCTest

@testable import UsageIslandPrototype

final class UsageIslandPrototypeTests: XCTestCase {
  func testProviderCatalogContainsOnlyCodex() {
    XCTAssertEqual(ProviderID.allCases, [.codex])
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

  func testResetFormatting() {
    let now = Date(timeIntervalSince1970: 1_000)
    let reset = now.addingTimeInterval(3_660)
    XCTAssertEqual(UsageFormatting.resetText(until: reset, now: now), "1h 1m")
  }

  func testNilResetFormattingDoesNotInventDate() {
    XCTAssertEqual(UsageFormatting.resetText(until: nil), "—")
  }

  func testWindowDurationFormatting() {
    let cases = [
      (300, "Cinco horas"),
      (10_080, "Semana"),
      (1, "1 minuto"),
      (45, "45 minutos"),
      (60, "1 hora"),
      (180, "3 horas"),
      (1_440, "1 día"),
      (4_320, "3 días")
    ]

    for (duration, expected) in cases {
      XCTAssertEqual(UsageFormatting.windowDuration(duration), expected)
    }
  }

  func testSecondaryWeeklyPresentationDependsOnAvailableWindows() throws {
    let short = try UsageWindow(
      durationMinutes: 300,
      remainingPercent: 70,
      resetsAt: nil
    )
    let weekly = try UsageWindow(
      durationMinutes: 10_080,
      remainingPercent: 55,
      resetsAt: nil
    )
    let future = try UsageWindow(
      durationMinutes: 15,
      remainingPercent: 80,
      resetsAt: nil
    )

    XCTAssertEqual(
      UsageFormatting.secondaryWeeklyRemainingPercent(
        for: try snapshot(preferred: short, additional: [weekly])
      ),
      55
    )
    XCTAssertNil(
      UsageFormatting.secondaryWeeklyRemainingPercent(
        for: try snapshot(preferred: weekly)
      )
    )
    XCTAssertEqual(
      UsageFormatting.secondaryWeeklyRemainingPercent(
        for: try snapshot(preferred: future, additional: [weekly])
      ),
      55
    )
    XCTAssertNil(
      UsageFormatting.secondaryWeeklyRemainingPercent(
        for: try snapshot(preferred: short)
      )
    )
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

  private func snapshot(
    preferred: UsageWindow,
    additional: [UsageWindow] = []
  ) throws -> UsageSnapshot {
    try UsageSnapshot(
      provider: .codex,
      preferredWindow: preferred,
      additionalWindows: additional,
      weeklySpend: nil,
      freshness: .fresh,
      isActivelyUsed: false,
      capturedAt: .now
    )
  }

}
