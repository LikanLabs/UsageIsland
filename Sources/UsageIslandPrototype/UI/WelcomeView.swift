import SwiftUI

/// The one-time welcome page inside the panel: what the app does, which
/// tools it found, where to put the pill, and the two options worth turning
/// on. macOS asks for notification permission only after "Get started".
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var system: SystemIntegration
    var onFinish: () -> Void

    @State private var opensAtLogin = true
    @State private var alerts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preferences.text(
                "Shows how much of your Codex and Claude Code limits is left, right by the notch. It updates by itself; there is nothing to set up.",
                "Muestra cuánto te queda de Codex y Claude Code, junto al notch. Se actualiza solo; no hay nada que configurar."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            card {
                ForEach(model.configuredProviderIDs) { provider in
                    providerRow(provider)
                    if provider != model.configuredProviderIDs.last { divider }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(preferences.text("Where should it go?", "¿Dónde la quieres?")).font(.system(size: 12, weight: .medium))
                Picker(preferences.text("Position", "Posición"), selection: $preferences.position) {
                    Text(preferences.text("Left", "Izquierda")).tag(EdgePosition.left)
                    Text(preferences.text("Notch", "Notch")).tag(EdgePosition.top)
                    Text(preferences.text("Right", "Derecha")).tag(EdgePosition.right)
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            card {
                if system.loginItem != .unavailable {
                    Toggle(isOn: $opensAtLogin) { label(preferences.text("Open at login", "Abrir al iniciar sesión")) }
                        .toggleStyle(.switch).controlSize(.small)
                    divider
                }
                Toggle(isOn: $alerts) { label(preferences.text("Alert me when running low", "Avisarme cuando quede poco")) }
                    .toggleStyle(.switch).controlSize(.small)
            }

            Spacer(minLength: 0)

            Button(action: finish) {
                Text(preferences.text("Get started", "Empezar"))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 30)
            }
            .islandProminentButtonStyle()
            .keyboardShortcut(.defaultAction)
        }
    }

    private func finish() {
        if system.loginItem != .unavailable, opensAtLogin != system.opensAtLogin {
            system.setOpensAtLogin(opensAtLogin)
        }
        preferences.usageAlerts = alerts
        preferences.hasCompletedOnboarding = true
        if alerts { system.requestNotificationPermission() }
        onFinish()
    }

    private func providerRow(_ provider: ProviderID) -> some View {
        let state = detection(provider)
        return HStack(spacing: 8) {
            ProviderMark(provider: provider, color: IslandPalette.brand(provider)).frame(width: 14, height: 14)
            Text(provider == .codex ? "Codex" : "Claude Code").font(.system(size: 12, weight: .medium))
            Spacer()
            Image(systemName: state.symbol).foregroundStyle(state.color).font(.system(size: 11, weight: .semibold))
            Text(state.text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }

    private func detection(_ provider: ProviderID) -> (symbol: String, color: Color, text: String) {
        if model.snapshot(for: provider) != nil {
            return ("checkmark.circle.fill", IslandPalette.level(0), preferences.text("Found", "Detectado"))
        }
        switch model.issues[provider] {
        case .notInstalled?:
            return ("minus.circle", .secondary, preferences.text("Not installed", "No instalado"))
        case .notSignedIn?:
            return ("exclamationmark.circle", .orange, preferences.text("Not signed in", "Sin sesión iniciada"))
        case .noPlanLimits?:
            return ("minus.circle", .secondary, preferences.text("No plan limits", "Sin límites de plan"))
        case .unavailable?:
            return ("exclamationmark.circle", .orange, preferences.text("Not available yet", "Aún no disponible"))
        case nil:
            return ("ellipsis.circle", .secondary, preferences.text("Looking…", "Buscando…"))
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IslandPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(IslandPalette.cardEdge, lineWidth: 0.5))
    }

    private var divider: some View {
        Rectangle().fill(IslandPalette.cardEdge).frame(height: 0.5)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium))
    }
}
