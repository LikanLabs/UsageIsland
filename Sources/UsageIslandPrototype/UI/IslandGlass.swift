import SwiftUI

/// Liquid Glass on macOS 26 and later; a translucent system material with a
/// hairline edge on earlier versions. Content on top keeps the dark scheme,
/// so the glass uses its darker variant and white text stays legible.
extension View {
    @ViewBuilder
    func islandGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if IslandPalette.rendersFlatSurfaces {
            background(Color(white: 0.16).opacity(0.92), in: shape)
                .overlay(shape.stroke(.white.opacity(0.2), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(IslandPalette.glassTint).interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .background(IslandPalette.glassTint, in: shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.5))
        }
    }

    /// Circular icon button that sits on a glass surface.
    @ViewBuilder
    func islandIconButtonStyle() -> some View {
        if #available(macOS 26.0, *), !IslandPalette.rendersFlatSurfaces {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(IslandFallbackIconButtonStyle())
        }
    }

    /// Small text button that sits on a glass surface.
    @ViewBuilder
    func islandTextButtonStyle() -> some View {
        if #available(macOS 26.0, *), !IslandPalette.rendersFlatSurfaces {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

private struct IslandFallbackIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.22 : 0.12), in: Circle())
            .contentShape(Circle())
    }
}

enum IslandPalette {
    /// Static image renderers cannot draw glass; layout previews in tests
    /// switch to flat surfaces. Never set in the app.
    nonisolated(unsafe) static var rendersFlatSurfaces = false

    /// Darkens the glass slightly so white text reads over bright wallpapers.
    static let glassTint = Color.black.opacity(0.22)
    static let card = Color.white.opacity(0.07)
    static let cardEdge = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.14)
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)

    static func brand(_ provider: ProviderID) -> Color {
        switch provider {
        case .codex: .white
        case .claude: claude
        }
    }

    /// Urgency by remaining quota, identical for every provider.
    static func level(_ used: Int) -> Color {
        switch UsageRingLevel(remainingPercent: 100 - used) {
        case .plenty: Color(red: 0.35, green: 0.85, blue: 0.62)
        case .moderate: Color(red: 0.96, green: 0.82, blue: 0.35)
        case .low: Color(red: 1, green: 0.59, blue: 0.28)
        case .critical: Color(red: 1, green: 0.33, blue: 0.35)
        }
    }
}
