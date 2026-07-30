import AppKit
import QuartzCore
import SwiftUI

/// Persistent AppKit host for the unified notch surface.
///
/// Rendering responsibilities are intentionally separated:
/// - `wingLayer` draws the resting wings and never animates.
/// - `bodyLayer` owns one final, static Pulse silhouette.
/// - `bodyRevealMaskLayer` reveals that silhouette vertically without
///   deforming its corners or connectors.
/// - SwiftUI content remains independent from Core Animation masks. It uses
///   the same delayed fade as v21, avoiding coordinate-system clipping of the
///   persistent wing content.
@MainActor
public final class UnifiedIslandContainerView: NSView {
  private let wingLayer = CAShapeLayer()
  private let bodyLayer = CAShapeLayer()
  private let bodyRevealMaskLayer = CAShapeLayer()

  private let hostingView: NSHostingView<UnifiedIslandView>

  private var layoutModel: UnifiedIslandLayout
  private var bodyHeight: CGFloat = 0
  private var animationGeneration = 0

  private let wingOuterRadius: CGFloat = 14
  private let bodyCornerRadius: CGFloat = 24
  private let connectorWidth: CGFloat = 16
  private let connectorHeight: CGFloat = 13
  private let connectorCornerRadius: CGFloat = 7
  private let connectorWingOverlap: CGFloat = 3
  private let connectorNotchOverlap: CGFloat = 2

  public override var isFlipped: Bool { false }

  public init(rootView: UnifiedIslandView, layout: UnifiedIslandLayout) {
    self.layoutModel = layout
    self.hostingView = NSHostingView(rootView: rootView)
    super.init(frame: .zero)

    wantsLayer = true
    layer = CALayer()
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = false

    configureVisibleShapeLayer(bodyLayer, zPosition: 0)
    configureVisibleShapeLayer(wingLayer, zPosition: 1)

    configureMaskShapeLayer(bodyRevealMaskLayer)
    bodyLayer.mask = bodyRevealMaskLayer

    hostingView.sizingOptions = []
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    hostingView.layer?.zPosition = 2
    hostingView.autoresizingMask = [.width, .height]

    addSubview(hostingView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public override func layout() {
    super.layout()

    hostingView.frame = bounds
    wingLayer.frame = bounds
    bodyLayer.frame = bounds
    bodyRevealMaskLayer.frame = bounds

    redrawImmediately()
  }

  public func updateLayout(_ layout: UnifiedIslandLayout) {
    layoutModel = layout
    redrawImmediately()
  }

  /// Reveals the already-final Pulse silhouette. No visible corner, shoulder,
  /// or wing geometry is morphed during this animation.
  public func setBodyHeight(
    _ requestedHeight: CGFloat,
    animated: Bool,
    duration: CFTimeInterval = 0.28,
    completion: (() -> Void)? = nil
  ) {
    let targetHeight = min(max(0, requestedHeight), layoutModel.expandedBodyHeight)
    bodyHeight = targetHeight
    animationGeneration += 1
    let generation = animationGeneration

    let targetPath = revealMaskPath(height: targetHeight)
    let visiblePath =
      (bodyRevealMaskLayer.presentation() as? CAShapeLayer)?.path
      ?? bodyRevealMaskLayer.path
      ?? revealMaskPath(height: 0)

    bodyRevealMaskLayer.removeAnimation(forKey: "usageIsland.bodyReveal")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bodyRevealMaskLayer.path = targetPath
    CATransaction.commit()

    guard animated, duration > 0 else {
      completion?()
      return
    }

    let timing = CAMediaTimingFunction(
      controlPoints: 0.18,
      0.74,
      0.20,
      1.00
    )

    let bodyAnimation = CABasicAnimation(keyPath: "path")
    bodyAnimation.fromValue = visiblePath
    bodyAnimation.toValue = targetPath
    bodyAnimation.duration = duration
    bodyAnimation.timingFunction = timing
    bodyAnimation.isRemovedOnCompletion = true

    bodyRevealMaskLayer.add(bodyAnimation, forKey: "usageIsland.bodyReveal")

    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
      guard let self, self.animationGeneration == generation else { return }
      completion?()
    }
  }

  public func stopAnimations() {
    animationGeneration += 1

    let visiblePath =
      (bodyRevealMaskLayer.presentation() as? CAShapeLayer)?.path
      ?? bodyRevealMaskLayer.path

    if let visiblePath {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      bodyRevealMaskLayer.path = visiblePath
      CATransaction.commit()
    }

    bodyRevealMaskLayer.removeAllAnimations()
  }

  private func configureVisibleShapeLayer(
    _ shapeLayer: CAShapeLayer,
    zPosition: CGFloat
  ) {
    shapeLayer.fillColor = NSColor.black.cgColor
    shapeLayer.strokeColor = nil
    shapeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    shapeLayer.zPosition = zPosition
    shapeLayer.allowsEdgeAntialiasing = true
    layer?.addSublayer(shapeLayer)
  }

  private func configureMaskShapeLayer(_ shapeLayer: CAShapeLayer) {
    shapeLayer.fillColor = NSColor.white.cgColor
    shapeLayer.strokeColor = nil
    shapeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    shapeLayer.allowsEdgeAntialiasing = true
  }

  private func redrawImmediately() {
    guard bounds.width > 0, bounds.height > 0 else { return }

    let wings = staticWingsPath()
    let body = finalPulseSurfacePath()
    let reveal = revealMaskPath(height: bodyHeight)

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    wingLayer.path = wings
    bodyLayer.path = body
    bodyRevealMaskLayer.path = reveal

    CATransaction.commit()
  }

  /// Exact resting-wing geometry. It is identical in closed and open states.
  private func staticWingsPath() -> CGPath {
    let topY = bounds.height
    let bottomY = bounds.height - layoutModel.wingHeight
    let leftOuter = layoutModel.leadingTopInset
    let leftInner = leftOuter + layoutModel.leftWingWidth
    let rightInner = leftInner + layoutModel.notchWidth
    let rightOuter = rightInner + layoutModel.rightWingWidth
    let radius = min(wingOuterRadius, layoutModel.wingHeight / 2)
    let kappa: CGFloat = 0.552_284_75

    let path = CGMutablePath()

    path.move(to: CGPoint(x: leftOuter, y: topY))
    path.addLine(to: CGPoint(x: leftInner, y: topY))
    path.addLine(to: CGPoint(x: leftInner, y: bottomY))
    path.addLine(to: CGPoint(x: leftOuter + radius, y: bottomY))
    path.addCurve(
      to: CGPoint(x: leftOuter, y: bottomY + radius),
      control1: CGPoint(x: leftOuter + radius - radius * kappa, y: bottomY),
      control2: CGPoint(x: leftOuter, y: bottomY + radius - radius * kappa)
    )
    path.addLine(to: CGPoint(x: leftOuter, y: topY))
    path.closeSubpath()

    path.move(to: CGPoint(x: rightInner, y: topY))
    path.addLine(to: CGPoint(x: rightOuter, y: topY))
    path.addLine(to: CGPoint(x: rightOuter, y: bottomY + radius))
    path.addCurve(
      to: CGPoint(x: rightOuter - radius, y: bottomY),
      control1: CGPoint(x: rightOuter, y: bottomY + radius - radius * kappa),
      control2: CGPoint(x: rightOuter - radius + radius * kappa, y: bottomY)
    )
    path.addLine(to: CGPoint(x: rightInner, y: bottomY))
    path.addLine(to: CGPoint(x: rightInner, y: topY))
    path.closeSubpath()

    return path
  }

  /// Final, non-animated Pulse surface.
  ///
  /// The body is a four-corner rounded macOS-style panel. Two compact
  /// connectors rise from its top edge into the inner lower corners of the
  /// static wings. The shape itself never changes while opening or closing.
  private func finalPulseSurfacePath() -> CGPath {
    let wingBottomY = bounds.height - layoutModel.wingHeight
    let bodyRect = CGRect(
      x: layoutModel.bodyInset,
      y: wingBottomY - layoutModel.expandedBodyHeight,
      width: layoutModel.bodyWidth,
      height: layoutModel.expandedBodyHeight
    )

    let leftWingInner = layoutModel.leadingTopInset + layoutModel.leftWingWidth
    let rightWingInner = leftWingInner + layoutModel.notchWidth

    let path = CGMutablePath()
    appendContinuousRoundedRect(
      to: path,
      rect: bodyRect,
      radius: bodyCornerRadius
    )

    let connectorTopY = wingBottomY + connectorWingOverlap
    let connectorBottomY = wingBottomY - connectorHeight

    let leftConnectorRect = CGRect(
      x: leftWingInner - connectorWidth,
      y: connectorBottomY,
      width: connectorWidth + connectorNotchOverlap,
      height: connectorTopY - connectorBottomY
    )
    appendContinuousRoundedRect(
      to: path,
      rect: leftConnectorRect,
      radius: connectorCornerRadius
    )

    let rightConnectorRect = CGRect(
      x: rightWingInner - connectorNotchOverlap,
      y: connectorBottomY,
      width: connectorWidth + connectorNotchOverlap,
      height: connectorTopY - connectorBottomY
    )
    appendContinuousRoundedRect(
      to: path,
      rect: rightConnectorRect,
      radius: connectorCornerRadius
    )

    return path
  }

  /// Simple top-anchored reveal mask. Its bottom edge carries the same radius
  /// as the final panel, so the visible Pulse keeps rounded lower corners at
  /// every intermediate and collapsed height.
  private func revealMaskPath(height requestedHeight: CGFloat) -> CGPath {
    let height = min(max(0, requestedHeight), layoutModel.expandedBodyHeight)
    let wingBottomY = bounds.height - layoutModel.wingHeight
    let revealTopY = wingBottomY + connectorWingOverlap
    let revealBottomY = wingBottomY - height
    let maskWidth = max(0, bounds.width - (layoutModel.bodyInset * 2))
    let radius = min(bodyCornerRadius, height / 2, maskWidth / 2)

    let path = CGMutablePath()
    let leftX = layoutModel.bodyInset
    let rightX = bounds.width - layoutModel.bodyInset

    path.move(to: CGPoint(x: leftX, y: revealTopY))
    path.addLine(to: CGPoint(x: rightX, y: revealTopY))
    path.addLine(to: CGPoint(x: rightX, y: revealBottomY + radius))

    let kappa: CGFloat = 0.552_284_75
    path.addCurve(
      to: CGPoint(x: rightX - radius, y: revealBottomY),
      control1: CGPoint(x: rightX, y: revealBottomY + radius - radius * kappa),
      control2: CGPoint(x: rightX - radius + radius * kappa, y: revealBottomY)
    )

    path.addLine(to: CGPoint(x: leftX + radius, y: revealBottomY))
    path.addCurve(
      to: CGPoint(x: leftX, y: revealBottomY + radius),
      control1: CGPoint(x: leftX + radius - radius * kappa, y: revealBottomY),
      control2: CGPoint(x: leftX, y: revealBottomY + radius - radius * kappa)
    )

    path.addLine(to: CGPoint(x: leftX, y: revealTopY))
    path.closeSubpath()
    return path
  }

  private func appendContinuousRoundedRect(
    to path: CGMutablePath,
    rect: CGRect,
    radius requestedRadius: CGFloat
  ) {
    guard rect.width > 0, rect.height > 0 else { return }

    let radius = min(requestedRadius, rect.width / 2, rect.height / 2)
    let kappa: CGFloat = 0.552_284_75

    path.move(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
    path.addCurve(
      to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
      control1: CGPoint(x: rect.maxX - radius + radius * kappa, y: rect.maxY),
      control2: CGPoint(x: rect.maxX, y: rect.maxY - radius + radius * kappa)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
    path.addCurve(
      to: CGPoint(x: rect.maxX - radius, y: rect.minY),
      control1: CGPoint(x: rect.maxX, y: rect.minY + radius - radius * kappa),
      control2: CGPoint(x: rect.maxX - radius + radius * kappa, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
    path.addCurve(
      to: CGPoint(x: rect.minX, y: rect.minY + radius),
      control1: CGPoint(x: rect.minX + radius - radius * kappa, y: rect.minY),
      control2: CGPoint(x: rect.minX, y: rect.minY + radius - radius * kappa)
    )
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
    path.addCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.maxY),
      control1: CGPoint(x: rect.minX, y: rect.maxY - radius + radius * kappa),
      control2: CGPoint(x: rect.minX + radius - radius * kappa, y: rect.maxY)
    )
    path.closeSubpath()
  }
}
