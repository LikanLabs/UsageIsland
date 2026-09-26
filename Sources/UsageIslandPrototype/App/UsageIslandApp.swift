import AppKit
import SwiftUI

/// Claude Code runs this executable as its status line command. That mode
/// records the plan limits and exits without starting the app.
@main
enum UsageIslandMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == ClaudeStatuslineBridge.argument {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            print(ClaudeStatuslineBridge.run(input: input))
            return
        }
        UsageIslandPrototypeApp.main()
    }
}

struct UsageIslandPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let codexUsageProvider: LocatingCodexUsageProvider
    private let terminationReply: (Bool) -> Void
    private var refreshController: UsageRefreshController?
    private var islandController: CodexEdgeWindowController?
    private var claudeConnection: ClaudeConnection?
    private let claudeRecordURL: URL
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
        claudeRecordURL = composition.claudeRecordURL
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
        claudeRecordURL = composition.claudeRecordURL
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
        claudeRecordURL: URL = ClaudeStatuslineBridge.defaultRecordURL,
        makeCodexProvider: @escaping @Sendable (
            CodexAppServerConfiguration,
            any UsageClock
        ) -> CodexUsageProvider = { configuration, clock in
            CodexUsageProvider(configuration: configuration, clock: clock)
        }
    ) -> LiveComposition {
        let provider = LocatingCodexUsageProvider(
            locator: locator,
            clock: clock,
            makeCodexProvider: makeCodexProvider
        )
        let claude = ClaudeUsageProvider(recordURL: claudeRecordURL, clock: clock)
        let model = makeModel(
            providerAdapters: [provider, claude],
            clock: clock,
            initialSnapshots: [],
            initialAgents: []
        )

        return LiveComposition(
            model: model,
            codexUsageProvider: provider,
            claudeRecordURL: claudeRecordURL
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let claude = ClaudeConnection(installer: ClaudeSettingsInstaller(), model: model, recordURL: claudeRecordURL)
        claudeConnection = claude
        claude.start()
        let island = CodexEdgeWindowController(model: model, claude: claude)
        islandController = island
        island.show()
        startInitialRefresh()
        let refresh = UsageRefreshController(model: model)
        refreshController = refresh
        refresh.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        claudeConnection?.stop()
        refreshController?.stop()
        refreshController = nil
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        model.stop()
        islandController?.shutdown()
        islandController = nil
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
    let claudeRecordURL: URL
}
