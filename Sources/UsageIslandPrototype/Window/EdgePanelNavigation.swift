import Combine
import Foundation

/// Keeps the outgoing page intact until its window has finished fading out.
@MainActor
final class EdgePanelNavigation: ObservableObject {
    @Published var showsSettings = false
    private var generation: UInt64 = 0
    private var presented = false

    func beginPresentation(_ open: Bool) -> UInt64 {
        generation &+= 1
        presented = open
        if open { showsSettings = false }
        return generation
    }

    func canFinishClosing(_ token: UInt64) -> Bool {
        token == generation && !presented
    }

    func finishClosing(_ token: UInt64) {
        guard canFinishClosing(token) else { return }
        showsSettings = false
    }
}

/// Presentation thresholds, independent of any provider's quota rules.
enum UsageRingLevel: Equatable {
    case plenty, moderate, low, critical

    init(remainingPercent: Int) {
        switch remainingPercent {
        case 51...: self = .plenty
        case 26...50: self = .moderate
        case 11...25: self = .low
        default: self = .critical
        }
    }
}
