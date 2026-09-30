import SwiftUI

/// Settings live inside the same glass panel as usage and use native
/// controls, which adopt Liquid Glass on macOS 26 and later.
struct AppearanceSettingsView: View {
    @ObservedObject var preferences: AppPreferences = .shared
    @ObservedObject var claude: ClaudeConnection
    @ObservedObject var system: SystemIntegration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                label(preferences.text("Position", "Posición"))
                Picker(preferences.text("Position", "Posición"), selection: $preferences.position) {
                    Text(preferences.text("Left", "Izquierda")).tag(EdgePosition.left)
                    Text(preferences.text("Notch", "Notch")).tag(EdgePosition.top)
                    Text(preferences.text("Right", "Derecha")).tag(EdgePosition.right)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            group {
                toggleRow(preferences.text("Auto-hide", "Ocultar automáticamente"), isOn: $preferences.autoHide)
                divider
                toggleRow(preferences.text("Show available %", "Mostrar % disponible"), isOn: Binding(
                    get: { !preferences.showsConsumedPercent },
                    set: { preferences.showsConsumedPercent = !$0 }
                ))
                divider
                HStack {
                    label(preferences.text("Language", "Idioma"))
                    Spacer()
                    Picker(preferences.text("Language", "Idioma"), selection: $preferences.language) {
                        Text(preferences.text("Automatic", "Automático")).tag(AppLanguage.system)
                        Text("Español").tag(AppLanguage.spanish)
                        Text("English").tag(AppLanguage.english)
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                }
                .frame(height: 26)
            }
            group {
                HStack {
                    label(preferences.text("Size", "Tamaño"))
                    Spacer()
                    Button("\(Int((preferences.scale * 100).rounded()))%") { preferences.scale = 1 }
                        .font(.system(size: 12)).monospacedDigit().buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(preferences.text("Restore original size", "Restaurar tamaño original"))
                        .accessibilityLabel(preferences.text("Restore original size", "Restaurar tamaño original"))
                }
                Slider(value: $preferences.scale, in: AppPreferences.scaleRange, step: 0.05) {
                    Text(preferences.text("Size", "Tamaño"))
                }
                .labelsHidden().controlSize(.small)
            }
            group {
                if system.loginItem != .unavailable {
                    toggleRow(preferences.text("Open at login", "Abrir al iniciar sesión"), isOn: Binding(
                        get: { system.opensAtLogin },
                        set: { system.setOpensAtLogin($0) }
                    ))
                    if system.loginItem == .requiresApproval {
                        noteButton(preferences.text("Allow it in System Settings", "Permítelo en Ajustes del Sistema")) {
                            system.openLoginItemsSettings()
                        }
                    }
                    divider
                }
                toggleRow(preferences.text("Alert when running low", "Avisar cuando quede poco"), isOn: $preferences.usageAlerts)
                    .help(preferences.text("Notifies at 20 %, 10 % and 0 % left, and when a low limit resets.",
                                           "Avisa al quedar 20 %, 10 % y 0 %, y cuando un límite bajo se reinicia."))
                if preferences.usageAlerts, system.notificationsDenied {
                    noteButton(preferences.text("Notifications are off in System Settings", "Las notificaciones están desactivadas en Ajustes")) {
                        system.openNotificationSettings()
                    }
                }
            }
            group { claudeRow }
        }
        .onAppear { system.refresh() }
    }

    private func noteButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.up.forward.app")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
    }

    /// Optional: the status line bridge updates Claude instantly after each
    /// terminal reply. Claude usage works without it.
    private var claudeRow: some View {
        HStack(spacing: 7) {
            ProviderMark(provider: .claude, color: IslandPalette.claude).frame(width: 13, height: 13)
            VStack(alignment: .leading, spacing: 1) {
                label(preferences.text("Claude in terminal", "Claude en terminal"))
                Text(preferences.text("Instant updates", "Actualización instantánea"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .help(preferences.text("Optional. Updates Claude usage right after each reply in Claude Code in the terminal.",
                                   "Opcional. Actualiza el consumo de Claude justo después de cada respuesta en Claude Code en la terminal."))
            Spacer()
            switch claude.status {
            case .notInstalled:
                Button(preferences.text("Connect", "Conectar")) { claude.connect() }
                    .islandTextButtonStyle().controlSize(.small)
            case .installed:
                Button(preferences.text("Disconnect", "Desconectar")) { claude.disconnect() }
                    .islandTextButtonStyle().controlSize(.small)
            case .otherStatusLine:
                note(preferences.text("Own status line", "Barra propia"))
                    .help(preferences.text("Usage Island never replaces your own Claude Code status line.",
                                           "Usage Island nunca reemplaza tu propia barra de estado de Claude Code."))
            case .claudeNotFound:
                note(preferences.text("Not installed", "No instalado"))
            case .unreadableSettings:
                note(preferences.text("Settings unreadable", "Ajustes ilegibles"))
            }
        }
        .onAppear { claude.reloadStatus() }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(IslandPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(IslandPalette.cardEdge, lineWidth: 0.5))
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { label(title) }
            .toggleStyle(.switch).controlSize(.small)
            .frame(height: 22)
    }

    private var divider: some View {
        Rectangle().fill(IslandPalette.cardEdge).frame(height: 0.5)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium))
    }
}
