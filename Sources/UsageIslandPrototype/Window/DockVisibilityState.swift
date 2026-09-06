import Foundation

/// Pointer polling needs no accessibility permission and never intercepts clicks.
struct DockVisibilityState {
    private(set) var isVisible = true
    private var hideDeadline: TimeInterval?

    mutating func update(autoHide: Bool, pointerActive: Bool, pinned: Bool,
                         menuOpen: Bool, now: TimeInterval) -> Bool {
        if !autoHide || pointerActive || pinned || menuOpen {
            isVisible = true
            hideDeadline = nil
        } else if isVisible {
            if let hideDeadline {
                if now >= hideDeadline { isVisible = false }
            } else {
                hideDeadline = now + 0.45
            }
        }
        return isVisible
    }
}
