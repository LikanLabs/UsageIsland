import AppKit
import Combine
import Foundation

@MainActor
public final class AppModel: ObservableObject {
    @Published public var providers: [ProviderUsage] = []
    @Published public var agents: [AgentSession] = []
    @Published public var leftMode: WingPresentationMode = .compact
    @Published public var rightMode: WingPresentationMode = .compact
    @Published public var requestedLayout: WingPresentationMode = .automatic
    @Published public var beaconPolicy: BeaconPolicy = .automatic
    @Published public var isPulseOpen = false
    @Published public var isPulsePresented = false
    @Published public var expandedProvider: ProviderID?
    @Published public var scenario: DemoScenario = .normal
    @Published public var lastUpdatedAt = Date.now
    @Published public var adaptiveSpacingIsTrusted = false
    @Published public var islandIsVisible = true

    public init() {
        applyScenario(.normal)
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
        self.scenario = scenario
        let now = Date.now

        switch scenario {
        case .normal:
            providers = [
                .init(id: .claude, shortWindow: .init(remainingPercent: 72, resetsAt: now.addingTimeInterval(3.3 * 3600)), weeklyRemainingPercent: 43, weeklySpend: 8.42, freshness: .fresh, isCurrentlyActive: true),
                .init(id: .codex, shortWindow: .init(remainingPercent: 48, resetsAt: now.addingTimeInterval(2.1 * 3600)), weeklyRemainingPercent: 61, weeklySpend: 6.20, freshness: .fresh, isCurrentlyActive: true),
                .init(id: .openCodeGo, shortWindow: .init(remainingPercent: 91, resetsAt: now.addingTimeInterval(4.6 * 3600)), weeklyRemainingPercent: 88, weeklySpend: 3.98, freshness: .fresh, isCurrentlyActive: false)
            ]
            agents = [
                .init(provider: .claude, status: .running, project: "api-server", source: "Terminal"),
                .init(provider: .codex, status: .running, project: "usage-island", source: "Paseo")
            ]

        case .critical:
            providers = [
                .init(id: .claude, shortWindow: .init(remainingPercent: 8, resetsAt: now.addingTimeInterval(42 * 60)), weeklyRemainingPercent: 29, weeklySpend: 16.12, freshness: .fresh, isCurrentlyActive: true),
                .init(id: .codex, shortWindow: .init(remainingPercent: 64, resetsAt: now.addingTimeInterval(3.8 * 3600)), weeklyRemainingPercent: 70, weeklySpend: 4.80, freshness: .fresh, isCurrentlyActive: false),
                .init(id: .openCodeGo, shortWindow: .init(remainingPercent: 87, resetsAt: now.addingTimeInterval(4.1 * 3600)), weeklyRemainingPercent: 81, weeklySpend: 4.10, freshness: .fresh, isCurrentlyActive: false)
            ]
            agents = [.init(provider: .claude, status: .running, project: "agent-runtime", source: "Orca")]

        case .waiting:
            providers = [
                .init(id: .claude, shortWindow: .init(remainingPercent: 68, resetsAt: now.addingTimeInterval(3 * 3600)), weeklyRemainingPercent: 44, weeklySpend: 8.90, freshness: .fresh, isCurrentlyActive: false),
                .init(id: .codex, shortWindow: .init(remainingPercent: 41, resetsAt: now.addingTimeInterval(1.8 * 3600)), weeklyRemainingPercent: 59, weeklySpend: 7.10, freshness: .fresh, isCurrentlyActive: true),
                .init(id: .openCodeGo, shortWindow: .init(remainingPercent: 90, resetsAt: now.addingTimeInterval(4.5 * 3600)), weeklyRemainingPercent: 86, weeklySpend: 3.98, freshness: .fresh, isCurrentlyActive: false)
            ]
            agents = [
                .init(provider: .claude, status: .running, project: "api-server", source: "Paseo"),
                .init(provider: .codex, status: .waitingForApproval, project: "usage-island", source: "Orca")
            ]

        case .error:
            providers = [
                .init(id: .claude, shortWindow: .init(remainingPercent: 70, resetsAt: now.addingTimeInterval(3.2 * 3600)), weeklyRemainingPercent: 42, weeklySpend: 9.10, freshness: .stale, isCurrentlyActive: false),
                .init(id: .codex, shortWindow: .init(remainingPercent: 48, resetsAt: now.addingTimeInterval(2.1 * 3600)), weeklyRemainingPercent: 61, weeklySpend: 6.20, freshness: .fresh, isCurrentlyActive: false),
                .init(id: .openCodeGo, shortWindow: .init(remainingPercent: 91, resetsAt: now.addingTimeInterval(4.6 * 3600)), weeklyRemainingPercent: 88, weeklySpend: 3.98, freshness: .unavailable, isCurrentlyActive: false)
            ]
            agents = [.init(provider: .codex, status: .failed, project: "usage-island", source: "Paseo")]
        }

        lastUpdatedAt = now
    }
}
