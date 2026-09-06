import SwiftUI

/// Settings live inside the same status-level panel as usage.
struct AppearanceSettingsView: View {
    @ObservedObject var preferences: AppPreferences = .shared

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
