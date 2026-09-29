// Owner: notch-shell (SPEC §A.2, §A.3).
//
// The notch outline: concave "shoulders" at the top that flare into the screen edge exactly like the hardware
// notch, straight sides, and rounded bottom corners. Both radii are animatable, so the closed → peek →
// expanded morph is one continuous spring.
//
// Geometry convention (see NotchGeometry): the shoulders sit OUTSIDE the notch body. A shape drawn in a rect
// of width `body + 2 × topCornerRadius` has a body of exactly `body` points between its straight sides.
//
// Adapted from DynamicNotchKit's `NotchShape` (MIT, © 2025 Kai Azim), which uses the same quad-curve outline.
import SuperNotchCore
import SwiftUI

/// `nonisolated`: SwiftUI may evaluate shape paths off the main actor; the app target defaults to MainActor.
nonisolated struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Clamp so extreme animation frames (spring overshoot, tiny rects) never produce a crossed path.
        let top = max(0, min(topCornerRadius, rect.width / 4, rect.height / 2))
        let bodyWidth = rect.width - 2 * top
        let bottom = max(0, min(bottomCornerRadius, bodyWidth / 2, rect.height - top))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left shoulder: from the screen edge down into the left side.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        // Bottom-left corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        // Bottom-right corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // Right shoulder.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

extension NotchShape {
    /// Radii per presentation (SPEC §A.2: closed 6/12, peek 10/20, expanded 12/24).
    static func radii(for presentation: NotchPresentationKind) -> (top: CGFloat, bottom: CGFloat) {
        switch presentation {
        case .closed: return (NotchMetrics.closedRadii.top, NotchMetrics.closedRadii.bottom)
        case .peek: return (NotchMetrics.peekRadii.top, NotchMetrics.peekRadii.bottom)
        case .expanded: return (NotchMetrics.expandedRadii.top, NotchMetrics.expandedRadii.bottom)
        }
    }

    init(for presentation: NotchPresentationKind) {
        let radii = Self.radii(for: presentation)
        self.init(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
    }
}

/// The three visual families of `NotchPresentation` (payload-free, for radii and styling).
nonisolated enum NotchPresentationKind: Hashable, Sendable {
    case closed
    case peek
    case expanded

    init(_ presentation: NotchPresentation) {
        switch presentation {
        case .closed: self = .closed
        case .peek: self = .peek
        case .expanded: self = .expanded
        }
    }
}
