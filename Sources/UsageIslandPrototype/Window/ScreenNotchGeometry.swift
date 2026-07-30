import AppKit

public struct ScreenNotchGeometry: Sendable {
    public let screenFrame: CGRect
    public let notchFrame: CGRect
    public let leftAuxiliaryArea: CGRect
    public let rightAuxiliaryArea: CGRect
    public let menuBarHeight: CGFloat
    public let hasHardwareNotch: Bool

    @MainActor
    public static func resolve(for screen: NSScreen) -> ScreenNotchGeometry {
        let screenFrame = screen.frame
        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            let notch = CGRect(
                x: left.maxX,
                y: min(left.minY, right.minY),
                width: max(1, right.minX - left.maxX),
                height: max(left.height, right.height)
            )

            return .init(
                screenFrame: screenFrame,
                notchFrame: notch,
                leftAuxiliaryArea: left,
                rightAuxiliaryArea: right,
                menuBarHeight: menuBarHeight,
                hasHardwareNotch: true
            )
        }

        let syntheticWidth: CGFloat = 150
        let syntheticNotch = CGRect(
            x: screenFrame.midX - syntheticWidth / 2,
            y: screenFrame.maxY - menuBarHeight,
            width: syntheticWidth,
            height: menuBarHeight
        )

        return .init(
            screenFrame: screenFrame,
            notchFrame: syntheticNotch,
            leftAuxiliaryArea: CGRect(x: screenFrame.minX, y: syntheticNotch.minY, width: syntheticNotch.minX - screenFrame.minX, height: menuBarHeight),
            rightAuxiliaryArea: CGRect(x: syntheticNotch.maxX, y: syntheticNotch.minY, width: screenFrame.maxX - syntheticNotch.maxX, height: menuBarHeight),
            menuBarHeight: menuBarHeight,
            hasHardwareNotch: false
        )
    }
}
