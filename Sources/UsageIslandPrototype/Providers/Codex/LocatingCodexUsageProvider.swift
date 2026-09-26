import Foundation

actor LocatingCodexUsageProvider: UsageProvider {
    nonisolated let id: ProviderID = .codex

    private let locator: ExecutableLocator
    private let clock: any UsageClock
    private let makeCodexProvider: @Sendable (
        CodexAppServerConfiguration,
        any UsageClock
    ) -> CodexUsageProvider
    private var inner: CodexUsageProvider?
    private var innerExecutableURL: URL?
    private var isShutDown = false

    init(
        locator: ExecutableLocator,
        clock: any UsageClock,
        makeCodexProvider: @escaping @Sendable (
            CodexAppServerConfiguration,
            any UsageClock
        ) -> CodexUsageProvider
    ) {
        self.locator = locator
        self.clock = clock
        self.makeCodexProvider = makeCodexProvider
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard !isShutDown else {
            throw CancellationError()
        }
        let executableURL: URL
        do {
            executableURL = try locator.locate("codex")
        } catch {
            throw CodexUsageError.appServerFailure(.executableUnavailable)
        }

        // Reinstalling or upgrading Codex can move the executable; retire the
        // provider bound to the old path instead of relaunching it forever.
        var retired: CodexUsageProvider?
        if inner == nil || innerExecutableURL != executableURL {
            retired = inner
            inner = makeCodexProvider(
                CodexAppServerConfiguration(executableURL: executableURL),
                clock
            )
            innerExecutableURL = executableURL
        }
        let provider = inner!
        if let retired {
            try? await retired.shutdown()
        }
        return try await provider.fetchUsage()
    }

    func shutdown() async throws {
        isShutDown = true
        let provider = inner
        inner = nil
        innerExecutableURL = nil
        try await provider?.shutdown()
    }
}
