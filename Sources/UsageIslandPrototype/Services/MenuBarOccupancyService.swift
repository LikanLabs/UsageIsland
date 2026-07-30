import AppKit
import ApplicationServices

public struct MenuBarOccupancy: Sendable {
    public var leftOccupiedMaxX: CGFloat
    public var rightOccupiedMinX: CGFloat
    public var isAccessibilityTrusted: Bool
}

@MainActor
public final class MenuBarOccupancyService {
    public init() {}

    public func requestAccessibilityPermission() {
        // Swift 6.4 treats the imported kAXTrustedCheckOptionPrompt symbol as
        // shared mutable state. Its documented Core Foundation key is stable,
        // so construct the key locally instead of referencing the global var.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func measure(for geometry: ScreenNotchGeometry) -> MenuBarOccupancy {
        let trusted = AXIsProcessTrusted()

        guard trusted else {
            return conservativeFallback(for: geometry, trusted: false)
        }

        let frontmostBoundary = frontmostApplicationMenuBoundary(in: geometry.screenFrame)
        let systemBoundary = systemStatusBoundary(in: geometry.screenFrame)

        return MenuBarOccupancy(
            leftOccupiedMaxX: frontmostBoundary ?? conservativeFallback(for: geometry, trusted: true).leftOccupiedMaxX,
            rightOccupiedMinX: systemBoundary ?? conservativeFallback(for: geometry, trusted: true).rightOccupiedMinX,
            isAccessibilityTrusted: true
        )
    }

    private func conservativeFallback(for geometry: ScreenNotchGeometry, trusted: Bool) -> MenuBarOccupancy {
        // Prototype fallback: leave large safety zones for menus and status items.
        // Production should hide a wing whenever occupancy cannot be measured confidently.
        let left = max(geometry.leftAuxiliaryArea.minX + 280, geometry.notchFrame.minX - 110)
        let right = min(geometry.rightAuxiliaryArea.maxX - 240, geometry.notchFrame.maxX + 90)
        return .init(leftOccupiedMaxX: left, rightOccupiedMinX: right, isAccessibilityTrusted: trusted)
    }

    private func frontmostApplicationMenuBoundary(in screenFrame: CGRect) -> CGFloat? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(application.processIdentifier)
        guard let menuBar = axElementAttribute(axApp, kAXMenuBarAttribute as CFString) else { return nil }

        let frames = childFrames(of: menuBar)
            .filter { screenFrame.intersects($0) }

        return frames.map(\.maxX).max()
    }

    private func systemStatusBoundary(in screenFrame: CGRect) -> CGFloat? {
        guard let systemUI = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.SystemUIServer").first else {
            return nil
        }

        let axApp = AXUIElementCreateApplication(systemUI.processIdentifier)
        guard let menuBar = axElementAttribute(axApp, kAXMenuBarAttribute as CFString) else { return nil }

        let frames = childFrames(of: menuBar)
            .filter { screenFrame.intersects($0) }

        return frames.map(\.minX).min()
    }


    private func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = elementAttribute(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        // AXUIElement is a Core Foundation reference type. After validating its
        // runtime type ID, this conversion avoids Swift 6.4's invalid
        // conditional-downcast diagnostic for CF types.
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    private func childFrames(of element: AXUIElement) -> [CGRect] {
        guard let children = elementAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] else {
            return []
        }
        return children.compactMap(frame(of:))
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = elementAttribute(element, kAXPositionAttribute as CFString),
              let sizeRef = elementAttribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }

        // Only x-coordinates are used for occupancy decisions. AX and AppKit share x orientation.
        return CGRect(origin: position, size: size)
    }
}
