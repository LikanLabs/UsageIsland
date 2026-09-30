import SwiftUI

enum CodexEdgeLayout {
    static let tabWidth: CGFloat = 72
    static let tabHeight: CGFloat = 100
    static let topWidth: CGFloat = 176
    // Keep the bridge close to the notch's roughly 32–38pt safe-area height.
    static let topHeight: CGFloat = 36
    static let detailWidth: CGFloat = 324
    static let detailHeight: CGFloat = 504
    static let gap: CGFloat = 8

    static let panelPadding: CGFloat = 18
    static let headerHeight: CGFloat = 36
    static let cardSpacing: CGFloat = 10
    static let cardChrome: CGFloat = 54
    static let gaugesHeight: CGFloat = 112
    static let staleNoteHeight: CGFloat = 24
    static let footerHeight: CGFloat = 26

    static func tabSize(_ position: EdgePosition) -> CGSize {
        position == .top ? CGSize(width: topWidth, height: topHeight) : CGSize(width: tabWidth, height: tabHeight)
    }

    static let gaugesPerRow = 3

    /// Gauges a card shows: every window, plus a "no session limit" slot
    /// when the plan reports no plan-wide 5-hour window.
    static func gaugeCount(_ snapshot: UsageSnapshot) -> Int {
        snapshot.windows.count + (snapshot.windows.contains { $0.durationMinutes == 300 && $0.scope == nil } ? 0 : 1)
    }

    /// Gauge rows: one row when everything fits, otherwise the plan-wide
    /// limits first and then one group per scope, each split into rows of
    /// `gaugesPerRow`. `nil` is the "no session limit" slot.
    static func gaugeRows(_ snapshot: UsageSnapshot) -> [[UsageWindow?]] {
        let hasSession = snapshot.windows.contains { $0.durationMinutes == 300 && $0.scope == nil }
        let all: [UsageWindow?] = (hasSession ? [] : [nil]) + snapshot.windows.map { $0 }
        if all.count <= gaugesPerRow { return [all] }
        var groups: [[UsageWindow?]] = [all.filter { $0?.scope == nil }]
        var scopes: [String] = []
        for window in snapshot.windows { if let scope = window.scope, !scopes.contains(scope) { scopes.append(scope) } }
        groups += scopes.map { scope in snapshot.windows.filter { $0.scope == scope }.map { $0 } }
        return groups.filter { !$0.isEmpty }.flatMap { group in
            stride(from: 0, to: group.count, by: gaugesPerRow).map { Array(group[$0..<min($0 + gaugesPerRow, group.count)]) }
        }
    }

    /// Height of one provider card, including its padding and header.
    static func cardHeight(provider: ProviderID, snapshot: UsageSnapshot?) -> CGFloat {
        guard let snapshot else { return cardChrome + 44 }
        return cardChrome + CGFloat(gaugeRows(snapshot).count) * gaugesHeight
            + (snapshot.freshness == .stale ? staleNoteHeight : 0)
    }

    @MainActor
    static func panelHeight(settings: Bool, model: AppModel) -> CGFloat {
        if settings { return detailHeight }
        let providers = model.configuredProviderIDs
        let cards = providers.reduce(CGFloat(0)) { $0 + cardHeight(provider: $1, snapshot: model.snapshot(for: $1)) }
        let spacing = CGFloat(max(providers.count - 1, 0)) * cardSpacing
        return panelPadding * 2 + headerHeight + 14 + cards + spacing + footerHeight
    }

    @MainActor
    static func envelopeHeight(model: AppModel) -> CGFloat {
        max(detailHeight, panelHeight(settings: false, model: model))
    }
}

/// Flat at the physical edge; rounded only on the exposed side.
private struct AttachedPill: Shape {
    let position: EdgePosition
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = position == .top ? 12 : 22
        return UnevenRoundedRectangle(
            topLeadingRadius: position == .left || position == .top ? 0 : radius,
            bottomLeadingRadius: position == .left ? 0 : radius,
            bottomTrailingRadius: position == .right ? 0 : radius,
            topTrailingRadius: position == .right || position == .top ? 0 : radius
        ).path(in: rect)
    }
}

/// The pill beside the notch or on a screen edge. At the notch it stays
/// black so it reads as part of the hardware; on the sides it is glass.
struct CodexEdgeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences = .shared
    var topWidth: CGFloat = CodexEdgeLayout.topWidth
    var topOverlap: CGFloat = 0
    var onOpen: () -> Void
    /// The pill follows the provider in use; the panel shows all of them.
    private var snapshot: UsageSnapshot? { model.displayedSnapshot }
    private var provider: ProviderID { model.displayedProviderID ?? .codex }
    private var atNotch: Bool { preferences.position == .top }

    var body: some View {
        Button(action: onOpen) {
            pillContent
                .frame(width: atNotch ? topWidth : CodexEdgeLayout.tabWidth,
                       height: CodexEdgeLayout.tabSize(preferences.position).height)
                // Reserve the overlap above the content: only this black background
                // enters the camera cutout; the logo and percentage start below it.
                .padding(.top, atNotch ? topOverlap : 0)
                .modifier(PillSurface(position: preferences.position))
                .foregroundStyle(.white)
                .contentShape(AttachedPill(position: preferences.position))
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
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

    private var pillContent: some View {
        // Ticks so a countdown to the reset stays current.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let countdown = resetCountdown(now: context.date)
            let value = Text(countdown ?? headlineText).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            let caption = Text(countdown == nil ? periodLabel : preferences.text("until reset", "para reinicio"))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            if atNotch {
                HStack(spacing: 7) {
                    logoRing(size: 24, lineWidth: 2.5)
                    value.font(.system(size: 15, weight: .semibold, design: .rounded))
                    caption
                }
            } else {
                VStack(spacing: 4) {
                    logoRing(size: 42, lineWidth: 3)
                    value.font(.system(size: countdown == nil ? 18 : 15, weight: .semibold, design: .rounded))
                    caption
                }
                .padding(.horizontal, 4)
            }
        }
    }

    /// When the shown limit is used up, the useful number is how long until
    /// it resets, not "0%".
    private func resetCountdown(now: Date) -> String? {
        guard let snapshot, let used = headlineUsed, used >= 100,
              let resetsAt = snapshot.preferredWindow.resetsAt, resetsAt > now else { return nil }
        return CodexEdgeText.countdown(until: resetsAt, now: now)
    }

    private var headlineText: String {
        headlineUsed.map { "\(displayPercent($0))%" } ?? "—"
    }

    /// Usage shown in the pill. A stale reading whose window already reset
    /// describes the previous window, so it is withheld instead of shown.
    private var headlineUsed: Int? {
        guard let snapshot else { return nil }
        if snapshot.freshness == .stale, snapshot.preferredWindow.hasReset(at: Date()) { return nil }
        return snapshot.preferredWindow.usedPercent
    }


    private func logoRing(size: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            UsageRing(used: headlineUsed,
                      showsConsumed: preferences.showsConsumedPercent,
                      stale: snapshot?.freshness == .stale,
                      lineWidth: lineWidth)
            ProviderMark(provider: provider, color: .white.opacity(0.95))
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .frame(width: size, height: size)
    }

    private var accessibilitySummary: String {
        let prefix = preferences.text("\(provider.displayName) usage, ", "Consumo de \(provider.displayName), ")
        guard snapshot != nil else { return prefix + preferences.text("unavailable", "no disponible") }
        guard let used = headlineUsed else { return prefix + preferences.text("reset pending", "reinicio pendiente") }
        if let countdown = resetCountdown(now: Date()) {
            return prefix + preferences.text("limit reached, resets in \(countdown)", "límite alcanzado, reinicia en \(countdown)")
        }
        let amount = "\(displayPercent(used))% " + percentLabel
        return prefix + amount + ", " + periodLabel
    }

    private func displayPercent(_ used: Int) -> Int { preferences.showsConsumedPercent ? used : 100 - used }

    private var percentLabel: String {
        preferences.showsConsumedPercent ? preferences.text("consumed", "consumido") : preferences.text("available", "disponible")
    }

    /// Names the one limit the pill shows: the 5-hour window when the plan
    /// has one, otherwise the weekly limit.
    private var periodLabel: String {
        guard let window = snapshot?.preferredWindow else { return "" }
        return CodexEdgeText.pillPeriod(window.durationMinutes, preferences: preferences)
    }
}

private struct PillSurface: ViewModifier {
    let position: EdgePosition
    func body(content: Content) -> some View {
        if position == .top {
            content.background(.black, in: AttachedPill(position: position))
        } else {
            content.islandGlass(in: AttachedPill(position: position), interactive: true)
        }
    }
}

/// Progress ring used by the pill and by each window gauge.
private struct UsageRing: View {
    let used: Int?
    let showsConsumed: Bool
    let stale: Bool
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            // A used-up limit tints the whole track red, so "0 % left" never
            // reads as an empty, neutral ring.
            Circle().stroke(used.map { $0 >= 100 } == true ? IslandPalette.level(100).opacity(0.5) : IslandPalette.track,
                            lineWidth: lineWidth)
            if let used {
                Circle().trim(from: 0, to: CGFloat(showsConsumed ? used : 100 - used) / 100)
                    .stroke(IslandPalette.level(used),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: stale ? [lineWidth, lineWidth * 1.4] : []))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
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

/// The glass panel: usage cards, or settings, in one surface.
struct CodexPanelContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var displayScale: EdgeDisplayScale
    @ObservedObject var navigation: EdgePanelNavigation
    @ObservedObject var claude: ClaudeConnection
    @ObservedObject var system: SystemIntegration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onClose: () -> Void

    private var height: CGFloat {
        CodexEdgeLayout.panelHeight(settings: navigation.showsSettings, model: model)
    }
    private let panelShape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ZStack(alignment: .topLeading) {
                if navigation.showsSettings {
                    AppearanceSettingsView(preferences: preferences, claude: claude, system: system)
                        .transition(pageTransition(forward: true))
                } else {
                    CodexUsageDetailView(model: model, preferences: preferences)
                        .transition(pageTransition(forward: false))
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(CodexEdgeLayout.panelPadding)
        .frame(width: CodexEdgeLayout.detailWidth, height: height, alignment: .topLeading)
        .islandGlass(in: panelShape)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, preferences.locale)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: navigation.showsSettings)
        // A stable transparent host lets SwiftUI animate the actual surface
        // without fighting AppKit window resizing. At the notch it stays top-aligned.
        .frame(height: CodexEdgeLayout.envelopeHeight(model: model),
               alignment: preferences.position == .top ? .top : .center)
        .scaleEffect(displayScale.value)
        .frame(width: CodexEdgeLayout.detailWidth * displayScale.value,
               height: CodexEdgeLayout.envelopeHeight(model: model) * displayScale.value)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if navigation.showsSettings {
                Button { navigation.showsSettings = false } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .islandIconButtonStyle()
                .help(preferences.text("Back to usage", "Volver al consumo"))
                .accessibilityLabel(preferences.text("Back to usage", "Volver al consumo"))
                Text(preferences.text("Settings", "Ajustes")).font(.system(size: 17, weight: .semibold))
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(preferences.text("Usage", "Consumo")).font(.system(size: 17, weight: .semibold))
                    if !model.providers.isEmpty {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(CodexEdgeText.updatedLabel(model.lastUpdatedAt, now: context.date, preferences: preferences))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if !navigation.showsSettings {
                iconButton("arrow.clockwise", label: preferences.text("Refresh usage", "Actualizar consumo")) {
                    Task { await model.refreshUsage() }
                }
                .disabled(model.connectionStates.values.contains(.connecting))
                iconButton("gearshape", label: preferences.text("Settings", "Ajustes")) {
                    navigation.showsSettings = true
                }
            }
            iconButton("xmark", label: preferences.text("Close", "Cerrar"), action: onClose)
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(height: CodexEdgeLayout.headerHeight)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28)
        }
        .islandIconButtonStyle()
        .help(label)
        .accessibilityLabel(label)
    }

    private func pageTransition(forward: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(x: forward ? 10 : -10))
    }
}

/// One card per provider, each with a ring gauge per usage window.
struct CodexUsageDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences = .shared

    private var providers: [ProviderID] { model.configuredProviderIDs }

    var body: some View {
        VStack(alignment: .leading, spacing: CodexEdgeLayout.cardSpacing) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: CodexEdgeLayout.cardSpacing) {
                    ForEach(providers) { provider in
                        card(provider, now: context.date)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(preferences.showsConsumedPercent
                 ? preferences.text("Quota used", "Cuota usada")
                 : preferences.text("Quota available", "Cuota disponible"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private func card(_ provider: ProviderID, now: Date) -> some View {
        let snapshot = model.snapshot(for: provider)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ProviderMark(provider: provider, color: IslandPalette.brand(provider)).frame(width: 15, height: 15)
                Text(provider.displayName).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                if provider == model.displayedProviderID, model.providers.count > 1 {
                    Text(preferences.text("In use", "En uso"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.16), in: Capsule())
                        .accessibilityLabel(preferences.text("Shown in the pill", "Mostrado en la pill"))
                }
            }
            .frame(height: 20)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if let snapshot {
                let rows = CodexEdgeLayout.gaugeRows(snapshot)
                let perRow = CodexEdgeLayout.gaugesPerRow
                let ringSize: CGFloat = CodexEdgeLayout.gaugeCount(snapshot) > 2 ? 62 : 72
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(rows[row].indices, id: \.self) { index in
                                Group {
                                    if let window = rows[row][index] {
                                        gauge(window, snapshot: snapshot, now: now, ringSize: ringSize)
                                    } else {
                                        noSessionGauge(ringSize: ringSize)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            // Keep short rows aligned to the columns above.
                            if rows.count > 1 {
                                ForEach(0..<(perRow - rows[row].count), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .frame(height: CodexEdgeLayout.gaugesHeight, alignment: .top)
                    }
                }
                if snapshot.freshness == .stale {
                    Label(preferences.text("Last known usage · update pending", "Último consumo conocido · pendiente de actualizar"),
                          systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .frame(height: CodexEdgeLayout.staleNoteHeight - 10)
                }
            } else {
                Text(unavailableText(provider))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CodexEdgeLayout.cardHeight(provider: provider, snapshot: snapshot), alignment: .top)
        .background(IslandPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(IslandPalette.cardEdge, lineWidth: 0.5))
    }

    private func unavailableText(_ provider: ProviderID) -> String {
        let cli = provider == .codex ? "Codex CLI" : "Claude Code"
        if model.connectionStates[provider] == .connecting, model.issues[provider] == nil {
            return preferences.text("Connecting…", "Conectando…")
        }
        switch model.issues[provider] ?? .unavailable {
        case .notInstalled:
            return preferences.text("\(cli) is not installed.", "\(cli) no está instalado.")
        case .notSignedIn:
            return preferences.text("Sign in to \(cli) in Terminal with your subscription.",
                                    "Inicia sesión en \(cli) desde la Terminal con tu suscripción.")
        case .noPlanLimits:
            return preferences.text("This account has no plan limits (API key or pay-as-you-go).",
                                    "Esta cuenta no tiene límites de plan (clave de API o pago por uso).")
        case .unavailable:
            return preferences.text("Couldn't read usage. Try refreshing.",
                                    "No se pudo leer el consumo. Prueba actualizar.")
        }
    }

    static func hasSession(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.windows.contains { $0.durationMinutes == 300 && $0.scope == nil }
    }

    /// Some plans (for example during a Codex promotion) report no 5-hour
    /// limit; say so instead of leaving the card lopsided.
    private func noSessionGauge(ringSize: CGFloat) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(IslandPalette.track, style: StrokeStyle(lineWidth: 5, dash: [2, 5])).padding(2.5)
                Text("—").font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(.tertiary)
            }
            .frame(width: ringSize, height: ringSize)
            .padding(.bottom, 2)
            Text(preferences.text("Session", "Sesión")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(preferences.text("No limit", "Sin límite")).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preferences.text("Session", "Sesión"))
        .accessibilityValue(preferences.text("No 5-hour limit reported for this plan", "Sin límite de 5 horas informado para este plan"))
    }

    private func gauge(_ window: UsageWindow, snapshot: UsageSnapshot, now: Date, ringSize: CGFloat) -> some View {
        // A stale window past its reset no longer describes current usage.
        let outdated = snapshot.freshness == .stale && window.hasReset(at: now)
        let shown = preferences.showsConsumedPercent ? window.usedPercent : window.remainingPercent
        let title = CodexEdgeText.windowTitle(window, preferences: preferences)
        return VStack(spacing: 4) {
            ZStack {
                UsageRing(used: outdated ? nil : window.usedPercent,
                          showsConsumed: preferences.showsConsumedPercent,
                          stale: snapshot.freshness == .stale,
                          lineWidth: 5)
                Text(outdated ? "—" : "\(shown)%")
                    .font(.system(size: ringSize * 0.25, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 9)
            }
            .frame(width: ringSize, height: ringSize)
            .padding(.bottom, 2)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(CodexEdgeText.compactResetLabel(window.resetsAt, now: now, preferences: preferences))
                .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue((outdated ? preferences.text("Reset pending", "Reinicio pendiente") : "\(shown)% " + (preferences.showsConsumedPercent ? preferences.text("used", "usado") : preferences.text("available", "disponible")))
                            + ", " + CodexEdgeText.resetLabel(window.resetsAt, now: now, preferences: preferences))
    }
}

/// Presentation strings for already-normalized usage windows.
@MainActor
enum CodexEdgeText {
    /// Scoped limits are named by the provider, e.g. "Fable week".
    static func windowTitle(_ window: UsageWindow, preferences: AppPreferences) -> String {
        guard let scope = window.scope else { return windowTitle(window.durationMinutes, preferences: preferences) }
        switch window.durationMinutes {
        case 10_080: return preferences.text("\(scope) week", "Semana \(scope)")
        case 300: return preferences.text("\(scope) session", "Sesión \(scope)")
        default: return "\(scope) · " + windowTitle(window.durationMinutes, preferences: preferences)
        }
    }

    static func windowTitle(_ durationMinutes: Int, preferences: AppPreferences) -> String {
        switch durationMinutes {
        case 300: return preferences.text("Session", "Sesión")
        case 10_080: return preferences.text("Week", "Semana")
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

    /// Compact time left: "45 min", "1h 20m", "2d 4h".
    static func countdown(until date: Date, now: Date) -> String {
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 1_440 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1_440)d \(minutes % 1_440 / 60)h"
    }

    static func pillPeriod(_ durationMinutes: Int, preferences: AppPreferences) -> String {
        switch durationMinutes {
        case 300: return preferences.text("5 hours", "5 horas")
        case 10_080: return preferences.text("weekly", "semanal")
        case let minutes where minutes % 1_440 == 0:
            let days = minutes / 1_440
            return preferences.text(days == 1 ? "daily" : "\(days) days", days == 1 ? "diario" : "\(days) días")
        case let minutes where minutes % 60 == 0:
            let hours = minutes / 60
            return preferences.text(hours == 1 ? "1 hour" : "\(hours) hours", hours == 1 ? "1 hora" : "\(hours) horas")
        default:
            return "\(durationMinutes) min"
        }
    }

    /// Short form for the gauges: "in 2h 4m" or "Thu 1, 1:00".
    static func compactResetLabel(_ date: Date?, now: Date, preferences: AppPreferences) -> String {
        guard let date else { return "—" }
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return preferences.text("Resetting", "Reiniciando") }
        if minutes < 60 { return preferences.text("in \(minutes) min", "en \(minutes) min") }
        if minutes < 1_440 { return preferences.text("in \(minutes / 60)h \(minutes % 60)m", "en \(minutes / 60)h \(minutes % 60)m") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute().locale(preferences.locale))
    }

    static func updatedLabel(_ date: Date, now: Date, preferences: AppPreferences) -> String {
        if now.timeIntervalSince(date) < 60 { return preferences.text("Updated just now", "Actualizado recién") }
        let relative = date.formatted(.relative(presentation: .named).locale(preferences.locale))
        return preferences.text("Updated ", "Actualizado ") + relative
    }
}
