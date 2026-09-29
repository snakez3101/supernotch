import Foundation

// FOUNDATION-OWNED (SPEC §A.2). Every size/radius/timing the streams design against.
// Deliberately compact: the user does NOT want a big fat notch.

public enum NotchMetrics {
    // MARK: Panel
    /// Fixed NSPanel size; SwiftUI morphs the shape inside it (top-centred). Must contain the largest state
    /// plus spring overshoot.
    public static let panelSize = CGSize(width: 580, height: 340)

    // MARK: Closed
    /// Island-mode wing width on each side of the physical notch.
    public static let islandWingWidth: CGFloat = 36
    /// Invisible-mode right wing that only appears for the usage warning dot.
    public static let warningWingWidth: CGFloat = 14
    public static let islandArtworkSize: CGFloat = 22
    public static let islandArtworkCornerRadius: CGFloat = 5
    public static let islandVisualizerSize = CGSize(width: 20, height: 14)
    public static let claudeDotDiameter: CGFloat = 6
    public static let claudeDotSpacing: CGFloat = 3
    public static let claudeMaxDots = 4
    public static let warningDotDiameter: CGFloat = 5

    // MARK: Peek (auto popups). Height = notch height + extra.
    public static let peekWidth: CGFloat = 420
    public static let peekExtraHeight: CGFloat = 64
    public static let permissionPeekWidth: CGFloat = 480
    public static let permissionPeekExtraHeight: CGFloat = 128

    // MARK: Expanded. Height = notch height + extra.
    public static let expandedWidth: CGFloat = 540
    public static let expandedExtraHeight: CGFloat = 156
    /// Horizontal content padding inside the expanded shape (in addition to the top flare).
    public static let contentPadding: CGFloat = 14
    public static let musicColumnWidth: CGFloat = 200
    public static let claudeRowHeight: CGFloat = 26
    public static let claudeVisibleRows = 4
    public static let usageBarHeight: CGFloat = 3
    public static let shelfTileSize: CGFloat = 64
    public static let homeArtworkSize: CGFloat = 56

    // MARK: Shape radii (NotchShape topCornerRadius / bottomCornerRadius)
    public static let closedRadii = (top: CGFloat(6), bottom: CGFloat(12))
    public static let peekRadii = (top: CGFloat(10), bottom: CGFloat(20))
    public static let expandedRadii = (top: CGFloat(12), bottom: CGFloat(24))

    // MARK: Fallback notch size when a screen reports a notch but no auxiliary areas (should not happen).
    public static let fallbackNotchSize = CGSize(width: 185, height: 32)

    // MARK: Timings
    public static let openSpringResponse: Double = 0.42
    public static let openSpringDamping: Double = 0.80
    public static let closeSpringResponse: Double = 0.45
    public static let closeSpringDamping: Double = 1.0
    /// Horizontal slack around the physical notch counted as "hovering the notch".
    public static let hoverSlack: CGFloat = 6
    /// Extra margin around the open shape before the close grace timer starts.
    public static let leaveMargin: CGFloat = 8
    /// 🟢→🟡 within this window never pops up.
    public static let popupDebounce: TimeInterval = 0.8
    /// Second click window for dangerous permission confirmation.
    public static let dangerConfirmWindow: TimeInterval = 4
}
