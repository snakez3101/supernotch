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
    /// Content fades in this long after the shape starts to open (§A.2).
    public static let contentFadeInDelay: Double = 0.06

    // MARK: Closed-state wings (§A.2). Single source of truth for the closed shape's width.

    /// Extra width left and right of the physical notch while closed:
    /// - island mode with something to show: `islandWingWidth` on both sides (artwork left, visualizer/dots right);
    /// - otherwise, while the usage warning shows: `warningWingWidth` on the **right** only (the orange dot);
    /// - otherwise none (looks exactly like the hardware notch).
    /// The shape is asymmetric in the warning case: its centre sits `(trailing - leading) / 2` right of the
    /// notch centre (`NotchClosedWings.centerOffset`). The physical notch never moves.
    /// - Parameter hasIslandContent: a track is playing, or a Claude session is 🟡 working or 🔴 needs you
    ///   (see `NotchSlots.hasIslandContent` in the app).
    public static func closedWings(
        mode: ClosedNotchMode, hasIslandContent: Bool, showsUsageWarning: Bool
    ) -> (leading: CGFloat, trailing: CGFloat) {
        if mode == .island && hasIslandContent { return (islandWingWidth, islandWingWidth) }
        if showsUsageWarning { return (0, warningWingWidth) }
        return (0, 0)
    }

    /// Total closed wing width (`leading + trailing`), for `NotchGeometry.size(for:closedWidthExtra:)`.
    public static func closedWidthExtra(
        mode: ClosedNotchMode, hasIslandContent: Bool, showsUsageWarning: Bool
    ) -> CGFloat {
        let wings = closedWings(mode: mode, hasIslandContent: hasIslandContent, showsUsageWarning: showsUsageWarning)
        return wings.leading + wings.trailing
    }

    // MARK: Glass look (§A.3)

    /// Unit location (0 = top of the shape, 1 = bottom) where the black gradient becomes fully clear.
    public static let glassClearLocation: Double = 0.65
    /// Minimum distance between the end of the solid band and the clear stop, so the fade stays soft.
    public static let glassMinimumFade: Double = 0.2

    /// Gradient stops for the black band that merges the glass into the hardware notch.
    public struct GlassGradientStops: Sendable, Hashable {
        /// Solid black from 0 down to here (the notch height).
        public let solidEnd: Double
        /// Fully clear from here down.
        public let clearAt: Double

        public init(solidEnd: Double, clearAt: Double) {
            self.solidEnd = solidEnd
            self.clearAt = clearAt
        }

        // Explicit so the conformance is identical on Linux and Apple platforms.
        public static func == (lhs: GlassGradientStops, rhs: GlassGradientStops) -> Bool {
            lhs.solidEnd == rhs.solidEnd && lhs.clearAt == rhs.clearAt
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(solidEnd)
            hasher.combine(clearAt)
        }
    }

    /// Solid black down to the notch height, clear at about 65 % of the shape height (never less than
    /// `glassMinimumFade` below the solid band). Always returns 0 ≤ solidEnd < clearAt ≤ 1.
    public static func glassGradientStops(notchHeight: CGFloat, shapeHeight: CGFloat) -> GlassGradientStops {
        guard shapeHeight > 0, notchHeight.isFinite, shapeHeight.isFinite else {
            return GlassGradientStops(solidEnd: 0, clearAt: glassClearLocation)
        }
        let solid = min(max(Double(notchHeight / shapeHeight), 0), 1 - glassMinimumFade)
        let clear = min(max(glassClearLocation, solid + glassMinimumFade), 1)
        return GlassGradientStops(solidEnd: solid, clearAt: clear)
    }
}
