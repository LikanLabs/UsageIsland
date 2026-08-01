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
    @Published public var scenario: DemoScenario = .normal
    @Published public private(set) var lastUpdatedAt: Date
    @Published public var adaptiveSpacingIsTrusted = false
    @Published public var islandIsVisible = true

    private let clock: any UsageClock
    private var providerAdapters: [any UsageProvider]
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    public convenience init(
        providerAdapters: [any UsageProvider],
        clock: any UsageClock,
        initialSnapshots: [UsageSnapshot],
        initialAgents: [AgentSession]? = nil,
        initialScenario: DemoScenario = .normal
    ) throws(AppModelConfigurationError) {
        let configuration = try Self.validateConfiguration(
            providerAdapters: providerAdapters,
            initialSnapshots: initialSnapshots
        )
        self.init(
            configuration: configuration,
            clock: clock,
            initialAgents: initialAgents,
            initialScenario: initialScenario
        )
    }

    private init(
        configuration: ValidatedAppModelConfiguration,
        clock: any UsageClock,
        initialAgents: [AgentSession]?,
        initialScenario: DemoScenario
    ) {
        self.clock = clock
        providerAdapters = configuration.providerAdapters
        providers = configuration.initialSnapshots
        connectionStates = configuration.connectionStates
        scenario = initialScenario
        lastUpdatedAt = configuration.initialSnapshots.map(\.capturedAt).max() ?? clock.now()
        if let initialAgents {
            agents = initialAgents
        } else {
            applyAgents(for: initialScenario)
        }
    }

    static func empty(
        clock: any UsageClock,
        initialAgents: [AgentSession]? = nil,
        initialScenario: DemoScenario = .normal
    ) -> AppModel {
        AppModel(
            configuration: ValidatedAppModelConfiguration(
                providerAdapters: [],
                initialSnapshots: [],
                connectionStates: [:]
            ),
            clock: clock,
            initialAgents: initialAgents,
            initialScenario: initialScenario
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

    public func applyScenario(_ scenario: DemoScenario) {
        let snapshots = DemoUsageProvider.snapshots(for: scenario, clock: clock)
        let adapters = DemoUsageProvider.providerAdapters(for: scenario, clock: clock)
        guard let configuration = try? Self.validateConfiguration(
            providerAdapters: adapters,
            initialSnapshots: snapshots
        ) else {
            return
        }

        invalidateRefresh()
        self.scenario = scenario
        providerAdapters = configuration.providerAdapters
        providers = configuration.initialSnapshots
        connectionStates = configuration.connectionStates
        lastUpdatedAt = configuration.initialSnapshots.map(\.capturedAt).max() ?? clock.now()
        applyAgents(for: scenario)
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

    public func stop() {
        invalidateRefresh()
        connectionStates = connectionStates.mapValues { _ in .disconnected }
    }

    private func applyAgents(for scenario: DemoScenario) {
        let now = clock.now()

        switch scenario {
        case .normal:
            agents = [
                .init(provider: .claude, status: .running, project: "api-server", source: "Terminal", updatedAt: now),
                .init(provider: .codex, status: .running, project: "usage-island", source: "Paseo", updatedAt: now)
            ]

        case .critical:
            agents = [
                .init(provider: .claude, status: .running, project: "agent-runtime", source: "Orca", updatedAt: now)
            ]

        case .waiting:
            agents = [
                .init(provider: .claude, status: .running, project: "api-server", source: "Paseo", updatedAt: now),
                .init(provider: .codex, status: .waitingForApproval, project: "usage-island", source: "Orca", updatedAt: now)
            ]

        case .error:
            agents = [
                .init(provider: .codex, status: .failed, project: "usage-island", source: "Paseo", updatedAt: now)
            ]
        }
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

        var snapshotsByID: [ProviderID: UsageSnapshot] = [:]
        for snapshot in providers {
            snapshotsByID[snapshot.id] = snapshot
        }
        var newConnectionStates = connectionStates
        var successfulCapturedDates: [Date] = []

        for result in results {
            if let snapshot = result.snapshot {
                snapshotsByID[result.id] = snapshot
                newConnectionStates[result.id] = .connected
                successfulCapturedDates.append(snapshot.capturedAt)
            } else if var previous = snapshotsByID[result.id] {
                previous.freshness = .stale
                snapshotsByID[result.id] = previous
                newConnectionStates[result.id] = .failed
            } else {
                newConnectionStates[result.id] = .failed
            }
        }

        providers = ProviderID.allCases.compactMap { snapshotsByID[$0] }
        connectionStates = newConnectionStates
        if let newestCapture = successfulCapturedDates.max() {
            lastUpdatedAt = newestCapture
        }
        refreshTask = nil
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
                        return RefreshResult(id: adapter.id, snapshot: nil)
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
}
