import AppKit
import Combine
import SwiftUI

@MainActor
public final class IslandWindowController {
  private let model: AppModel
  private let occupancyService: MenuBarOccupancyService
  private let unifiedLayout = UnifiedIslandLayout()

  private var leftPanel: NSPanel?
  private var rightPanel: NSPanel?
  private var unifiedPanel: NSPanel?
  private var unifiedContainer: UnifiedIslandContainerView?

  private var cancellables: Set<AnyCancellable> = []
  private var eventMonitor: Any?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var transitionGeneration = 0

  private let wingHeight: CGFloat = 28
  private let notchOverlap: CGFloat = 8
  private let safetyMargin: CGFloat = 8

  public init(model: AppModel, occupancyService: MenuBarOccupancyService) {
    self.model = model
    self.occupancyService = occupancyService
    observeModel()
    observeWorkspace()
  }

  public func shutdown() {
    transitionGeneration += 1
    removeOutsideClickMonitor()
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    for observer in workspaceObservers {
      workspaceCenter.removeObserver(observer)
      NotificationCenter.default.removeObserver(observer)
    }
    workspaceObservers.removeAll()
    cancellables.removeAll()

    unifiedContainer?.stopAnimations()
    leftPanel?.close()
    rightPanel?.close()
    unifiedPanel?.close()
    leftPanel = nil
    rightPanel = nil
    unifiedPanel = nil
    unifiedContainer = nil
  }

  public func show() {
    buildWindowsOnce()
  }

  public func refreshLayout() {
    guard let screen = targetScreen() else { return }
    let geometry = ScreenNotchGeometry.resolve(for: screen)
    let occupancy = occupancyService.measure(for: geometry)
    model.adaptiveSpacingIsTrusted = occupancy.isAccessibilityTrusted

    let leftAvailable = max(
      0,
      geometry.notchFrame.minX - occupancy.leftOccupiedMaxX - safetyMargin
    )
    let rightAvailable = max(
      0,
      occupancy.rightOccupiedMinX - geometry.notchFrame.maxX - safetyMargin
    )

    model.leftMode = resolveLeftMode(availableWidth: leftAvailable)
    model.rightMode = resolveRightMode(availableWidth: rightAvailable)
    updateUnifiedLayout(using: geometry)

    if model.isPulseOpen {
      hideRestingWings()
      positionUnifiedPanel(using: geometry, bringForward: true)
    } else {
      unifiedPanel?.orderOut(nil)
      positionRestingWings(using: geometry)
    }

    model.islandIsVisible =
      model.leftMode != .hidden || (model.rightMode != .hidden && !model.activeAgents.isEmpty)
  }

  public func togglePulse() {
    model.togglePulse()
  }

  public func requestAccessibilityPermission() {
    occupancyService.requestAccessibilityPermission()
  }

  private func buildWindowsOnce() {
    guard leftPanel == nil, rightPanel == nil, unifiedPanel == nil else {
      refreshLayout()
      return
    }

    leftPanel = makePanel(
      rootView: UsageWingView(model: model, mode: .automatic) { [weak self] in
        self?.togglePulse()
      }
    )
    rightPanel = makePanel(
      rootView: AgentWingView(model: model, mode: .automatic) { [weak self] in
        self?.togglePulse()
      }
    )

    let panel = makeEmptyPanel()
    let container = UnifiedIslandContainerView(
      rootView: UnifiedIslandView(model: model, layout: unifiedLayout),
      layout: unifiedLayout
    )
    container.autoresizingMask = [.width, .height]
    panel.contentView = container
    panel.alphaValue = 1
    panel.orderOut(nil)
    unifiedContainer = container
    unifiedPanel = panel

    refreshLayout()
  }

  private func makePanel<Content: View>(rootView: Content) -> NSPanel {
    let panel = makeEmptyPanel()
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.sizingOptions = []
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    return panel
  }

  private func makeEmptyPanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
    panel.animationBehavior = .none
    return panel
  }

  private func observeModel() {
    model.$requestedLayout
      .dropFirst()
      .sink { [weak self] _ in self?.refreshLayout() }
      .store(in: &cancellables)

    Publishers.CombineLatest3(model.$providers, model.$agents, model.$scenario)
      .dropFirst()
      .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
      .sink { [weak self] _, _, _ in self?.refreshLayout() }
      .store(in: &cancellables)

    model.$isPulseOpen
      .removeDuplicates()
      .sink { [weak self] open in self?.setPulse(open: open) }
      .store(in: &cancellables)

    model.$expandedProvider
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] provider in
        guard let self, self.model.isPulseOpen else { return }
        let target =
          provider == nil
          ? self.unifiedLayout.collapsedBodyHeight
          : self.unifiedLayout.expandedBodyHeight
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.unifiedContainer?.setBodyHeight(
          target,
          animated: !reduceMotion,
          duration: reduceMotion ? 0 : UsageIslandTokens.bodyRevealDuration
        )
      }
      .store(in: &cancellables)
  }

  private func observeWorkspace() {
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
          Task { @MainActor in self?.refreshLayout() }
        }
      }
    )
    workspaceObservers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.refreshLayout() }
      }
    )
  }

  private func setPulse(open: Bool) {
    guard let unifiedPanel, let unifiedContainer, let screen = targetScreen() else {
      return
    }
    let geometry = ScreenNotchGeometry.resolve(for: screen)
    updateUnifiedLayout(using: geometry)
    transitionGeneration += 1
    let generation = transitionGeneration
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    if open {
      positionUnifiedPanel(using: geometry, bringForward: false)

      if !unifiedPanel.isVisible {
        var reset = Transaction()
        reset.animation = nil
        reset.disablesAnimations = true
        withTransaction(reset) {
          model.isPulsePresented = false
        }
        unifiedContainer.setBodyHeight(0, animated: false)
        unifiedPanel.contentView?.layoutSubtreeIfNeeded()
        unifiedPanel.displayIfNeeded()
        unifiedPanel.orderFrontRegardless()
        hideRestingWings()
      } else {
        unifiedPanel.orderFrontRegardless()
      }

      installOutsideClickMonitor()
      let targetHeight =
        model.expandedProvider == nil
        ? unifiedLayout.collapsedBodyHeight
        : unifiedLayout.expandedBodyHeight

      // Use the same synchronized expansion used by provider details:
      // the surface reveal and the SwiftUI content reveal start together and
      // share the detail-motion duration instead of using a delayed fade.
      if reduceMotion {
        model.isPulsePresented = true
      } else {
        withAnimation(UsageIslandTokens.detailMotion) {
          model.isPulsePresented = true
        }
      }

      unifiedContainer.setBodyHeight(
        targetHeight,
        animated: !reduceMotion,
        duration: reduceMotion ? 0 : UsageIslandTokens.bodyRevealDuration
      )
    } else {
      removeOutsideClickMonitor()

      var detailReset = Transaction()
      detailReset.animation = nil
      detailReset.disablesAnimations = true
      withTransaction(detailReset) {
        model.expandedProvider = nil
      }

      if reduceMotion {
        model.isPulsePresented = false
        unifiedContainer.setBodyHeight(0, animated: false) { [weak self] in
          guard let self,
            self.transitionGeneration == generation,
            !self.model.isPulseOpen
          else { return }
          self.positionRestingWings(using: geometry)
          unifiedPanel.orderOut(nil)
        }
        return
      }

      // Closing is the exact reverse of opening, matching provider-detail
      // collapse instead of fading first and moving the surface afterwards.
      withAnimation(UsageIslandTokens.detailMotion) {
        model.isPulsePresented = false
      }

      unifiedContainer.setBodyHeight(
        0,
        animated: true,
        duration: UsageIslandTokens.bodyRevealDuration
      ) { [weak self] in
        guard let self,
          self.transitionGeneration == generation,
          !self.model.isPulseOpen
        else { return }
        self.positionRestingWings(using: geometry)
        unifiedPanel.orderOut(nil)
      }
    }
  }

  private func updateUnifiedLayout(using geometry: ScreenNotchGeometry) {
    let leftWidth = max(width(forLeftMode: model.leftMode), 58)
    let rightWidth = max(width(forRightMode: model.rightMode), 40)
    let notchWidth = max(1, geometry.notchFrame.width - (notchOverlap * 2))

    unifiedLayout.update(
      notchWidth: notchWidth,
      leftWingWidth: leftWidth,
      rightWingWidth: rightWidth
    )
    unifiedContainer?.updateLayout(unifiedLayout)
  }

  private func positionUnifiedPanel(
    using geometry: ScreenNotchGeometry,
    bringForward: Bool
  ) {
    guard let unifiedPanel, let screen = targetScreen() else { return }
    let frame = pixelAligned(unifiedFrame(for: geometry), on: screen)
    unifiedPanel.setFrame(frame, display: true)
    unifiedPanel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
    unifiedPanel.contentView?.layoutSubtreeIfNeeded()
    if bringForward {
      unifiedPanel.alphaValue = 1
      unifiedPanel.orderFrontRegardless()
    }
  }

  private func unifiedFrame(for geometry: ScreenNotchGeometry) -> CGRect {
    let width = unifiedLayout.totalWidth
    let height = unifiedLayout.totalHeight
    let x =
      geometry.notchFrame.minX
      - unifiedLayout.leftWingWidth
      - unifiedLayout.leadingTopInset
      + notchOverlap
    let y = geometry.screenFrame.maxY - height
    return CGRect(x: x, y: y, width: width, height: height)
  }

  private func pixelAligned(_ frame: CGRect, on screen: NSScreen) -> CGRect {
    let scale = screen.backingScaleFactor
    func aligned(_ value: CGFloat) -> CGFloat {
      (value * scale).rounded() / scale
    }

    let minX = aligned(frame.minX)
    let maxX = aligned(frame.maxX)
    let minY = aligned(frame.minY)
    let maxY = aligned(frame.maxY)
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private func positionRestingWings(using geometry: ScreenNotchGeometry) {
    guard let screen = targetScreen() else { return }
    let leftWidth = width(forLeftMode: model.leftMode)
    let rightWidth = width(forRightMode: model.rightMode)
    let topY = geometry.screenFrame.maxY - wingHeight

    if model.leftMode == .hidden {
      leftPanel?.orderOut(nil)
    } else {
      let frame = CGRect(
        x: geometry.notchFrame.minX - leftWidth + notchOverlap,
        y: topY,
        width: leftWidth,
        height: wingHeight
      )
      leftPanel?.setFrame(pixelAligned(frame, on: screen), display: true)
      leftPanel?.orderFrontRegardless()
    }

    if model.rightMode == .hidden || model.activeAgents.isEmpty {
      rightPanel?.orderOut(nil)
    } else {
      let frame = CGRect(
        x: geometry.notchFrame.maxX - notchOverlap,
        y: topY,
        width: rightWidth,
        height: wingHeight
      )
      rightPanel?.setFrame(pixelAligned(frame, on: screen), display: true)
      rightPanel?.orderFrontRegardless()
    }
  }

  private func hideRestingWings() {
    leftPanel?.orderOut(nil)
    rightPanel?.orderOut(nil)
  }

  private func installOutsideClickMonitor() {
    removeOutsideClickMonitor()
    eventMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      guard let self, let panel = self.unifiedPanel else { return }

      let visibleBodyHeight =
        self.model.expandedProvider == nil
        ? self.unifiedLayout.collapsedBodyHeight
        : self.unifiedLayout.expandedBodyHeight
      let visibleHeight = self.unifiedLayout.wingHeight + visibleBodyHeight
      let visibleFrame = CGRect(
        x: panel.frame.minX,
        y: panel.frame.maxY - visibleHeight,
        width: panel.frame.width,
        height: visibleHeight
      )

      if !visibleFrame.contains(NSEvent.mouseLocation) {
        Task { @MainActor in self.model.closePulse() }
      }
    }
  }

  private func removeOutsideClickMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }

  private func targetScreen() -> NSScreen? {
    NSScreen.main ?? NSScreen.screens.first
  }

  private func resolveLeftMode(availableWidth: CGFloat) -> WingPresentationMode {
    if model.requestedLayout != .automatic { return model.requestedLayout }
    if availableWidth >= 190 { return .full }
    if availableWidth >= 130 { return .compact }
    if availableWidth >= 48 { return .minimal }
    return .hidden
  }

  private func resolveRightMode(availableWidth: CGFloat) -> WingPresentationMode {
    if model.requestedLayout != .automatic { return model.requestedLayout }
    if availableWidth >= 120 { return .full }
    if availableWidth >= 64 { return .compact }
    if availableWidth >= 36 { return .minimal }
    return .hidden
  }

  private func width(forLeftMode mode: WingPresentationMode) -> CGFloat {
    switch mode {
    case .full: 224
    case .compact, .automatic: 142
    case .minimal: 58
    case .hidden: 0
    }
  }

  private func width(forRightMode mode: WingPresentationMode) -> CGFloat {
    switch mode {
    case .full: 132
    case .compact, .automatic: 72
    case .minimal: 40
    case .hidden: 0
    }
  }
}
