import XCTest

final class ResilienceTests: XCTestCase {
    func testPanelPresentation() async throws { try await ResilienceScenarios.panelPresentation() }
    func testRingColors() throws { try ResilienceScenarios.ringColors() }
    func testQueuedCancellationKeepsHealthyClient() async throws { try await ResilienceScenarios.queuedCancellationKeepsHealthyClient() }
    func testCancelledRequestRecoversOnNextRefresh() async throws { try await ResilienceScenarios.cancelledRequestRecoversOnNextRefresh() }
    func testStartupRecovery() async throws { try await ResilienceScenarios.startupRecovery() }
    func testStaleThenRecovery() async throws { try await ResilienceScenarios.staleThenRecovery() }
    func testCleanupFailureDoesNotStartAnotherProcess() async throws { try await ResilienceScenarios.cleanupFailureDoesNotStartAnotherProcess() }
    func testShutdownDuringRecovery() async throws { try await ResilienceScenarios.shutdownDuringRecovery() }
    func testAccountFailureDoesNotRestart() async throws { try await ResilienceScenarios.accountFailureDoesNotRestart() }
    func testSleepWakeAndPolling() async throws { try await ResilienceScenarios.sleepWakeAndPolling() }
    func testScreenGeometry() throws { try ResilienceScenarios.screenGeometry() }
    func testDockVisibility() throws { try ResilienceScenarios.dockVisibility() }
}
