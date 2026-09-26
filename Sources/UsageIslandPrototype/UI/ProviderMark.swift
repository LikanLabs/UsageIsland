import SwiftUI

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
