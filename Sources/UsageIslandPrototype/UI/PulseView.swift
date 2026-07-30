import SwiftUI

public struct PulseView: View {
  @ObservedObject private var model: AppModel
  private let collapsedHeight: CGFloat
  private let expandedHeight: CGFloat
  private let drawsSurface: Bool

  public init(
    model: AppModel,
    collapsedHeight: CGFloat = 236,
    expandedHeight: CGFloat = 316,
    drawsSurface: Bool = true
  ) {
    self.model = model
    self.collapsedHeight = collapsedHeight
    self.expandedHeight = expandedHeight
    self.drawsSurface = drawsSurface
  }

  private var visibleHeight: CGFloat {
    model.expandedProvider == nil ? collapsedHeight : expandedHeight
  }

  @ViewBuilder
  public var body: some View {
    if drawsSurface {
      ZStack(alignment: .top) {
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: 22,
          bottomTrailingRadius: 22,
          topTrailingRadius: 0,
          style: .continuous
        )
        .fill(UsageIslandTokens.islandBackground)
        .frame(height: visibleHeight, alignment: .top)

        content
          .frame(height: visibleHeight, alignment: .top)
          .clipped()
      }
      .frame(height: expandedHeight, alignment: .top)
      .clipped()
    } else {
      content
        .frame(height: visibleHeight, alignment: .top)
        .clipped()
    }
  }

  private var content: some View {
    VStack(spacing: 0) {
      VStack(spacing: 2) {
        ForEach(model.prioritizedProviders) { provider in
          providerRow(provider)
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)

      agentSummary
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
        .padding(.horizontal, 18)
        .padding(.top, 9)

      Spacer(minLength: 5)

      footer
    }
    .frame(height: visibleHeight, alignment: .top)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Text("Actualizado ahora")
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(UsageIslandTokens.secondaryText)
        .lineLimit(1)

      Spacer(minLength: 10)

      Button {
        model.applyScenario(model.scenario)
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help("Actualizar")

      Button {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
      } label: {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.plain)
      .help("Preferencias")
    }
    .font(.system(size: 11.5, weight: .semibold))
    .foregroundStyle(UsageIslandTokens.secondaryText)
    .padding(.horizontal, 17)
    .padding(.bottom, 15)
  }

  @ViewBuilder
  private func providerRow(_ provider: ProviderUsage) -> some View {
    Button {
      withAnimation(UsageIslandTokens.detailMotion) {
        model.toggleProviderDetails(provider.id)
      }
    } label: {
      VStack(spacing: 0) {
        providerSummary(provider)
          .padding(.horizontal, 8)
          .padding(.vertical, 8)

        if model.expandedProvider == provider.id {
          expandedDetails(provider)
            .transition(.opacity)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(Color.white.opacity(model.expandedProvider == provider.id ? 0.055 : 0))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func providerSummary(_ provider: ProviderUsage) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Text(provider.id.compactSymbol)
        .font(.system(size: 12.5, weight: .semibold))
        .frame(width: 20, alignment: .center)

      VStack(alignment: .leading, spacing: 2) {
        Text(provider.id.displayName)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(UsageIslandTokens.primaryText)
          .lineLimit(1)
          .minimumScaleFactor(0.90)

        if let weekly = provider.weeklyRemainingPercent {
          Text("Semana \(weekly)%")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(UsageIslandTokens.secondaryText)
            .lineLimit(1)
        } else {
          Text(" ")
            .font(.system(size: 10))
        }
      }
      .frame(width: 120, alignment: .leading)

      Group {
        if let spend = UsageFormatting.currency(provider.weeklySpend) {
          Text(spend)
        } else {
          Text("")
        }
      }
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(UsageIslandTokens.secondaryText)
      .monospacedDigit()
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .frame(width: 64, alignment: .trailing)

      Text("\(provider.shortWindow.remainingPercent)%")
        .font(.system(size: 16.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(UsageIslandTokens.usageColor(for: provider.shortWindow.remainingPercent))
        .lineLimit(1)
        .frame(width: 58, alignment: .trailing)

      Text(UsageFormatting.resetText(until: provider.shortWindow.resetsAt))
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(UsageIslandTokens.secondaryText)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(width: 64, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func expandedDetails(_ provider: ProviderUsage) -> some View {
    VStack(spacing: 6) {
      detailLine("Cinco horas", value: "\(provider.shortWindow.remainingPercent)% restante")
      if let weekly = provider.weeklyRemainingPercent {
        detailLine("Semana", value: "\(weekly)% restante")
      }
      if let spend = UsageFormatting.currency(provider.weeklySpend) {
        detailLine("Gasto semanal", value: spend)
      }
      detailLine("Fuente", value: sourceName(for: provider.id))
    }
    .font(.system(size: 9.8, weight: .medium))
    .padding(.leading, 37)
    .padding(.trailing, 14)
    .padding(.bottom, 10)
  }

  private func detailLine(_ title: String, value: String) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(UsageIslandTokens.secondaryText)
        .lineLimit(1)

      Spacer(minLength: 12)

      Text(value)
        .foregroundStyle(UsageIslandTokens.primaryText.opacity(0.82))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .monospacedDigit()
    }
  }

  private var agentSummary: some View {
    Group {
      if let agent = model.attentionAgent {
        HStack(spacing: 8) {
          Image(systemName: agent.status == .failed ? "xmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(agent.status == .failed ? UsageIslandTokens.critical : UsageIslandTokens.warning)

          VStack(alignment: .leading, spacing: 1) {
            Text(agent.status == .failed ? "\(agent.provider.displayName) encontró un error" : "\(agent.provider.displayName) espera aprobación")
              .font(.system(size: 10.8, weight: .semibold))
              .foregroundStyle(UsageIslandTokens.primaryText)
              .lineLimit(1)

            Text("\(agent.source) · \(agent.project)")
              .font(.system(size: 9.6, weight: .medium))
              .foregroundStyle(UsageIslandTokens.secondaryText)
              .lineLimit(1)
          }
        }
        .fixedSize(horizontal: true, vertical: false)
      } else if !model.activeAgents.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "bolt.fill")
          Text("\(model.activeAgents.count) agentes activos")
            .monospacedDigit()
        }
        .font(.system(size: 10.8, weight: .semibold))
        .foregroundStyle(UsageIslandTokens.primaryText)
        .fixedSize(horizontal: true, vertical: false)
      } else {
        Text("Sin agentes activos")
          .font(.system(size: 10.8, weight: .medium))
          .foregroundStyle(UsageIslandTokens.secondaryText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func sourceName(for provider: ProviderID) -> String {
    switch provider {
    case .claude: "Claude OAuth"
    case .codex: "Codex app-server"
    case .openCodeGo: "OpenCode Web · Experimental"
    }
  }
}
