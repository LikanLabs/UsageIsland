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
        let executableURL: URL
        do {
            executableURL = try locator.locate("codex")
        } catch {
            throw CodexUsageError.appServerFailure(.executableUnavailable)
        }

        if inner == nil {
            inner = makeCodexProvider(
                CodexAppServerConfiguration(executableURL: executableURL),
                clock
            )
        }
        return try await inner!.fetchUsage()
    }

    func shutdown() async throws {
        let provider = inner
        inner = nil
        try await provider?.shutdown()
    }
}
