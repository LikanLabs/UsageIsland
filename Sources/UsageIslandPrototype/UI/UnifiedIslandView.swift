import SwiftUI

/// Geometry shared by AppKit's renderer and SwiftUI's content.
@MainActor
public final class UnifiedIslandLayout: ObservableObject {
  @Published public var notchWidth: CGFloat = 150
  @Published public var leftWingWidth: CGFloat = 142
  @Published public var rightWingWidth: CGFloat = 72

  public let wingHeight: CGFloat
  public let collapsedBodyHeight: CGFloat
  public let expandedBodyHeight: CGFloat
  public let bodyInset: CGFloat
  public let minimumBodyWidth: CGFloat

  public init(
    wingHeight: CGFloat = 28,
    collapsedBodyHeight: CGFloat = 236,
    expandedBodyHeight: CGFloat = 316,
    bodyInset: CGFloat = 18,
    minimumBodyWidth: CGFloat = 386
  ) {
    self.wingHeight = wingHeight
    self.collapsedBodyHeight = collapsedBodyHeight
    self.expandedBodyHeight = expandedBodyHeight
    self.bodyInset = bodyInset
    self.minimumBodyWidth = minimumBodyWidth
  }

  public var naturalTopWidth: CGFloat {
    leftWingWidth + notchWidth + rightWingWidth
  }

  public var totalWidth: CGFloat {
    max(naturalTopWidth, minimumBodyWidth + (bodyInset * 2))
  }

  public var extraTopWidth: CGFloat {
    max(0, totalWidth - naturalTopWidth)
  }

  public var leadingTopInset: CGFloat { floor(extraTopWidth / 2) }
  public var trailingTopInset: CGFloat { ceil(extraTopWidth / 2) }
  public var bodyWidth: CGFloat { totalWidth - (bodyInset * 2) }
  public var totalHeight: CGFloat { wingHeight + expandedBodyHeight }

  public func update(
    notchWidth: CGFloat,
    leftWingWidth: CGFloat,
    rightWingWidth: CGFloat
  ) {
    self.notchWidth = notchWidth
    self.leftWingWidth = leftWingWidth
    self.rightWingWidth = rightWingWidth
  }
}

/// SwiftUI owns only content and hit targets. Core Animation renders the black
/// surface underneath.
public struct UnifiedIslandView: View {
  @ObservedObject private var model: AppModel
  @ObservedObject private var layout: UnifiedIslandLayout

  public init(model: AppModel, layout: UnifiedIslandLayout) {
    self.model = model
    self.layout = layout
  }

  public var body: some View {
    VStack(spacing: 0) {
      topWings
        .transaction { transaction in
          transaction.animation = nil
          transaction.disablesAnimations = true
        }

      PulseView(
        model: model,
        collapsedHeight: layout.collapsedBodyHeight,
        expandedHeight: layout.expandedBodyHeight,
        drawsSurface: false
      )
      .frame(width: layout.bodyWidth, height: layout.expandedBodyHeight, alignment: .top)
      // Only Pulse content is revealed here. The persistent wing content stays
      // outside this SwiftUI mask, avoiding the v24 clipping regression.
      .mask(alignment: .top) {
        Rectangle()
          .frame(height: presentedContentHeight, alignment: .top)
          .frame(maxHeight: .infinity, alignment: .top)
      }
      .opacity(model.isPulsePresented ? 1 : 0)
      .allowsHitTesting(model.isPulsePresented)
    }
    .frame(width: layout.totalWidth, height: layout.totalHeight, alignment: .top)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .ignoresSafeArea()
  }

  private var presentedContentHeight: CGFloat {
    guard model.isPulsePresented else { return 0 }
    return model.expandedProvider == nil
      ? layout.collapsedBodyHeight
      : layout.expandedBodyHeight
  }

  private var topWings: some View {
    HStack(spacing: 0) {
      Color.clear
        .frame(width: layout.leadingTopInset, height: layout.wingHeight)
        .allowsHitTesting(false)

      UsageWingView(model: model, mode: model.leftMode, drawsSurface: false) {
        model.togglePulse()
      }
      .frame(width: layout.leftWingWidth, height: layout.wingHeight)

      Color.clear
        .frame(width: layout.notchWidth, height: layout.wingHeight)
        .allowsHitTesting(false)

      AgentWingView(model: model, mode: model.rightMode, drawsSurface: false) {
        model.togglePulse()
      }
      .frame(width: layout.rightWingWidth, height: layout.wingHeight)

      Color.clear
        .frame(width: layout.trailingTopInset, height: layout.wingHeight)
        .allowsHitTesting(false)
    }
    .frame(width: layout.totalWidth, height: layout.wingHeight, alignment: .top)
  }
}
