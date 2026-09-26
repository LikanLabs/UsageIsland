import SwiftUI

enum CodexEdgeLayout {
    static let tabWidth: CGFloat = 72
    static let tabHeight: CGFloat = 100
    static let topWidth: CGFloat = 176
    // Keep the bridge close to the notch's roughly 32–38pt safe-area height.
    static let topHeight: CGFloat = 36
    static let detailWidth: CGFloat = 324
    static let detailHeight: CGFloat = 350
    static let gap: CGFloat = 8

    static func tabSize(_ position: EdgePosition) -> CGSize {
        position == .top ? CGSize(width: topWidth, height: topHeight) : CGSize(width: tabWidth, height: tabHeight)
    }

    static let sectionHeaderHeight: CGFloat = 26
    static let claudeHintHeight: CGFloat = 52

    /// Height of one provider's section body, excluding its header.
    static func sectionHeight(provider: ProviderID, snapshot: UsageSnapshot?) -> CGFloat {
        guard let snapshot else { return provider == .codex ? 100 : claudeHintHeight }
        return CGFloat(snapshot.windows.count) * 88 + (snapshot.freshness == .stale ? 28 : 0)
    }

    @MainActor
    static func panelHeight(settings: Bool, model: AppModel) -> CGFloat {
        if settings { return detailHeight }
        let sections = model.configuredProviderIDs
        let bodies = sections.reduce(CGFloat(0)) { $0 + sectionHeight(provider: $1, snapshot: model.snapshot(for: $1)) }
        let headers = sections.count > 1 ? CGFloat(sections.count) * sectionHeaderHeight : 0
        return 142 + bodies + headers
    }

    @MainActor
    static func envelopeHeight(model: AppModel) -> CGFloat {
        max(detailHeight, panelHeight(settings: false, model: model))
    }
}

private enum DockStyle {
    static let muted = Color.white.opacity(0.58)
    static func tint(_ used: Int) -> Color {
        switch UsageRingLevel(remainingPercent: 100 - used) {
        case .plenty: Color(red: 0.35, green: 0.85, blue: 0.62)
        case .moderate: Color(red: 0.96, green: 0.82, blue: 0.35)
        case .low: Color(red: 1, green: 0.59, blue: 0.28)
        case .critical: Color(red: 1, green: 0.33, blue: 0.35)
        }
    }
}

/// Flat at the physical edge; rounded only on the exposed side.
private struct AttachedPill: Shape {
    let position: EdgePosition
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = position == .top ? 10 : 17
        return UnevenRoundedRectangle(
            topLeadingRadius: position == .left || position == .top ? 0 : radius,
            bottomLeadingRadius: position == .left ? 0 : radius,
            bottomTrailingRadius: position == .right ? 0 : radius,
            topTrailingRadius: position == .right || position == .top ? 0 : radius
        ).path(in: rect)
    }
}

struct CodexEdgeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences = .shared
    var topWidth: CGFloat = CodexEdgeLayout.topWidth
    var topOverlap: CGFloat = 0
    var onOpen: () -> Void
    /// The pill follows the provider in use; the panel shows all of them.
    private var snapshot: UsageSnapshot? { model.displayedSnapshot }
    private var provider: ProviderID { model.displayedProviderID ?? .codex }

    var body: some View {
        Button(action: onOpen) {
            Group {
                if preferences.position == .top {
                    HStack(spacing: 8) {
                        logoRing(size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            percentage.font(.system(size: 15, weight: .semibold, design: .rounded))
                            Text(percentLabel).font(.system(size: 8)).foregroundStyle(DockStyle.muted)
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        logoRing(size: 46)
                        percentage.font(.system(size: 19, weight: .semibold, design: .rounded))
                    }
                }
            }
            .frame(width: preferences.position == .top ? topWidth : CodexEdgeLayout.tabWidth,
                   height: CodexEdgeLayout.tabSize(preferences.position).height)
            // Reserve the overlap above the content: only this black background
            // enters the camera cutout; the logo and percentage start below it.
            .padding(.top, preferences.position == .top ? topOverlap : 0)
            .background(.black, in: AttachedPill(position: preferences.position))
            .foregroundStyle(.white)
            .contentShape(AttachedPill(position: preferences.position))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(model.isPulseOpen ? preferences.text("Details open", "Detalle abierto") : preferences.text("Details closed", "Detalle cerrado"))
        .accessibilityHint(snapshot?.freshness == .stale ? preferences.text("Last known usage. Update pending.", "Último consumo conocido. Pendiente de actualizar.") : "")
        .help(preferences.text("Click to open and refresh usage", "Haz clic para abrir y actualizar el consumo"))
        .contextMenu {
            Button(preferences.text("Refresh usage", "Actualizar consumo")) { Task { await model.refreshUsage() } }
                .disabled(model.connectionStates.values.contains(.connecting))
            Divider()
            Button(preferences.text("Quit", "Salir")) { NSApplication.shared.terminate(nil) }
        }
    }

    /// Usage shown in the pill. A stale reading whose window already reset
    /// describes the previous window, so it is withheld instead of shown.
    private var headlineUsed: Int? {
        guard let snapshot else { return nil }
        if snapshot.freshness == .stale, snapshot.preferredWindow.hasReset(at: Date()) { return nil }
        return snapshot.preferredWindow.usedPercent
    }

    private var percentage: some View {
        Text(headlineUsed.map { "\(displayPercent($0))%" } ?? "—").monospacedDigit()
    }

    @ViewBuilder
    private func logoRing(size: CGFloat) -> some View {
        ZStack {
            UsageRing(used: headlineUsed,
                      showsConsumed: preferences.showsConsumedPercent,
                      stale: snapshot?.freshness == .stale)
            ProviderMark(provider: provider, color: .white.opacity(0.92)).frame(width: size * 0.52, height: size * 0.52)
        }.frame(width: size, height: size)
    }

    private var accessibilitySummary: String {
        let prefix = preferences.text("\(provider.displayName) usage, ", "Consumo de \(provider.displayName), ")
        guard snapshot != nil else { return prefix + preferences.text("unavailable", "no disponible") }
        guard let used = headlineUsed else { return prefix + preferences.text("reset pending", "reinicio pendiente") }
        let amount = "\(displayPercent(used))% " + percentLabel
        return prefix + amount + ", " + periodLabel
    }

    private func displayPercent(_ used: Int) -> Int { preferences.showsConsumedPercent ? used : 100 - used }

    private var percentLabel: String {
        preferences.showsConsumedPercent ? preferences.text("consumed", "consumido") : preferences.text("available", "disponible")
    }

    private var periodLabel: String {
        switch snapshot?.preferredWindow.durationMinutes {
        case 300: preferences.text("session", "sesión")
        case 10_080: preferences.text("week", "semana")
        default: preferences.text("used", "usado")
        }
    }
}

private struct UsageRing: View {
    let used: Int?
    let showsConsumed: Bool
    let stale: Bool
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.17), lineWidth: 3)
            if let used {
                Circle().trim(from: 0, to: CGFloat(showsConsumed ? used : 100 - used) / 100)
                    .stroke(DockStyle.tint(used), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: stale ? [3, 3] : []))
                    .rotationEffect(.degrees(-90))
            }
        }.padding(2).accessibilityHidden(true)
    }
}

struct DockIndicatorContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var displayScale: EdgeDisplayScale
    var onOpen: () -> Void

    var body: some View {
        let size = CodexEdgeLayout.tabSize(preferences.position)
        let width = preferences.position == .top ? displayScale.topWidth : size.width
        let overlap = preferences.position == .top ? displayScale.topOverlap : 0
        CodexEdgeView(model: model, preferences: preferences, topWidth: width, topOverlap: overlap, onOpen: onOpen)
            .scaleEffect(displayScale.value)
            .frame(width: width * displayScale.value, height: (size.height + overlap) * displayScale.value)
    }
}

struct CodexPanelContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var displayScale: EdgeDisplayScale
    @ObservedObject var navigation: EdgePanelNavigation
    @ObservedObject var claude: ClaudeConnection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onClose: () -> Void

    private var height: CGFloat {
        CodexEdgeLayout.panelHeight(settings: navigation.showsSettings, model: model)
    }
    private var showsSingleProvider: Bool { model.configuredProviderIDs.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if navigation.showsSettings {
                    Button { navigation.showsSettings = false } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                            Text(preferences.text("Back", "Volver"))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 32)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.accessibilityLabel(preferences.text("Back to usage", "Volver al consumo"))
                } else {
                    ProviderMark(provider: model.displayedProviderID ?? .codex, color: .white.opacity(0.8))
                        .frame(width: 20, height: 20)
                        .frame(height: 32)
                }
                Text(navigation.showsSettings ? preferences.text("Settings", "Ajustes") : preferences.text("Usage", "Consumo"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }.accessibilityLabel(preferences.text("Close", "Cerrar"))
            }
            .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
            .frame(height: 32)

            ZStack(alignment: .topLeading) {
                if navigation.showsSettings {
                    AppearanceSettingsView(preferences: preferences, claude: claude)
                        .frame(height: CodexEdgeLayout.detailHeight - 88, alignment: .topLeading)
                        .transition(pageTransition(forward: true))
                } else {
                    CodexUsageDetailView(model: model, preferences: preferences) {
                        navigation.showsSettings = true
                    }
                    .frame(height: CodexEdgeLayout.panelHeight(settings: false, model: model) - 88)
                    .transition(pageTransition(forward: false))
                }
            }
            .frame(height: height - 88, alignment: .topLeading)
        }
        .padding(20)
        .frame(width: CodexEdgeLayout.detailWidth, height: height, alignment: .topLeading)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .environment(\.locale, preferences.locale)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: navigation.showsSettings)
        // A stable transparent host lets SwiftUI animate the actual black surface
        // without fighting AppKit window resizing. At the notch it stays top-aligned.
        .frame(height: CodexEdgeLayout.envelopeHeight(model: model),
               alignment: preferences.position == .top ? .top : .center)
        .scaleEffect(displayScale.value)
        .frame(width: CodexEdgeLayout.detailWidth * displayScale.value,
               height: CodexEdgeLayout.envelopeHeight(model: model) * displayScale.value)
    }

    private func pageTransition(forward: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(x: forward ? 10 : -10))
    }
}

struct CodexUsageDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences = .shared
    var onSettings: () -> Void

    private var providers: [ProviderID] { model.configuredProviderIDs }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(providers) { provider in
                VStack(alignment: .leading, spacing: 8) {
                    if providers.count > 1 { sectionHeader(provider) }
                    section(provider)
                }
            }
            Spacer(minLength: 0)
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            HStack {
                Text(preferences.showsConsumedPercent
                     ? preferences.text("Quota used", "Cuota usada")
                     : preferences.text("Quota available", "Cuota disponible"))
                    .font(.system(size: 10)).foregroundStyle(DockStyle.muted)
                Spacer()
                Button { Task { await model.refreshUsage() } } label: { Image(systemName: "arrow.clockwise").frame(width: 26, height: 24) }
                    .disabled(model.connectionStates.values.contains(.connecting))
                    .help(preferences.text("Refresh usage", "Actualizar consumo"))
                    .accessibilityLabel(preferences.text("Refresh usage", "Actualizar consumo"))
                Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 26, height: 24) }
                    .help(preferences.text("Settings", "Ajustes"))
                    .accessibilityLabel(preferences.text("Settings", "Ajustes"))
            }.font(.system(size: 13)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
        }
    }

    private func sectionHeader(_ provider: ProviderID) -> some View {
        HStack(spacing: 6) {
            ProviderMark(provider: provider, color: .white.opacity(0.85)).frame(width: 13, height: 13)
            Text(provider.displayName).font(.system(size: 12, weight: .semibold))
            if provider == model.displayedProviderID, providers.count > 1 {
                Circle().fill(.white.opacity(0.55)).frame(width: 4, height: 4)
                    .accessibilityLabel(preferences.text("Shown in the pill", "Mostrado en la pill"))
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func section(_ provider: ProviderID) -> some View {
        if let snapshot = model.snapshot(for: provider) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 16) {
                    ForEach(snapshot.windows, id: \.durationMinutes) { window in
                        usageRow(window, snapshot: snapshot, now: context.date)
                    }
                }
            }
            if snapshot.freshness == .stale {
                Text(preferences.text("Last known usage · update pending", "Último consumo conocido · pendiente de actualizar"))
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if provider == .claude {
            Text(claudeHint)
                .font(.system(size: 12)).foregroundStyle(DockStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: CodexEdgeLayout.claudeHintHeight - 8, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.connectionStates[provider] == .connecting ? preferences.text("Connecting…", "Conectando…") : preferences.text("Usage unavailable", "Consumo no disponible"))
                    .font(.system(size: 15, weight: .medium))
                Text(preferences.text("Check that your Codex CLI is installed and signed in.", "Comprueba que Codex CLI esté instalado y tenga una sesión iniciada."))
                    .font(.system(size: 12)).foregroundStyle(DockStyle.muted)
            }.frame(maxWidth: .infinity, minHeight: 85, alignment: .leading)
        }
    }

    private var claudeHint: String {
        preferences.text("Claude Code not found or not signed in.",
                         "No se encontró Claude Code o no tiene sesión iniciada.")
    }

    private func usageRow(_ window: UsageWindow, snapshot: UsageSnapshot, now: Date) -> some View {
        // A stale window past its reset no longer describes current usage.
        let outdated = snapshot.freshness == .stale && window.hasReset(at: now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(CodexEdgeText.windowTitle(window.durationMinutes, preferences: preferences))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(DockStyle.muted)
                Spacer()
                Text(outdated ? "—" : "\(preferences.showsConsumedPercent ? window.usedPercent : 100 - window.usedPercent)%")
                    .font(.system(size: 27, weight: .light, design: .rounded)).monospacedDigit()
            }
            GeometryReader { proxy in
                Capsule().fill(.white.opacity(0.14))
                    .overlay(alignment: .leading) {
                        Capsule().fill(DockStyle.tint(window.usedPercent))
                            .frame(width: outdated ? 0 : proxy.size.width * CGFloat(preferences.showsConsumedPercent ? window.usedPercent : window.remainingPercent) / 100)
                    }
            }.frame(height: 4).accessibilityHidden(true)
            Text(CodexEdgeText.resetLabel(window.resetsAt, now: now, preferences: preferences)).font(.system(size: 10)).foregroundStyle(DockStyle.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Presentation strings for already-normalized usage windows.
@MainActor
enum CodexEdgeText {
    static func windowTitle(_ durationMinutes: Int, preferences: AppPreferences) -> String {
        switch durationMinutes {
        case 300: return preferences.text("Session", "Sesión")
        case 10_080: return preferences.text("This week", "Esta semana")
        case let minutes where minutes % 1_440 == 0:
            let days = minutes / 1_440
            return preferences.text(days == 1 ? "1 day" : "\(days) days", days == 1 ? "1 día" : "\(days) días")
        case let minutes where minutes % 60 == 0:
            return "\(minutes / 60) h"
        default:
            return "\(durationMinutes) min"
        }
    }

    static func resetLabel(_ date: Date?, now: Date, preferences: AppPreferences) -> String {
        guard let date else { return preferences.text("Reset unavailable", "Reinicio no disponible") }
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return preferences.text("Reset pending", "Reinicio pendiente") }
        if minutes < 60 { return preferences.text("Resets in \(minutes) min", "Reinicia en \(minutes) min") }
        if minutes < 1_440 { return preferences.text("Resets in \(minutes / 60)h \(minutes % 60)m", "Reinicia en \(minutes / 60)h \(minutes % 60)m") }
        // Include the day of the month: a bare weekday a week away reads like
        // a time earlier today.
        return preferences.text("Resets ", "Reinicia ") + date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute().locale(preferences.locale))
    }
}
