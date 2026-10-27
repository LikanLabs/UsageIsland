import Combine
import CoreGraphics

@MainActor
final class EdgeDisplayScale: ObservableObject {
    @Published var value: CGFloat = 1
    @Published var topWidth: CGFloat = CodexEdgeLayout.topWidth
    @Published var topOverlap: CGFloat = 0
}

struct EdgeWindowGeometry {
    let scale: CGFloat
    let tab: CGRect
    let detail: CGRect
    let activation: CGRect
    /// Physical points, independent of the user's content scale.
    let topOverlap: CGFloat
    /// The part of the screen a side pill moves along.
    let usable: CGRect

    /// How close to the middle a dropped side pill snaps back to it.
    static let centerSnap: CGFloat = 24

    /// The side position (0 at the bottom, 1 at the top) that puts the pill's
    /// center at `centerY`.
    func verticalPosition(tabCenterY centerY: CGFloat) -> CGFloat {
        let travel = usable.height - tab.height
        guard travel > 0 else { return 0.5 }
        return min(1, max(0, (centerY - usable.minY - tab.height / 2) / travel))
    }

    /// Where a side pill dropped at `position` stays: near the middle it is
    /// the middle, so a pill dragged back is centered again.
    func dropped(at position: CGFloat) -> CGFloat {
        abs(position - 0.5) * max(0, usable.height - tab.height) <= Self.centerSnap ? 0.5 : position
    }

    func visibleDetail(height: CGFloat, position: EdgePosition) -> CGRect {
        let height = min(detail.height, height * scale)
        return CGRect(x: detail.minX,
                      y: position == .top ? detail.maxY - height : detail.midY - height / 2,
                      width: detail.width, height: height)
    }

    static func resolve(screen: CGRect, visible: CGRect, requestedScale: CGFloat,
                        backingScale: CGFloat, position: EdgePosition = .right,
                        verticalPosition: CGFloat = 0.5,
                        topInset: CGFloat = 0, notchFrame: CGRect? = nil,
                        detailHeight: CGFloat = CodexEdgeLayout.detailHeight) -> Self {
        let bounds = screen.intersection(visible)
        let usable = bounds.isNull || bounds.isEmpty ? screen : bounds
        let baseWidth = position == .top ? CodexEdgeLayout.detailWidth : CodexEdgeLayout.tabWidth + CodexEdgeLayout.detailWidth + CodexEdgeLayout.gap
        let preferred = requestedScale.isFinite ? max(0.01, requestedScale) : 1
        let topAnchor = notchFrame?.minY ?? (topInset > 0 ? screen.maxY - topInset : usable.maxY)
        let availableHeight = position == .top ? topAnchor - usable.minY : usable.height
        let scale = min(preferred, max(1, screen.width) / baseWidth,
                        max(1, availableHeight) / (detailHeight + (position == .top ? CodexEdgeLayout.topHeight + CodexEdgeLayout.gap : 0)))
        // A side pill sits where it was dragged, centered by default; the
        // panel stays beside it until it meets the top or bottom.
        let tabHeight = CodexEdgeLayout.tabHeight * scale
        let along = verticalPosition.isFinite ? min(1, max(0, verticalPosition)) : 0.5
        let tabCenterY = usable.height > tabHeight
            ? usable.minY + tabHeight / 2 + (usable.height - tabHeight) * along
            : usable.midY
        let detailHalf = detailHeight * scale / 2
        let detailCenterY = min(max(tabCenterY, usable.minY + detailHalf), usable.maxY - detailHalf)
        var tab = CGRect(x: screen.maxX - CodexEdgeLayout.tabWidth * scale,
                         y: tabCenterY - tabHeight / 2,
                         width: CodexEdgeLayout.tabWidth * scale,
                         height: tabHeight)
        var detail = CGRect(x: tab.minX - (CodexEdgeLayout.detailWidth + CodexEdgeLayout.gap) * scale,
                            y: detailCenterY - detailHalf,
                            width: CodexEdgeLayout.detailWidth * scale,
                            height: detailHeight * scale)
        var topOverlap: CGFloat = 0
        if position == .left {
            tab.origin.x = screen.minX
            detail.origin.x = tab.maxX + CodexEdgeLayout.gap * scale
        } else if position == .top {
            // AppKit supplies the complete cutout bounds, not its corner radius.
            // Cover the full detected width; the view's lower corners follow the
            // camera housing while only the background overlaps into it.
            let width = min(screen.width, notchFrame?.width ?? CodexEdgeLayout.topWidth * scale)
            topOverlap = min(8, notchFrame?.height ?? 0)
            // With no notch, attach below the menu bar instead.
            let notchOriginX = notchFrame?.minX ?? (screen.midX - width / 2)
            // AppKit's Y axis points UP. Put the full content height BELOW
            // the camera, with just topOverlap points of black above its base.
            let tabOriginY = topAnchor - CodexEdgeLayout.topHeight * scale
            tab = CGRect(x: notchOriginX,
                         y: tabOriginY,
                         width: width, height: CodexEdgeLayout.topHeight * scale + topOverlap)
            detail.origin = CGPoint(x: notchOriginX + (width - detail.width) / 2,
                                    y: tab.minY - CodexEdgeLayout.gap * scale - detail.height)
        }
        let activation: CGRect
        switch position {
        case .left: activation = CGRect(x: screen.minX, y: tab.minY - 10, width: tab.maxX - screen.minX, height: tab.height + 20)
        case .right: activation = CGRect(x: tab.minX, y: tab.minY - 10, width: screen.maxX - tab.minX, height: tab.height + 20)
        case .top: activation = CGRect(x: tab.minX, y: tab.minY, width: tab.width, height: screen.maxY - tab.minY)
        }
        return Self(scale: scale, tab: aligned(tab, backingScale), detail: aligned(detail, backingScale),
                    activation: activation, topOverlap: topOverlap, usable: usable)
    }

    private static func aligned(_ rect: CGRect, _ backingScale: CGFloat) -> CGRect {
        let pixelScale = backingScale.isFinite ? max(1, backingScale) : 1
        func pixel(_ value: CGFloat) -> CGFloat { (value * pixelScale).rounded() / pixelScale }
        return CGRect(x: pixel(rect.minX), y: pixel(rect.minY),
                      width: pixel(rect.maxX) - pixel(rect.minX),
                      height: pixel(rect.maxY) - pixel(rect.minY))
    }
}
