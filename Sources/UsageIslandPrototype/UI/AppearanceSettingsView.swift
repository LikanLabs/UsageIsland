import SwiftUI

/// Settings live inside the same status-level panel as usage.
struct AppearanceSettingsView: View {
    @ObservedObject var preferences: AppPreferences = .shared
    @ObservedObject var claude: ClaudeConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                label(preferences.text("Position", "Posición"))
                Picker(preferences.text("Position", "Posición"), selection: $preferences.position) {
                    Text(preferences.text("Left", "Izquierda")).tag(EdgePosition.left)
                    Text(preferences.text("Right", "Derecha")).tag(EdgePosition.right)
                    Text(preferences.text("Notch / Top", "Notch / Arriba")).tag(EdgePosition.top)
                }.pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                label(preferences.text("Auto-hide", "Ocultar automáticamente"))
                Spacer()
                Toggle(preferences.text("Auto-hide", "Ocultar automáticamente"), isOn: $preferences.autoHide)
                    .toggleStyle(PanelSwitchStyle())
            }
            HStack {
                label(preferences.text("Show available %", "Mostrar % disponible"))
                Spacer()
                Toggle(preferences.text("Show available percentage", "Mostrar porcentaje disponible"), isOn: Binding(
                    get: { !preferences.showsConsumedPercent },
                    set: { preferences.showsConsumedPercent = !$0 }
                ))
                    .toggleStyle(PanelSwitchStyle())
            }
            HStack {
                label(preferences.text("Language", "Idioma"))
                Spacer()
                Picker(preferences.text("Language", "Idioma"), selection: $preferences.language) {
                    Text(preferences.text("Automatic", "Automático")).tag(AppLanguage.system)
                    Text("Español").tag(AppLanguage.spanish)
                    Text("English").tag(AppLanguage.english)
                }.labelsHidden().fixedSize()
            }
            VStack(spacing: 6) {
                HStack {
                    label(preferences.text("Size", "Tamaño"))
                    Spacer()
                    Text("\(Int((preferences.scale * 100).rounded()))%")
                        .font(.system(size: 12)).monospacedDigit()
                }
                Slider(value: $preferences.scale, in: AppPreferences.scaleRange, step: 0.05) {
                    Text(preferences.text("Size", "Tamaño"))
                }.labelsHidden().controlSize(.small)
            }
            claudeRow
            HStack {
                Text(preferences.text("Saved automatically", "Se guarda automáticamente"))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button("100%") { preferences.scale = 1 }
                    .font(.system(size: 11)).buttonStyle(.plain)
                    .accessibilityLabel(preferences.text("Restore original size", "Restaurar tamaño original"))
            }
        }.tint(.white)
    }

    /// Optional: the status line bridge updates Claude instantly after each
    /// terminal reply. Claude usage works without it.
    private var claudeRow: some View {
        HStack(spacing: 6) {
            ProviderMark(provider: .claude, color: .white.opacity(0.7)).frame(width: 12, height: 12)
            label(preferences.text("Claude in terminal", "Claude en terminal"))
                .help(preferences.text("Optional. Updates Claude usage right after each reply in Claude Code in the terminal.",
                                       "Opcional. Actualiza el consumo de Claude justo después de cada respuesta en Claude Code en la terminal."))
            Spacer()
            switch claude.status {
            case .notInstalled:
                panelButton(preferences.text("Connect", "Conectar")) { claude.connect() }
                    .help(preferences.text("Adds a status line to Claude Code that shares its plan usage with Usage Island.",
                                           "Añade una barra de estado a Claude Code que comparte su consumo del plan con Usage Island."))
            case .installed:
                Text(preferences.text("Connected", "Conectado"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                panelButton(preferences.text("Disconnect", "Desconectar")) { claude.disconnect() }
            case .otherStatusLine:
                note(preferences.text("Custom status line in use", "Ya usas otra barra de estado"))
                    .help(preferences.text("Usage Island never replaces your own Claude Code status line.",
                                           "Usage Island nunca reemplaza tu propia barra de estado de Claude Code."))
            case .claudeNotFound:
                note(preferences.text("Not installed", "No instalado"))
            case .unreadableSettings:
                note(preferences.text("Settings file unreadable", "Ajustes ilegibles"))
            }
        }
        .frame(height: 24)
        .onAppear { claude.reloadStatus() }
    }

    private func panelButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
            .padding(.horizontal, 8).frame(height: 22)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
    }
}

/// Both switches share the panel's matte monochrome appearance on every macOS.
private struct PanelSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Color.white.opacity(0.9) : Color.white.opacity(0.18))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? .black : .white.opacity(0.85))
                        .frame(width: 14, height: 14).padding(2)
                }
                .frame(width: 30, height: 18)
                .frame(width: 34, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
