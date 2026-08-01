import AppKit
import SwiftUI

@main
struct UsageIslandPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("Usage Island Prototype")
                    .font(.title2.weight(.semibold))
                Text("Usa el Beacon para cambiar escenarios, layouts y solicitar acceso de Accessibility.")
                    .foregroundStyle(.secondary)
                Text("Este prototipo usa datos simulados; todavía no conecta proveedores reales.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 430)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let codexUsageProvider: CodexUsageProvider?
    private let terminationReply: (Bool) -> Void
    private let occupancyService = MenuBarOccupancyService()
    private var islandController: IslandWindowController?
    private var beaconController: BeaconController?
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

    static func makeDemoModel(clock: any UsageClock) -> AppModel {
        makeModel(
            providerAdapters: DemoUsageProvider.providerAdapters(for: .normal, clock: clock),
            clock: clock,
            initialSnapshots: DemoUsageProvider.snapshots(for: .normal, clock: clock)
        )
    }

    static func makeModel(
        providerAdapters: [any UsageProvider],
        clock: any UsageClock,
        initialSnapshots: [UsageSnapshot],
        initialAgents: [AgentSession]? = nil,
        initialScenario: DemoScenario = .normal
    ) -> AppModel {
        do {
            return try AppModel(
                providerAdapters: providerAdapters,
                clock: clock,
                initialSnapshots: initialSnapshots,
                initialAgents: initialAgents,
                initialScenario: initialScenario
            )
        } catch {
            return AppModel.empty(
                clock: clock,
                initialAgents: initialAgents,
                initialScenario: initialScenario
            )
        }
    }

    static func makeLiveComposition(
        clock: any UsageClock,
        locator: ExecutableLocator,
        makeCodexProvider: (
            CodexAppServerConfiguration,
            any UsageClock
        ) -> CodexUsageProvider = { configuration, clock in
            CodexUsageProvider(configuration: configuration, clock: clock)
        }
    ) -> LiveComposition {
        let codexUsageProvider: CodexUsageProvider?
        let codexAdapter: any UsageProvider
        if let executableURL = try? locator.locate("codex") {
            let provider = makeCodexProvider(
                CodexAppServerConfiguration(executableURL: executableURL),
                clock
            )
            codexUsageProvider = provider
            codexAdapter = provider
        } else {
            codexUsageProvider = nil
            codexAdapter = UnavailableCodexUsageProvider()
        }

        let claudeAdapter = DemoUsageProvider(
            id: .claude,
            scenario: .normal,
            clock: clock
        )
        let openCodeAdapter = DemoUsageProvider(
            id: .openCodeGo,
            scenario: .normal,
            clock: clock
        )
        let capturedAt = clock.now()
        let initialSnapshots = [
            claudeAdapter.snapshot(at: capturedAt),
            openCodeAdapter.snapshot(at: capturedAt)
        ]
        let model = makeModel(
            providerAdapters: [claudeAdapter, codexAdapter, openCodeAdapter],
            clock: clock,
            initialSnapshots: initialSnapshots,
            initialAgents: []
        )

        return LiveComposition(
            model: model,
            codexUsageProvider: codexUsageProvider
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let island = IslandWindowController(model: model, occupancyService: occupancyService)
        let beacon = BeaconController(model: model, allowsDemoScenarios: false)

        beacon.onTogglePulse = { [weak island] in island?.togglePulse() }
        beacon.onRefreshLayout = { [weak island] in island?.refreshLayout() }
        beacon.onRequestAccessibility = { [weak island] in island?.requestAccessibilityPermission() }

        islandController = island
        beaconController = beacon
        island.show()
        startInitialRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        model.stop()
        islandController?.shutdown()
        islandController = nil
        beaconController = nil
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
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        model.stop()

        let provider = codexUsageProvider
        terminationTask = Task { [self] in
            if let provider {
                try? await provider.shutdown()
            }
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
    let codexUsageProvider: CodexUsageProvider?
}

private struct UnavailableCodexUsageProvider: UsageProvider {
    let id: ProviderID = .codex

    func fetchUsage() async throws -> UsageSnapshot {
        throw CodexUsageError.appServerFailure(.executableUnavailable)
    }
}
