import AppKit
import Combine
import SwiftUI

@MainActor
final class CodexEdgeWindowController {
    private let model: AppModel
    private let preferences: AppPreferences
    private let displayScale = EdgeDisplayScale()
    private let navigation = EdgePanelNavigation()
    private var tab: NSPanel?
    private var detail: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var isPinned = false
    private var geometry: EdgeWindowGeometry?
    private var visibility = DockVisibilityState()
    private var visibilityTimer: AnyCancellable?
    private var menuOpen = false
    private var animationID = 0

    init(model: AppModel, preferences: AppPreferences = .shared) {
        self.model = model
        self.preferences = preferences
    }

    func show() {
        guard tab == nil else { return }
        tab = makePanel(DockIndicatorContent(model: model, preferences: preferences, displayScale: displayScale, onOpen: { [weak self] in
            self?.togglePulse()
        }))
        tab?.title = "Codex Usage Tab"
        detail = makePanel(CodexPanelContent(model: model, preferences: preferences, displayScale: displayScale, navigation: navigation, onClose: { [weak self] in
            self?.model.closePulse()
        }))
        detail?.title = "Codex Usage Details"
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: detail)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.detail?.isKeyWindow != true, !self.menuOpen else { return }
                self.model.closePulse()
            }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.model.closePulse()
            }.store(in: &subscriptions)
        model.$isPulseOpen.removeDuplicates().sink { [weak self] open in
            self?.presentDetail(open)
        }.store(in: &subscriptions)
        preferences.$scale.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLayout() }
            .store(in: &subscriptions)
        preferences.$position.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshLayout()
        }.store(in: &subscriptions)
        model.$providers.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLayout() }
            .store(in: &subscriptions)
        preferences.$autoHide.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.configureAutoHide()
        }.store(in: &subscriptions)
        for (notification, tracking) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            NotificationCenter.default.publisher(for: notification).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.menuOpen = tracking
                self?.pollVisibility()
            }.store(in: &subscriptions)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshLayout() }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Global monitors receive clicks dispatched to another application.
            // Do not reclassify them using a later cursor position or menu state.
            Task { @MainActor in self?.model.closePulse() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53, self?.menuOpen != true {
                self?.model.closePulse()
                return nil
            } else if event.type != .keyDown {
                self?.closeIfOutside(event)
            }
            return event
        }
        for event in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: event)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshLayout() }
                .store(in: &subscriptions)
        }
        refreshLayout()
    }

    func refreshLayout() {
        // Prefer the built-in display, including models without a notch. When it
        // disconnects (clamshell mode), fall back to the first remaining display.
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        } ?? NSScreen.screens.first
        guard let screen else {
            tab?.orderOut(nil)
            detail?.orderOut(nil)
            model.islandIsVisible = false
            return
        }
        let notch = ScreenNotchGeometry.resolve(for: screen)
        let geometry = EdgeWindowGeometry.resolve(
            screen: screen.frame, visible: screen.visibleFrame,
            requestedScale: preferences.scale, backingScale: screen.backingScaleFactor,
            position: preferences.position, topInset: screen.safeAreaInsets.top,
            notchFrame: notch.hasHardwareNotch ? notch.notchFrame : nil,
            detailHeight: CodexEdgeLayout.envelopeHeight(snapshot: model.providers.first { $0.id == .codex })
        )
        self.geometry = geometry
        displayScale.value = geometry.scale
        displayScale.topWidth = geometry.tab.width / geometry.scale
        displayScale.topOverlap = geometry.topOverlap / geometry.scale
        tab?.setFrame(geometry.tab, display: true)
        detail?.setFrame(geometry.detail, display: true)
        if model.isPulseOpen { detail?.orderFrontRegardless() }

        setIndicatorVisible(visibility.isVisible, force: true)
        pollVisibility()
    }

    func togglePulse() {
        if model.isPulseOpen { model.closePulse() } else { pinDetails() }
    }

    private func pinDetails() {
        setIndicatorVisible(true)
        isPinned = true
        model.isPulseOpen = true
        detail?.makeKeyAndOrderFront(nil)
        if model.connectionStates[.codex] != .connecting {
            Task { [weak model] in await model?.refreshUsage() }
        }
    }

    func shutdown() {
        visibilityTimer = nil
        animationID += 1
        subscriptions.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        tab?.close()
        detail?.close()
        tab = nil
        detail = nil
    }

    private func configureAutoHide() {
        visibilityTimer = nil
        if preferences.autoHide {
            visibilityTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.pollVisibility()
            }
        }
        pollVisibility()
    }

    private func pollVisibility() {
        guard let geometry else { return }
        let pointer = NSEvent.mouseLocation
        let active = geometry.activation.contains(pointer) || (model.isPulseOpen && visibleDetailFrame?.contains(pointer) == true)
        let visible = visibility.update(autoHide: preferences.autoHide, pointerActive: active,
                                        pinned: isPinned, menuOpen: menuOpen,
                                        now: ProcessInfo.processInfo.systemUptime)
        setIndicatorVisible(visible)
    }

    private func setIndicatorVisible(_ visible: Bool, force: Bool = false) {
        guard let tab, let geometry, force || model.islandIsVisible != visible else { return }
        animationID += 1
        let currentID = animationID
        model.islandIsVisible = visible
        tab.ignoresMouseEvents = !visible
        let offset: CGSize = switch preferences.position {
        case .left: CGSize(width: -6 * geometry.scale, height: 0)
        case .right: CGSize(width: 6 * geometry.scale, height: 0)
        case .top: CGSize(width: 0, height: 6 * geometry.scale)
        }
        let hiddenFrame = geometry.tab.offsetBy(dx: offset.width, dy: offset.height)
        if visible {
            if !tab.isVisible { tab.alphaValue = 0; tab.setFrame(hiddenFrame, display: false) }
            tab.orderFrontRegardless()
        } else {
            if !isPinned { model.closePulse() }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            tab.animator().alphaValue = visible ? 1 : 0
            tab.animator().setFrame(visible ? geometry.tab : hiddenFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationID == currentID, !visible else { return }
                self.tab?.orderOut(nil)
            }
        }
    }

    private func closeIfOutside(_ event: NSEvent) {
        guard !menuOpen else { return }
        // The event's receiving window is authoritative, including while the
        // SwiftUI surface is animating inside its stable host. A later global
        // cursor read can refer to a different point (or an accessibility click).
        if event.window !== tab && event.window !== detail {
            model.closePulse()
        }
    }

    private var visibleDetailFrame: CGRect? {
        geometry?.visibleDetail(
            height: CodexEdgeLayout.panelHeight(settings: navigation.showsSettings, snapshot: model.providers.first { $0.id == .codex }),
            position: preferences.position
        )
    }

    private func presentDetail(_ open: Bool) {
        guard let detail else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        let token = withTransaction(transaction) { navigation.beginPresentation(open) }
        if !open {
            isPinned = false
            detail.ignoresMouseEvents = true
        }
        if open {
            detail.ignoresMouseEvents = false
            detail.alphaValue = 0
            detail.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            detail.animator().alphaValue = open ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.navigation.canFinishClosing(token) else { return }
                self.detail?.orderOut(nil)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { self.navigation.finishClosing(token) }
            }
        }
    }

    private func makePanel<Content: View>(_ content: Content) -> NSPanel {
        let panel = CodexEdgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

private final class CodexEdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
