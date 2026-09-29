import Foundation

// Owner: notch-shell. Signatures FROZEN (SPEC §D.2); implementation may be refined.
// Pure geometry in AppKit screen coordinates (origin bottom-left, y grows upwards). Tested on Linux.

public struct NotchGeometry: Sendable, Hashable {
    public let screenFrame: CGRect
    /// The physical notch in screen coordinates.
    public let notchRect: CGRect

    /// - Parameters:
    ///   - screenFrame: `NSScreen.frame`.
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top` (0 ⇒ no notch ⇒ returns nil).
    ///   - auxiliaryTopLeftWidth / auxiliaryTopRightWidth: widths of `auxiliaryTopLeftArea` /
    ///     `auxiliaryTopRightArea` (nil on screens without a notch / macOS 27 below-notch mode).
    public init?(
        screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeftWidth: CGFloat?,
        auxiliaryTopRightWidth: CGFloat?
    ) {
        guard safeAreaTop > 0, screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let width: CGFloat
        if let left = auxiliaryTopLeftWidth, let right = auxiliaryTopRightWidth {
            width = screenFrame.width - left - right
        } else {
            width = NotchMetrics.fallbackNotchSize.width
        }
        guard width > 40, width < screenFrame.width else { return nil }
        let height = safeAreaTop
        // Centre on the gap between the auxiliary areas (equals midX on all current MacBooks).
        let minX: CGFloat
        if let left = auxiliaryTopLeftWidth, auxiliaryTopRightWidth != nil {
            minX = screenFrame.minX + left
        } else {
            minX = screenFrame.midX - width / 2
        }
        self.screenFrame = screenFrame
        self.notchRect = CGRect(x: minX, y: screenFrame.maxY - height, width: width, height: height)
    }

    public var notchSize: CGSize { notchRect.size }

    /// Fixed panel frame: `NotchMetrics.panelSize`, top edge flush with the screen top, centred on the notch.
    public var panelFrame: CGRect {
        let size = NotchMetrics.panelSize
        return CGRect(x: notchRect.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width,
            height: size.height)
    }

    /// Shape size for a presentation. `closedWidthExtra` is the total extra width of closed-state wings
    /// (0 in invisible mode without warning; 2 × islandWingWidth in island mode, …) computed by the shell.
    public func size(for presentation: NotchPresentation, closedWidthExtra: CGFloat = 0) -> CGSize {
        let notch = notchSize
        switch presentation {
        case .closed:
            return CGSize(width: notch.width + max(closedWidthExtra, 0), height: notch.height)
        case .peek(let request):
            switch request.payload {
            case .claudePermission:
                return CGSize(
                    width: max(NotchMetrics.permissionPeekWidth, notch.width + 80),
                    height: notch.height + NotchMetrics.permissionPeekExtraHeight)
            case .claudeSession:
                return CGSize(
                    width: max(NotchMetrics.peekWidth, notch.width + 80),
                    height: notch.height + NotchMetrics.peekExtraHeight)
            }
        case .expanded:
            return CGSize(
                width: max(NotchMetrics.expandedWidth, notch.width + 160),
                height: notch.height + NotchMetrics.expandedExtraHeight)
        }
    }

    /// Screen rect of a top-centred shape of `size` (for hover/leave tests and positioning helpers).
    public func shapeRectInScreen(for size: CGSize) -> CGRect {
        CGRect(x: notchRect.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width,
            height: size.height)
    }

    /// The region that counts as hovering the notch (physical notch + horizontal slack, up to the screen top).
    public func hoverRect(slack: CGFloat = NotchMetrics.hoverSlack) -> CGRect {
        CGRect(x: notchRect.minX - slack, y: notchRect.minY, width: notchRect.width + 2 * slack,
            height: notchRect.height + 1)  // +1: include the very top pixel row (mouse y == maxY)
    }

    /// Converts a screen point into the panel's SwiftUI coordinate space (origin top-left of the panel).
    public func pointInPanel(_ screenPoint: CGPoint) -> CGPoint {
        let frame = panelFrame
        return CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
    }
}
