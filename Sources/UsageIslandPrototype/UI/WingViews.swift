import SwiftUI

public struct UsageWingView: View {
    @ObservedObject private var model: AppModel
    private let mode: WingPresentationMode
    private let onOpen: () -> Void
    private let drawsSurface: Bool

    private var effectiveMode: WingPresentationMode {
        mode == .automatic ? model.leftMode : mode
    }

    public init(
        model: AppModel,
        mode: WingPresentationMode,
        drawsSurface: Bool = true,
        onOpen: @escaping () -> Void
    ) {
        self.model = model
        self.mode = mode
        self.drawsSurface = drawsSurface
        self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                ForEach(visibleProviders) { provider in
                    providerItem(provider)
                    if provider.id != visibleProviders.last?.id, effectiveMode != .minimal {
                        Rectangle()
                            .fill(UsageIslandTokens.divider)
                            .frame(width: 1, height: 12)
                    }
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .background(drawsSurface ? UsageIslandTokens.islandBackground : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(.rect(bottomLeadingRadius: drawsSurface ? 14 : 0))
        .accessibilityLabel("Abrir Usage Island")
    }

    private var visibleProviders: [ProviderUsage] {
        let prioritized = model.prioritizedProviders
        switch effectiveMode {
        case .full, .compact, .automatic:
            return Array(prioritized.prefix(3))
        case .minimal:
            return Array(prioritized.prefix(1))
        case .hidden:
            return []
        }
    }

    @ViewBuilder
    private func providerItem(_ provider: ProviderUsage) -> some View {
        HStack(spacing: 4) {
            if effectiveMode == .full {
                Text(provider.id.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UsageIslandTokens.secondaryText)
                    .lineLimit(1)
            } else {
                Text(provider.id.compactSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UsageIslandTokens.primaryText)
            }

            Text("\(provider.shortWindow.remainingPercent)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(UsageIslandTokens.usageColor(for: provider.shortWindow.remainingPercent))

            if provider.freshness == .stale {
                Circle()
                    .fill(UsageIslandTokens.warning)
                    .frame(width: 3, height: 3)
            }
        }
        .fixedSize()
    }
}

public struct AgentWingView: View {
    @ObservedObject private var model: AppModel
    private let mode: WingPresentationMode
    private let onOpen: () -> Void
    private let drawsSurface: Bool

    private var effectiveMode: WingPresentationMode {
        mode == .automatic ? model.rightMode : mode
    }

    public init(
        model: AppModel,
        mode: WingPresentationMode,
        drawsSurface: Bool = true,
        onOpen: @escaping () -> Void
    ) {
        self.model = model
        self.mode = mode
        self.drawsSurface = drawsSurface
        self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                if let attention = model.attentionAgent {
                    attentionView(attention)
                } else if !model.activeAgents.isEmpty {
                    runningView
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(drawsSurface ? UsageIslandTokens.islandBackground : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(.rect(bottomTrailingRadius: drawsSurface ? 14 : 0))
        .accessibilityLabel("Abrir estado de agentes")
    }

    private var runningView: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("\(model.activeAgents.count)")
                .monospacedDigit()
            if effectiveMode == .full {
                Text("activos")
                    .foregroundStyle(UsageIslandTokens.secondaryText)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(UsageIslandTokens.primaryText)
        .fixedSize()
    }

    private func attentionView(_ agent: AgentSession) -> some View {
        HStack(spacing: 5) {
            Image(systemName: agent.status == .failed ? "xmark" : "exclamationmark")
                .font(.system(size: 9, weight: .bold))

            if effectiveMode == .full {
                Text(agent.provider.displayName)
                Text(agent.status == .failed ? "error" : "espera")
                    .foregroundStyle(UsageIslandTokens.secondaryText)
            } else {
                Text("1")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(agent.status == .failed ? UsageIslandTokens.critical : UsageIslandTokens.warning)
        .fixedSize()
    }
}
