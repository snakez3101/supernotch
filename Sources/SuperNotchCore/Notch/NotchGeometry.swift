import Foundation

// Owner: notch-shell. Signatures FROZEN (SPEC §D.2); implementation may be refined.
// Pure geometry in AppKit screen coordinates (origin bottom-left, y grows upwards). Tested on Linux.
//
// Shape convention: a "shape size" is the size of the notch BODY (what `size(for:)` returns and what hit
// tests use). `NotchShape` additionally draws its concave top shoulders `topCornerRadius` outside the body on
// each side, exactly like the hardware notch flares into the screen edge.

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
        guard safeAreaTop > 0, safeAreaTop < screenFrame.height / 4, screenFrame.width > 0,
            screenFrame.height > 0
        else { return nil }
        let width: CGFloat
        let minX: CGFloat
        if let left = auxiliaryTopLeftWidth, let right = auxiliaryTopRightWidth, left > 0, right > 0 {
            width = screenFrame.width - left - right
            // Centre on the gap between the auxiliary areas (equals midX on all current MacBooks).
            minX = screenFrame.minX + left
        } else {
            width = NotchMetrics.fallbackNotchSize.width
            minX = screenFrame.midX - width / 2
        }
        guard width > 40, width < screenFrame.width / 2 else { return nil }
        let height = safeAreaTop
        self.screenFrame = screenFrame
        self.notchRect = CGRect(x: minX, y: screenFrame.maxY - height, width: width, height: height)
    }

    public var notchSize: CGSize { notchRect.size }

    /// Fixed panel frame: `NotchMetrics.panelSize`, top edge flush with the screen top, centred on the notch.
    public var panelFrame: CGRect {
        let size = NotchMetrics.panelSize
        return CGRect(
            x: notchRect.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width,
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

    /// Shape size for a presentation with (possibly asymmetric) closed wings.
    public func size(for presentation: NotchPresentation, wings: NotchClosedWings) -> CGSize {
        size(for: presentation, closedWidthExtra: wings.total)
    }

    /// Screen rect of a top-centred shape of `size` (for hover/leave tests and positioning helpers).
    public func shapeRectInScreen(for size: CGSize) -> CGRect {
        CGRect(
            x: notchRect.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width,
            height: size.height)
    }

    /// Screen rect of the current shape body. Closed shapes follow their wings (a lone right wing shifts the
    /// shape to the right; the physical notch never moves); open shapes are centred on the notch.
    public func shapeRectInScreen(for presentation: NotchPresentation, wings: NotchClosedWings) -> CGRect {
        let rect = shapeRectInScreen(for: size(for: presentation, wings: wings))
        guard presentation.isClosed else { return rect }
        return rect.offsetBy(dx: wings.centerOffset, dy: 0)
    }

    /// The region that counts as hovering the notch (physical notch + horizontal slack, up to the screen top).
    public func hoverRect(slack: CGFloat = NotchMetrics.hoverSlack) -> CGRect {
        CGRect(
            x: notchRect.minX - slack, y: notchRect.minY, width: notchRect.width + 2 * slack,
            height: notchRect.height + 1)  // +1: include the very top pixel row (mouse y == maxY)
    }

    /// The region the pointer may wander in before the close grace timer starts: the shape rect plus
    /// `margin` on the left, right and bottom (and one extra row above the screen top edge).
    public func leaveRect(for shapeRect: CGRect, margin: CGFloat = NotchMetrics.leaveMargin) -> CGRect {
        CGRect(
            x: shapeRect.minX - margin, y: shapeRect.minY - margin, width: shapeRect.width + 2 * margin,
            height: shapeRect.height + margin + 1)
    }

    /// Converts a screen point into the panel's SwiftUI coordinate space (origin top-left of the panel).
    public func pointInPanel(_ screenPoint: CGPoint) -> CGPoint {
        let frame = panelFrame
        return CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
    }

    /// A screen rect in the panel's SwiftUI coordinate space (origin top-left of the panel).
    public func rectInPanel(_ screenRect: CGRect) -> CGRect {
        let frame = panelFrame
        return CGRect(
            x: screenRect.minX - frame.minX, y: frame.maxY - screenRect.maxY, width: screenRect.width,
            height: screenRect.height)
    }

    /// True when the notch sits on the given display frame (used to ignore fullscreen apps on other screens).
    public func isOnScreen(frame: CGRect) -> Bool {
        abs(frame.minX - screenFrame.minX) < 1 && abs(frame.minY - screenFrame.minY) < 1
            && abs(frame.width - screenFrame.width) < 1 && abs(frame.height - screenFrame.height) < 1
    }
}

// MARK: - Closed wings

/// Extra width left and right of the physical notch while closed (SPEC §A.2).
public struct NotchClosedWings: Sendable, Hashable {
    public var leading: CGFloat
    public var trailing: CGFloat

    public init(leading: CGFloat = 0, trailing: CGFloat = 0) {
        self.leading = max(leading, 0)
        self.trailing = max(trailing, 0)
    }

    public static let none = NotchClosedWings()

    public var total: CGFloat { leading + trailing }
    public var isEmpty: Bool { total == 0 }
    /// Horizontal offset of the closed shape's centre relative to the notch centre.
    public var centerOffset: CGFloat { (trailing - leading) / 2 }

    /// - Parameters:
    ///   - mode: the user's closed style.
    ///   - hasIslandContent: Spotify has a track or a Claude session is active.
    ///   - showsUsageWarning: usage ≥ threshold (orange dot).
    public static func resolve(mode: ClosedNotchMode, hasIslandContent: Bool, showsUsageWarning: Bool)
        -> NotchClosedWings
    {
        if mode == .island && hasIslandContent {
            return NotchClosedWings(leading: NotchMetrics.islandWingWidth, trailing: NotchMetrics.islandWingWidth)
        }
        // Invisible mode (or island mode with nothing to show): exactly the notch, plus a small right wing
        // for the usage warning dot.
        return showsUsageWarning ? NotchClosedWings(trailing: NotchMetrics.warningWingWidth) : .none
    }
}

// MARK: - Fullscreen heuristic (SPEC §A.8)

/// One on-screen window as reported by `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`. Bounds are in
/// Quartz global coordinates (origin top-left of the primary display, y grows downwards). None of these
/// fields needs the Screen Recording permission.
public struct NotchWindowSample: Sendable, Hashable {
    public var ownerPID: Int32
    public var layer: Int
    public var bounds: CGRect

    public init(ownerPID: Int32, layer: Int, bounds: CGRect) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
    }
}

public enum NotchFullscreenHeuristic {
    /// `kCGMainMenuWindowLevel` (the menu bar window's layer).
    public static let mainMenuLayer = 24
    /// Points of slack for frame comparisons.
    public static let tolerance: CGFloat = 2

    /// Converts an AppKit screen rect (origin bottom-left of the primary display) into Quartz global
    /// coordinates (origin top-left of the primary display).
    public static func quartzRect(fromAppKit rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// True when the frontmost app shows a fullscreen window on the notch screen.
    ///
    /// A window counts when it belongs to the frontmost app, sits at layer 0, and either covers the whole
    /// screen, or covers the screen below the notch band (macOS places native fullscreen windows below the
    /// camera housing by default). The second shape is also what a zoomed window looks like when the Dock is
    /// hidden, so it only counts while the menu bar is not on screen (it auto-hides in fullscreen spaces).
    ///
    /// - Parameters:
    ///   - windows: on-screen windows, front to back.
    ///   - frontmostPID: pid of `NSWorkspace.frontmostApplication`.
    ///   - screenFrame: the notch screen's frame in Quartz coordinates.
    ///   - notchHeight: `safeAreaInsets.top` of the notch screen.
    public static func isFullscreen(
        windows: [NotchWindowSample], frontmostPID: Int32, screenFrame: CGRect, notchHeight: CGFloat
    ) -> Bool {
        let t = tolerance
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= t }
        var belowNotchCandidate = false
        for window in windows where window.ownerPID == frontmostPID && window.layer == 0 {
            let b = window.bounds
            guard close(b.minX, screenFrame.minX), close(b.width, screenFrame.width),
                close(b.maxY, screenFrame.maxY)
            else { continue }
            if close(b.minY, screenFrame.minY) { return true }
            if notchHeight > 0, close(b.minY, screenFrame.minY + notchHeight) { belowNotchCandidate = true }
        }
        guard belowNotchCandidate else { return false }
        let menuBarVisible = windows.contains { window in
            window.layer == mainMenuLayer && window.bounds.width > 0
                && window.bounds.intersects(screenFrame) && close(window.bounds.minY, screenFrame.minY)
        }
        return !menuBarVisible
    }
}
