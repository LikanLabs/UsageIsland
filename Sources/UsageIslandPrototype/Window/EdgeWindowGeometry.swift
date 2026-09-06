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

    func visibleDetail(height: CGFloat, position: EdgePosition) -> CGRect {
        let height = min(detail.height, height * scale)
        return CGRect(x: detail.minX,
                      y: position == .top ? detail.maxY - height : detail.midY - height / 2,
                      width: detail.width, height: height)
    }

    static func resolve(screen: CGRect, visible: CGRect, requestedScale: CGFloat,
                        backingScale: CGFloat, position: EdgePosition = .right,
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
        let centerY = usable.midY
        var tab = CGRect(x: screen.maxX - CodexEdgeLayout.tabWidth * scale,
                         y: centerY - CodexEdgeLayout.tabHeight * scale / 2,
                         width: CodexEdgeLayout.tabWidth * scale,
                         height: CodexEdgeLayout.tabHeight * scale)
        var detail = CGRect(x: tab.minX - (CodexEdgeLayout.detailWidth + CodexEdgeLayout.gap) * scale,
                            y: centerY - detailHeight * scale / 2,
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
        return Self(scale: scale, tab: aligned(tab, backingScale), detail: aligned(detail, backingScale), activation: activation, topOverlap: topOverlap)
    }

    private static func aligned(_ rect: CGRect, _ backingScale: CGFloat) -> CGRect {
        let pixelScale = backingScale.isFinite ? max(1, backingScale) : 1
        func pixel(_ value: CGFloat) -> CGFloat { (value * pixelScale).rounded() / pixelScale }
        return CGRect(x: pixel(rect.minX), y: pixel(rect.minY),
                      width: pixel(rect.maxX) - pixel(rect.minX),
                      height: pixel(rect.maxY) - pixel(rect.minY))
    }
}
