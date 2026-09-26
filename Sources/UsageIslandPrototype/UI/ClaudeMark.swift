import SwiftUI

/// A simple radiating spark used to tell Claude apart from Codex at a glance.
/// Drawn here rather than copied from a brand asset. Render as a fill.
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rays = 12
        var path = Path()
        for index in 0..<rays {
            let angle = (Double(index) / Double(rays)) * 2 * .pi - .pi / 2
            let length = side * (index.isMultiple(of: 2) ? 0.5 : 0.4)
            // Rays meet at the center, so the core needs no separate shape
            // (overlapping subpaths with opposite winding would leave holes).
            let inner: CGFloat = 0
            let baseHalfWidth = side * 0.055
            let tipHalfWidth = side * 0.022
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            func point(_ distance: CGFloat, _ offset: CGFloat) -> CGPoint {
                CGPoint(x: center.x + direction.dx * distance + normal.dx * offset,
                        y: center.y + direction.dy * distance + normal.dy * offset)
            }
            path.move(to: point(inner, baseHalfWidth))
            path.addLine(to: point(length - tipHalfWidth, tipHalfWidth))
            path.addQuadCurve(to: point(length - tipHalfWidth, -tipHalfWidth), control: point(length + tipHalfWidth, 0))
            path.addLine(to: point(inner, -baseHalfWidth))
            path.closeSubpath()
        }
        return path
    }
}

/// The mark for any provider, sized by the caller.
struct ProviderMark: View {
    let provider: ProviderID
    var color: Color = .white

    var body: some View {
        shape.fill(color)
    }

    private var shape: AnyShape {
        switch provider {
        case .codex: AnyShape(CodexMark())
        case .claude: AnyShape(ClaudeMark())
        }
    }
}
