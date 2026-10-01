import AppKit
import SwiftUI

/// Versions 0.1.3–0.1.7 could register this executable as Claude Code's
/// status line (`--claude-statusline`). Until that entry is cleaned up, such
/// a call must print nothing and exit instead of starting a second app.
///
/// The app itself runs on AppKit directly: all of its UI lives in the pill
/// and panel windows. (A SwiftUI `App` needs at least one scene, and its
/// placeholder Settings window could be opened empty by the system.)
@main
enum UsageIslandMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == ClaudeLegacyBridge.argument {
            return
        }
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let codexUsageProvider: LocatingCodexUsageProvider
    private let terminationReply: (Bool) -> Void
    private var refreshController: UsageRefreshController?
    private var islandController: CodexEdgeWindowController?
    private var alertMonitor: UsageAlertMonitor?
    private var updateCheck: Timer?
    private var relaunchPending = false
    private let runningVersion = BundleVersion.onDisk(at: Bundle.main.bundleURL)
    private var initialRefreshTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var didBeginTermination = false
    private var didReplyToTermination = false

    override init() {
        let composition = Self.makeLiveComposition(
            clock: SystemUsageClock(),
            locator: ExecutableLocator()
        )
        model = composition.model
        codexUsageProvider = composition.codexUsageProvider
        terminationReply = { shouldTerminate in
            NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        super.init()
    }

    init(
        composition: LiveComposition,
        terminationReply: @escaping (Bool) -> Void
    ) {
        model = composition.model
        codexUsageProvider = composition.codexUsageProvider
        self.terminationReply = terminationReply
        super.init()
    }

    static func makeModel(
        providerAdapters: [any UsageProvider],
        clock: any UsageClock,
        initialSnapshots: [UsageSnapshot],
        initialAgents: [AgentSession] = []
    ) -> AppModel {
        do {
            return try AppModel(
                providerAdapters: providerAdapters,
                clock: clock,
                initialSnapshots: initialSnapshots,
                initialAgents: initialAgents
            )
        } catch {
            return AppModel.empty(
                clock: clock,
                initialAgents: initialAgents
            )
        }
    }

    static func makeLiveComposition(
        clock: any UsageClock,
        locator: ExecutableLocator,
        makeCodexProvider: @escaping @Sendable (
            CodexAppServerConfiguration,
            any UsageClock
        ) -> CodexUsageProvider = { configuration, clock in
            CodexUsageProvider(configuration: configuration, clock: clock)
        },
        makeClaudeQuery: (@Sendable () -> (any ClaudeUsageQuerying)?)? = nil
    ) -> LiveComposition {
        let provider = LocatingCodexUsageProvider(
            locator: locator,
            clock: clock,
            makeCodexProvider: makeCodexProvider
        )
        let claude = ClaudeUsageProvider(
            clock: clock,
            makeQuery: makeClaudeQuery ?? ClaudeUsageProvider.cliQuery(locator: locator)
        )
        let model = makeModel(
            providerAdapters: [provider, claude],
            clock: clock,
            initialSnapshots: [],
            initialAgents: []
        )

        return LiveComposition(
            model: model,
            codexUsageProvider: provider
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Undo the Claude Code status line older versions could add.
        ClaudeLegacyBridge.removeIfInstalled()
        let notifier = SystemUsageNotifier()
        // Clicking an alert opens the usage panel.
        notifier.onOpen = { [weak self] in self?.showUsagePanel() }
        let system = SystemIntegration(login: SystemLoginItem(), notifier: notifier)
        let alerts = UsageAlertMonitor(model: model, preferences: .shared, notifier: notifier, clock: SystemUsageClock())
        alertMonitor = alerts
        alerts.start()
        let island = CodexEdgeWindowController(model: model, system: system)
        islandController = island
        island.show()
        startInitialRefresh()
        let refresh = UsageRefreshController(model: model)
        refreshController = refresh
        refresh.start()
        startUpdateCheck()
    }

    /// `brew upgrade` replaces the bundle while this process keeps running
    /// the old code. Notice the new version on disk and reopen on it.
    private func startUpdateCheck() {
        guard runningVersion != nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.relaunchIfUpdated() }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateCheck = timer
    }

    private func relaunchIfUpdated() {
        guard !relaunchPending, !didBeginTermination,
              AppUpdateRelaunch.shouldRelaunch(
                running: runningVersion,
                onDisk: BundleVersion.onDisk(at: Bundle.main.bundleURL),
                panelOpen: model.isPulseOpen
              ) else { return }
        relaunchPending = true
        do {
            try AppUpdateRelaunch.scheduleReopen(of: Bundle.main.bundleURL)
            NSApp.terminate(nil)
        } catch {
            relaunchPending = false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCheck?.invalidate()
        updateCheck = nil
        alertMonitor?.stop()
        refreshController?.stop()
        refreshController = nil
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        model.stop()
        islandController?.shutdown()
        islandController = nil
    }

    /// Opening the app again (its icon in Finder, Launchpad or Spotlight)
    /// shows the usage panel instead of asking for a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showUsagePanel()
        return false
    }

    private func showUsagePanel() {
        guard !didBeginTermination, !model.isPulseOpen else { return }
        islandController?.togglePulse()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination()
    }

    func requestTermination() -> NSApplication.TerminateReply {
        if didReplyToTermination {
            return .terminateNow
        }
        guard !didBeginTermination else {
            return .terminateLater
        }

        didBeginTermination = true
        islandController?.shutdown()
        islandController = nil
        refreshController?.stop()
        refreshController = nil
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        model.stop()

        let provider = codexUsageProvider
        terminationTask = Task { [self] in
            try? await provider.shutdown()
            finishTermination()
            terminationTask = nil
        }
        return .terminateLater
    }

    func startInitialRefresh() {
        guard initialRefreshTask == nil, !didBeginTermination else {
            return
        }
        initialRefreshTask = Task { @MainActor [model] in
            await model.refreshUsage()
        }
    }

    func waitForInitialRefresh() async {
        await initialRefreshTask?.value
    }

    func waitForTermination() async {
        await terminationTask?.value
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func finishTermination() {
        guard !didReplyToTermination else {
            return
        }
        didReplyToTermination = true
        terminationReply(true)
    }
}

struct LiveComposition {
    let model: AppModel
    let codexUsageProvider: LocatingCodexUsageProvider
}
