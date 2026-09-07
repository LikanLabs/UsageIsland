import AppKit
import Foundation
@testable import UsageIslandPrototype

/// Shared by XCTest and the standalone verification runner on CLT-only Macs.
enum ResilienceScenarios {
    @MainActor
    static func panelPresentation() throws {
        let state = EdgePanelNavigation()
        _ = state.beginPresentation(true)
        state.showsSettings = true
        let closing = state.beginPresentation(false)
        try check(state.showsSettings, "settings must stay visible throughout the close fade")
        try check(state.canFinishClosing(closing), "current close may finish")
        state.finishClosing(closing)
        try check(!state.showsSettings, "only the hidden panel resets to usage")

        _ = state.beginPresentation(true)
        state.showsSettings = true
        let interrupted = state.beginPresentation(false)
        _ = state.beginPresentation(true)
        state.showsSettings = true
        try check(!state.canFinishClosing(interrupted), "old completion must not hide a reopened panel")
        state.finishClosing(interrupted)
        try check(state.showsSettings, "old completion must not change the reopened page")
        let latest = state.beginPresentation(false)
        try check(!state.canFinishClosing(interrupted) && state.canFinishClosing(latest), "only latest close owns completion")
        state.finishClosing(latest)
        try check(!state.showsSettings, "latest close resets normally")
    }

    static func ringColors() throws {
        for (remaining, level) in [(100, UsageRingLevel.plenty), (51, .plenty), (50, .moderate), (26, .moderate), (25, .low), (11, .low), (10, .critical), (0, .critical)] {
            try check(UsageRingLevel(remainingPercent: remaining) == level, "remaining quota color threshold")
        }
    }

    static func queuedCancellationKeepsHealthyClient() async throws {
        let requestGate = RecoveryGate()
        let fetchGate = CodexUsageFetchGate()
        let first = RecoveryFixtureClient(requestGate: requestGate)
        let replacement = RecoveryFixtureClient()
        let provider = CodexUsageProvider(client: first, clock: SystemUsageClock(), gate: fetchGate, makeReplacementClient: { replacement })
        let active = Task { try await provider.fetchUsage() }
        await requestGate.waitForEntry()
        let queued = Task { try await provider.fetchUsage() }
        await fetchGate.waitUntilQueued()
        queued.cancel()
        do {
            _ = try await queued.value
            throw CheckFailure.message("queued fetch must respect cancellation")
        } catch is CancellationError {}
        await requestGate.open()
        _ = try await active.value
        _ = try await provider.fetchUsage()
        let old = await first.counts()
        let new = await replacement.counts()
        try check(old.starts == 1 && old.shutdowns == 0 && new.starts == 0, "queued cancellation must preserve the healthy client")
        try await provider.shutdown()
    }

    static func cancelledRequestRecoversOnNextRefresh() async throws {
        let gate = RecoveryGate()
        let first = RecoveryFixtureClient(requestGate: gate)
        let replacement = RecoveryFixtureClient()
        let provider = CodexUsageProvider(client: first, clock: SystemUsageClock(), makeReplacementClient: { replacement })
        let fetch = Task { try await provider.fetchUsage() }
        await gate.waitForEntry()
        fetch.cancel()
        await gate.open()
        do {
            _ = try await fetch.value
            throw CheckFailure.message("cancelled fetch must not publish usage")
        } catch is CancellationError {}
        // JSONRPCClient closes its transport on request cancellation. The very
        // next refresh must replace it, without wasting a polling interval.
        let snapshot = try await provider.fetchUsage()
        try check(snapshot.provider == .codex, "first refresh after cancellation must recover")
        let old = await first.counts()
        let new = await replacement.counts()
        try check(old.shutdowns == 1 && new.starts == 1, "cancelled transport must be retired before a new handshake")
        try await provider.shutdown()
    }

    static func startupRecovery() async throws {
        let broken = RecoveryFixtureClient(startFails: true)
        let healthy = RecoveryFixtureClient()
        let provider = CodexUsageProvider(client: broken, clock: SystemUsageClock(), makeReplacementClient: { healthy })
        try await expectFailure(provider)
        let snapshot = try await provider.fetchUsage()
        try check(snapshot.provider == .codex, "startup retry must return Codex")
        let oldCounts = await broken.counts()
        let newCounts = await healthy.counts()
        try check(oldCounts.shutdowns == 1 && newCounts.starts == 1, "old process must close before a fresh handshake")
        try await provider.shutdown()
    }

    @MainActor
    static func staleThenRecovery() async throws {
        for failure in [JSONRPCError.transportClosed, .requestTimedOut(.integer(1)), .remoteError(code: -32000)] {
            try await staleThenRecovery(failure: failure)
        }
    }

    @MainActor
    private static func staleThenRecovery(failure: JSONRPCError) async throws {
        let first = RecoveryFixtureClient()
        let replacement = RecoveryFixtureClient()
        let provider = CodexUsageProvider(client: first, clock: SystemUsageClock(), makeReplacementClient: { replacement })
        let model = try AppModel(providerAdapters: [provider], clock: SystemUsageClock(), initialSnapshots: [], initialAgents: [])
        await model.refreshUsage()
        let valid = model.providers
        try check(valid.count == 1, "first snapshot missing")
        await first.breakTransport(failure)
        await model.refreshUsage()
        try check(model.providers.first?.windows == valid.first?.windows, "failure must preserve quota")
        try check(model.freshness(for: .codex) == .stale, "failure must mark quota stale")
        await model.refreshUsage()
        try check(model.freshness(for: .codex) == .fresh && model.connectionStates[.codex] == .connected, "retry must recover")
        try await provider.shutdown()
    }

    static func cleanupFailureDoesNotStartAnotherProcess() async throws {
        let first = RecoveryFixtureClient(startFails: true, shutdownFailures: 1)
        let replacement = RecoveryFixtureClient()
        let provider = CodexUsageProvider(client: first, clock: SystemUsageClock(), makeReplacementClient: { replacement })
        try await expectFailure(provider)
        try await expectFailure(provider)
        let before = await replacement.counts()
        try check(before.starts == 0, "must not start a second process before cleanup succeeds")
        _ = try await provider.fetchUsage()
        let after = await replacement.counts()
        try check(after.starts == 1, "cleanup retry should recover")
        try await provider.shutdown()
    }

    static func shutdownDuringRecovery() async throws {
        let gate = RecoveryGate()
        let first = RecoveryFixtureClient(startFails: true, shutdownGate: gate)
        let replacement = RecoveryFixtureClient()
        let provider = CodexUsageProvider(client: first, clock: SystemUsageClock(), makeReplacementClient: { replacement })
        try await expectFailure(provider)
        let recovering = Task { try await provider.fetchUsage() }
        await gate.waitForEntry()
        try await provider.shutdown()
        await gate.open()
        do {
            _ = try await recovering.value
            throw CheckFailure.message("shutdown must prevent recovery publication")
        } catch is CodexUsageError {} catch is CancellationError {}
        let counts = await replacement.counts()
        try check(counts.starts == 0, "shutdown must prevent restarting the process")
    }

    static func accountFailureDoesNotRestart() async throws {
        let first = RecoveryFixtureClient(authenticated: false)
        let replacement = RecoveryFixtureClient()
        let provider = CodexUsageProvider(client: first, clock: SystemUsageClock(), makeReplacementClient: { replacement })
        try await expectFailure(provider)
        try await expectFailure(provider)
        let counts = await first.counts()
        let unused = await replacement.counts()
        try check(counts.starts == 1 && unused.starts == 0, "authentication failure must not spawn processes repeatedly")
        try await provider.shutdown()
    }

    @MainActor
    static func sleepWakeAndPolling() async throws {
        let client = RecoveryFixtureClient()
        let provider = CodexUsageProvider(client: client, clock: SystemUsageClock())
        let model = try AppModel(providerAdapters: [provider], clock: SystemUsageClock(), initialSnapshots: [], initialAgents: [])
        await model.refreshUsage()
        let notifications = NotificationCenter()
        let controller = UsageRefreshController(model: model, notifications: notifications, interval: .milliseconds(25))
        controller.start()
        defer { controller.stop() }
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await eventually { model.freshness(for: .codex) == .stale }
        let sleeping = await client.counts()
        try await Task.sleep(for: .milliseconds(80))
        let stillSleeping = await client.counts()
        try check(sleeping.requests == stillSleeping.requests, "sleep must pause polling")
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await eventually { model.freshness(for: .codex) == .fresh }
        let woke = await client.counts()
        try check(woke.requests > sleeping.requests, "wake must refresh")
        try await Task.sleep(for: .milliseconds(80))
        let polled = await client.counts()
        try check(polled.requests > woke.requests, "polling must resume after wake")
        controller.stop()
        let stopped = await client.counts()
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))
        let afterStop = await client.counts()
        try check(afterStop.requests == stopped.requests, "stop must detach wake/polling")
        try await provider.shutdown()
    }

    static func screenGeometry() throws {
        try adaptiveNotchGeometry()
        let screens = [
            CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 1512, y: -1080, width: 2560, height: 1440),
            CGRect(x: -400, y: -400, width: 400, height: 240)
        ]
        for screen in screens {
            for requested in [0.75, 1.0, 1.25, 1.5] {
                for backing in [1.0, 2.0] {
                    let visible = screen.insetBy(dx: 0, dy: 25)
                    for position in EdgePosition.allCases {
                        for height in [230.0, 318.0, 346.0, 316.0] {
                            for inset in [0.0, 32.0] {
                                let cutout = inset > 0 ? CGRect(x: screen.midX - 95, y: screen.maxY - inset, width: 190, height: inset) : nil
                                let result = EdgeWindowGeometry.resolve(screen: screen, visible: visible, requestedScale: requested, backingScale: backing, position: position, topInset: inset, notchFrame: cutout, detailHeight: height)
                                try check(screen.contains(result.tab) && screen.contains(result.detail), "windows must fit their screen")
                                let surface = result.visibleDetail(height: height / 2, position: position)
                                let host = result.detail.insetBy(dx: -0.01, dy: -0.01)
                                try check(host.contains(surface), "animated surface must fit the stable host")
                                if position == .top {
                                    try check(abs(surface.maxY - result.detail.maxY) <= 1 / backing, "short content must not introduce transparent space below notch")
                                } else {
                                    try check(abs(surface.midY - result.detail.midY) < 0.001, "side surfaces stay centered while resizing")
                                }
                                let gap: CGFloat
                                switch position {
                                case .right:
                                    gap = result.tab.minX - result.detail.maxX
                                    try check(result.tab.maxX == screen.maxX && result.activation.maxX == screen.maxX, "right pill must meet physical edge")
                                case .left:
                                    gap = result.detail.minX - result.tab.maxX
                                    try check(result.tab.minX == screen.minX && result.activation.minX == screen.minX, "left pill must meet physical edge")
                                case .top:
                                    gap = result.tab.minY - result.detail.maxY
                                    let anchor = inset > 0 ? screen.maxY - inset : visible.maxY
                                    if inset > 0 {
                                        // SwiftUI reserves topOverlap at the TOP of the window.
                                        // In AppKit that means subtracting it from maxY.
                                        let contentTop = result.tab.maxY - result.topOverlap
                                        try check(contentTop <= anchor + 1 / backing, "logo and percentage must be entirely below the camera")
                                        try check(result.tab.minY < anchor - 20 * result.scale, "the visible indicator must extend down into usable screen space")
                                    } else {
                                        try check(abs(result.tab.maxY - anchor) <= 1 / backing, "menu-bar fallback must meet its lower edge")
                                    }
                                    try check(result.activation.maxY == screen.maxY, "top reveal reaches physical edge")
                                    if inset > 0 {
                                        try check(abs(result.tab.width - 190) <= 1 / backing, "notch bridge must cover the complete detected hardware width")
                                        try check(result.topOverlap == 8, "notch overlap must stay independent of content scale")
                                    } else {
                                        try check(result.topOverlap == 0, "displays without a notch must not overlap the menu bar")
                                    }
                                }
                                try check(abs(gap - CodexEdgeLayout.gap * result.scale) <= 1 / backing, "visible gap must be consistent at every position and panel height")
                                try check(result.scale <= requested, "small display fallback must not enlarge UI")
                            }
                        }
                    }
                }
            }
        }
    }

    private static func adaptiveNotchGeometry() throws {
        // Synthetic cutouts, including fractional points and a non-centered
        // cutout on a secondary display. These are not model-specific presets.
        let screen = CGRect(x: -1512, y: -982, width: 1512, height: 982)
        for size in [CGSize(width: 185, height: 32), CGSize(width: 220, height: 38), CGSize(width: 163.5, height: 28.5)] {
            let notch = CGRect(x: screen.midX - size.width / 2 + 3.5,
                               y: screen.maxY - size.height, width: size.width, height: size.height)
            for scale in [0.75, 0.85, 1.0, 1.25, 1.5] {
                for backing in [1.0, 2.0] {
                    let result = EdgeWindowGeometry.resolve(screen: screen, visible: screen.insetBy(dx: 0, dy: 25), requestedScale: scale,
                        backingScale: backing, position: .top, topInset: size.height, notchFrame: notch)
                    let content = CGRect(x: result.tab.minX, y: result.tab.minY,
                        width: result.tab.width, height: result.tab.height - result.topOverlap)
                    let cameraInterior = notch.insetBy(dx: 0, dy: 1 / backing)
                    try check(!content.intersects(cameraInterior), "rendered content must not intersect the physical camera")
                    try check(content.maxY <= notch.minY + 1 / backing, "the whole content rectangle belongs BELOW the notch")
                    try check(abs(content.height - 36 * scale) <= 1 / backing, "notch height must not cap the user's content scale")
                    try check(abs(result.tab.minX - notch.minX) <= 1 / backing && abs(result.tab.maxX - notch.maxX) <= 1 / backing, "both edges must follow the detected cutout, even off center")
                    try check(abs(result.detail.midX - notch.midX) <= 1 / backing, "detail must follow the cutout center")
                }
            }
        }
    }

    static func dockVisibility() throws {
        var state = DockVisibilityState()
        func step(_ time: Double, active: Bool = false, pinned: Bool = false, menu: Bool = false, automatic: Bool = true) -> Bool {
            state.update(autoHide: automatic, pointerActive: active, pinned: pinned, menuOpen: menu, now: time)
        }
        try check(step(0) && step(0.3), "grace period permits crossing to detail")
        try check(!step(0.5), "idle indicator hides")
        try check(step(0.6, active: true), "edge pointer reveals")
        try check(step(1, pinned: true) && step(2, pinned: true), "pinned detail stays visible")
        try check(step(3, menu: true) && step(4, menu: true), "context menu stays visible")
        try check(step(5) && !step(6), "indicator hides after menu and pin close")
        try check(step(7, automatic: false) && step(20, automatic: false), "fixed mode restores and retains visibility")
    }

    private static func expectFailure(_ provider: CodexUsageProvider) async throws {
        do {
            _ = try await provider.fetchUsage()
        } catch { return }
        throw CheckFailure.message("Expected synthetic provider failure")
    }

    @MainActor
    private static func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CheckFailure.message("lifecycle event timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure.message(message) }
    }
    private enum CheckFailure: Error { case message(String) }
}

private actor RecoveryFixtureClient: CodexUsageClient {
    private let startFails: Bool
    private let authenticated: Bool
    private let shutdownGate: RecoveryGate?
    private let requestGate: RecoveryGate?
    private var shutdownFailures: Int
    private var failure: JSONRPCError?
    private var starts = 0
    private var requests = 0
    private var shutdowns = 0

    init(startFails: Bool = false, authenticated: Bool = true, shutdownFailures: Int = 0, shutdownGate: RecoveryGate? = nil, requestGate: RecoveryGate? = nil) {
        self.startFails = startFails
        self.authenticated = authenticated
        self.shutdownFailures = shutdownFailures
        self.shutdownGate = shutdownGate
        self.requestGate = requestGate
    }
    func start() throws {
        starts += 1
        if startFails { throw JSONRPCError.transportClosed }
    }
    func notifications() -> AsyncThrowingStream<JSONRPCNotification, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        requests += 1
        if requests == 1, let requestGate {
            await requestGate.wait()
            if Task.isCancelled {
                failure = .transportClosed
                throw JSONRPCError.requestCancelled(.integer(1))
            }
        }
        if let failure { throw failure }
        if method == "account/read" {
            return .object(["requiresOpenaiAuth": .bool(true), "account": authenticated ? .object(["type": .string("chatgpt"), "planType": .string("plus"), "email": .null]) : .null])
        }
        return .object(["rateLimits": .object([
            "primary": .object(["windowDurationMins": .integer(300), "usedPercent": .integer(25), "resetsAt": .integer(2_000_000_000)]),
            "secondary": .null
        ])])
    }
    func shutdown() async throws {
        shutdowns += 1
        if shutdowns == 1, let shutdownGate { await shutdownGate.wait() }
        if shutdownFailures > 0 { shutdownFailures -= 1; throw JSONRPCError.transportClosed }
    }
    func breakTransport(_ error: JSONRPCError) { failure = error }
    func counts() -> (starts: Int, requests: Int, shutdowns: Int) { (starts, requests, shutdowns) }
}

private actor RecoveryGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func open() { continuation?.resume(); continuation = nil }
}
