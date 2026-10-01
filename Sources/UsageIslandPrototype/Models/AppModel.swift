import AppKit
import Combine
import Foundation

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var providers: [ProviderUsage]
    @Published public private(set) var connectionStates: [ProviderID: ProviderConnectionState]
    @Published public var agents: [AgentSession] = []
    @Published public var leftMode: WingPresentationMode = .compact
    @Published public var rightMode: WingPresentationMode = .compact
    @Published public var requestedLayout: WingPresentationMode = .automatic
    @Published public var beaconPolicy: BeaconPolicy = .automatic
    @Published public var isPulseOpen = false
    @Published public var isPulsePresented = false
    @Published public var expandedProvider: ProviderID?
    @Published public private(set) var lastUpdatedAt: Date
    @Published public var adaptiveSpacingIsTrusted = false
    @Published public var islandIsVisible = true
    /// The provider the pill shows: the one used most recently since launch,
    /// otherwise the previous choice, otherwise the most critical one.
    @Published public private(set) var displayedProviderID: ProviderID?
    /// Why a provider without a reading has none; cleared on success.
    @Published public private(set) var issues: [ProviderID: ProviderIssue] = [:]

    private let clock: any UsageClock
    /// Activity before launch is ignored so an old reading cannot outrank a
    /// provider that is actually in use now.
    private let activityCutoff: Date
    private var lastActivity: [ProviderID: Date] = [:]
    private var forecaster = UsageForecaster()
    private var providerAdapters: [any UsageProvider]
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    public convenience init(
        providerAdapters: [any UsageProvider],
        clock: any UsageClock,
        initialSnapshots: [UsageSnapshot],
        initialAgents: [AgentSession] = []
    ) throws(AppModelConfigurationError) {
        let configuration = try Self.validateConfiguration(
            providerAdapters: providerAdapters,
            initialSnapshots: initialSnapshots
        )
        self.init(
            configuration: configuration,
            clock: clock,
            initialAgents: initialAgents
        )
    }

    private init(
        configuration: ValidatedAppModelConfiguration,
        clock: any UsageClock,
        initialAgents: [AgentSession]
    ) {
        self.clock = clock
        activityCutoff = clock.now()
        providerAdapters = configuration.providerAdapters
        providers = configuration.initialSnapshots
        displayedProviderID = Self.displayedProvider(
            snapshots: configuration.initialSnapshots,
            lastActivity: [:],
            previous: nil
        )
        connectionStates = configuration.connectionStates
        lastUpdatedAt = configuration.initialSnapshots.map(\.capturedAt).max() ?? clock.now()
        agents = initialAgents
    }

    static func empty(
        clock: any UsageClock,
        initialAgents: [AgentSession] = []
    ) -> AppModel {
        AppModel(
            configuration: ValidatedAppModelConfiguration(
                providerAdapters: [],
                initialSnapshots: [],
                connectionStates: [:]
            ),
            clock: clock,
            initialAgents: initialAgents
        )
    }

    public var prioritizedProviders: [ProviderUsage] {
        providers.sorted {
            if $0.priorityScore == $1.priorityScore {
                return $0.id.rawValue < $1.id.rawValue
            }
            return $0.priorityScore > $1.priorityScore
        }
    }

    public var activeAgents: [AgentSession] {
        agents.filter { [.running, .waitingForApproval, .waitingForInput].contains($0.status) }
    }

    public var attentionAgent: AgentSession? {
        agents.first { $0.status == .failed }
            ?? agents.first { $0.status == .waitingForApproval }
            ?? agents.first { $0.status == .waitingForInput }
    }

    public var displayedSnapshot: UsageSnapshot? {
        providers.first { $0.id == displayedProviderID }
    }

    public var configuredProviderIDs: [ProviderID] {
        ProviderID.allCases.filter { id in providerAdapters.contains { $0.id == id } }
    }

    /// Providers worth a card: every configured one except those whose CLI
    /// is not installed, so someone who only uses Codex (or only Claude) sees
    /// just that. Empty when none is installed.
    public var visibleProviderIDs: [ProviderID] {
        configuredProviderIDs.filter { id in
            snapshot(for: id) != nil || issues[id] != .notInstalled
        }
    }

    /// The provider the pill represents, even before any reading exists.
    public var pillProviderID: ProviderID? {
        displayedProviderID ?? visibleProviderIDs.first
    }

    /// "Will it last?" for a provider's card, from its recent official
    /// readings; nil when there is no recent use to project.
    func forecast(for provider: ProviderID) -> UsageForecast? {
        guard let snapshot = snapshot(for: provider), snapshot.freshness == .fresh else { return nil }
        return forecaster.headline(for: snapshot, now: clock.now())
    }

    public func snapshot(for provider: ProviderID) -> UsageSnapshot? {
        providers.first { $0.id == provider }
    }

    public func freshness(for provider: ProviderID) -> DataFreshness {
        providers.first(where: { $0.id == provider })?.freshness ?? .unavailable
    }

    public func togglePulse() {
        isPulseOpen.toggle()
    }

    public func closePulse() {
        isPulseOpen = false
        expandedProvider = nil
    }

    public func toggleProviderDetails(_ provider: ProviderID) {
        expandedProvider = expandedProvider == provider ? nil : provider
    }

    public func refreshUsage() async {
        invalidateRefresh()
        let generation = refreshGeneration
        let adaptersToRefresh = providerAdapters

        var connectingStates = connectionStates
        for adapter in adaptersToRefresh {
            connectingStates[adapter.id] = .connecting
        }
        connectionStates = connectingStates

        let task = Task { [weak self] in
            let results = await Self.fetchAll(adaptersToRefresh)
            guard !Task.isCancelled, let self else { return }
            self.applyRefreshResults(results, generation: generation)
        }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        if Task.isCancelled {
            cancelRefreshIfCurrent(generation)
        }
    }

    /// Refreshes one provider without cancelling a refresh in progress, for
    /// cheap sources that change often (Claude's status line record).
    public func refreshUsage(for provider: ProviderID) async {
        guard let adapter = providerAdapters.first(where: { $0.id == provider }) else { return }
        let results = await Self.fetchAll([adapter])
        guard !Task.isCancelled else { return }
        merge(results)
    }

    /// Forgets a provider's reading, for example after the user disconnects it.
    public func clearUsage(for provider: ProviderID) {
        providers.removeAll { $0.id == provider }
        lastActivity[provider] = nil
        issues[provider] = nil
        connectionStates[provider] = .disconnected
        displayedProviderID = Self.displayedProvider(
            snapshots: providers,
            lastActivity: lastActivity,
            previous: displayedProviderID == provider ? nil : displayedProviderID
        )
    }

    public func suspendRefresh() {
        invalidateRefresh()
        providers = providers.map { snapshot in
            var stale = snapshot
            stale.freshness = .stale
            return stale
        }
        connectionStates = connectionStates.mapValues { _ in .disconnected }
    }

    public func stop() {
        invalidateRefresh()
        connectionStates = connectionStates.mapValues { _ in .disconnected }
    }

    private func invalidateRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func cancelRefreshIfCurrent(_ generation: Int) {
        guard generation == refreshGeneration else { return }
        invalidateRefresh()
        connectionStates = connectionStates.mapValues { state in
            state == .connecting ? .disconnected : state
        }
    }

    private func applyRefreshResults(_ results: [RefreshResult], generation: Int) {
        guard generation == refreshGeneration else { return }
        merge(results)
        refreshTask = nil
    }

    private func merge(_ results: [RefreshResult]) {
        var snapshotsByID: [ProviderID: UsageSnapshot] = [:]
        for snapshot in providers {
            snapshotsByID[snapshot.id] = snapshot
        }
        var newConnectionStates = connectionStates
        var newIssues = issues
        var successfulCapturedDates: [Date] = []

        let now = clock.now()
        for result in results {
            if let snapshot = result.snapshot {
                let previous = snapshotsByID[result.id]
                newConnectionStates[result.id] = .connected
                newIssues[result.id] = nil
                // A slower refresh can finish after a newer single-provider one.
                if let previous, previous.capturedAt > snapshot.capturedAt { continue }
                if let activity = Self.activity(previous: previous, next: snapshot, now: now),
                   activity > activityCutoff,
                   activity > (lastActivity[result.id] ?? .distantPast) {
                    lastActivity[result.id] = activity
                }
                snapshotsByID[result.id] = snapshot
                forecaster.record(snapshot)
                successfulCapturedDates.append(snapshot.capturedAt)
            } else if var previous = snapshotsByID[result.id] {
                previous.freshness = .stale
                snapshotsByID[result.id] = previous
                newConnectionStates[result.id] = .failed
            } else {
                newConnectionStates[result.id] = .failed
            }
        }

        for result in results where result.snapshot == nil {
            newIssues[result.id] = result.issue ?? .unavailable
        }
        providers = ProviderID.allCases.compactMap { snapshotsByID[$0] }
        connectionStates = newConnectionStates
        if newIssues != issues { issues = newIssues }
        if let newestCapture = successfulCapturedDates.max() {
            lastUpdatedAt = newestCapture
        }
        let displayed = Self.displayedProvider(
            snapshots: providers,
            lastActivity: lastActivity,
            previous: displayedProviderID
        )
        if displayed != displayedProviderID { displayedProviderID = displayed }
    }

    /// When `next` shows new use compared with `previous`. Providers that
    /// report their own activity time win; otherwise any window whose usage
    /// rose counts as use observed now.
    static func activity(previous: UsageSnapshot?, next: UsageSnapshot, now: Date) -> Date? {
        if let previous {
            for window in next.windows {
                if let old = previous.windows.first(where: { $0.id == window.id }),
                   window.usedPercent > old.usedPercent {
                    return max(now, next.lastActivityAt ?? now)
                }
            }
        }
        return next.lastActivityAt
    }

    static func displayedProvider(
        snapshots: [UsageSnapshot],
        lastActivity: [ProviderID: Date],
        previous: ProviderID?
    ) -> ProviderID? {
        let available = Set(snapshots.map(\.id))
        if let recent = lastActivity.filter({ available.contains($0.key) })
            .max(by: { $0.value < $1.value })?.key {
            return recent
        }
        if let previous, available.contains(previous) { return previous }
        return snapshots.max { lhs, rhs in
            lhs.priorityScore == rhs.priorityScore
                ? lhs.id.rawValue > rhs.id.rawValue
                : lhs.priorityScore < rhs.priorityScore
        }?.id
    }

    private static func validateConfiguration(
        providerAdapters: [any UsageProvider],
        initialSnapshots: [UsageSnapshot]
    ) throws(AppModelConfigurationError) -> ValidatedAppModelConfiguration {
        var adapterIDs = Set<ProviderID>()
        var connectionStates: [ProviderID: ProviderConnectionState] = [:]

        for adapter in providerAdapters {
            guard adapterIDs.insert(adapter.id).inserted else {
                throw AppModelConfigurationError.duplicateProviderAdapter(adapter.id)
            }
            connectionStates[adapter.id] = .disconnected
        }

        var snapshotIDs = Set<ProviderID>()
        for snapshot in initialSnapshots {
            guard snapshotIDs.insert(snapshot.id).inserted else {
                throw AppModelConfigurationError.duplicateInitialSnapshot(snapshot.id)
            }
            guard adapterIDs.contains(snapshot.id) else {
                throw AppModelConfigurationError.snapshotWithoutAdapter(snapshot.id)
            }
            connectionStates[snapshot.id] = .connected
        }

        return ValidatedAppModelConfiguration(
            providerAdapters: providerAdapters,
            initialSnapshots: initialSnapshots,
            connectionStates: connectionStates
        )
    }

    nonisolated private static func fetchAll(
        _ providerAdapters: [any UsageProvider]
    ) async -> [RefreshResult] {
        await withTaskGroup(of: RefreshResult.self) { group in
            for adapter in providerAdapters {
                group.addTask {
                    do {
                        let snapshot = try await adapter.fetchUsage()
                        guard snapshot.id == adapter.id else {
                            return RefreshResult(id: adapter.id, snapshot: nil)
                        }
                        return RefreshResult(
                            id: adapter.id,
                            snapshot: snapshot
                        )
                    } catch {
                        return RefreshResult(
                            id: adapter.id,
                            snapshot: nil,
                            issue: (error as? any ProviderIssueReporting)?.issue ?? .unavailable
                        )
                    }
                }
            }

            var results: [RefreshResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}

private struct ValidatedAppModelConfiguration {
    let providerAdapters: [any UsageProvider]
    let initialSnapshots: [UsageSnapshot]
    let connectionStates: [ProviderID: ProviderConnectionState]
}

private struct RefreshResult: Sendable {
    let id: ProviderID
    let snapshot: UsageSnapshot?
    var issue: ProviderIssue? = nil
}
