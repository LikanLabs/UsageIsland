import Foundation

@main
struct VerifyResilience {
    static func main() async throws {
        try ResilienceScenarios.panelPresentation()
        print("PASS: settings close without resetting during fade; rapid reopen rejects old completion")
        try ResilienceScenarios.ringColors()
        print("PASS: ring colors follow remaining-quota boundaries")
        try await ResilienceScenarios.queuedCancellationKeepsHealthyClient()
        print("PASS: queued cancellation keeps the healthy client")
        try await ResilienceScenarios.cancelledRequestRecoversOnNextRefresh()
        print("PASS: cancelled request recovers on the very next refresh")
        try await ResilienceScenarios.startupRecovery()
        print("PASS: failed startup recovers")
        try await ResilienceScenarios.staleThenRecovery()
        print("PASS: transport, timeout and remote failures preserve stale quota and recover")
        try await ResilienceScenarios.cleanupFailureDoesNotStartAnotherProcess()
        print("PASS: failed cleanup prevents duplicate processes")
        try await ResilienceScenarios.shutdownDuringRecovery()
        print("PASS: shutdown during recovery never restarts")
        try await ResilienceScenarios.accountFailureDoesNotRestart()
        print("PASS: authentication errors do not trigger restart loops")
        try await ResilienceScenarios.sleepWakeAndPolling()
        print("PASS: sleep/wake notifications pause and resume polling")
        try ResilienceScenarios.screenGeometry()
        print("PASS: 768 layout cases plus 30 adaptive-notch camera-occlusion regression cases")
        try ResilienceScenarios.dockVisibility()
        print("PASS: auto-hide delay, reveal, pinned details, menus and fixed mode")
    }
}
