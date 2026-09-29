// Owner: FOUNDATION (SPEC §A.2, §A.3, §D.10). Colours, fonts, spacing, motion and the glass look.
//
// Sizes that the layout depends on (notch sizes, radii, columns, rows) live in `NotchMetrics` (Core) so they
// are testable; this file only turns them into SwiftUI values. The notch panel is always dark
// (`.environment(\.colorScheme, .dark)`), so the colours below are designed for a black/glass background.
import SuperNotchCore
import SwiftUI

enum DesignTokens {

    // MARK: - Colours

    enum Colors {
        /// Hardware-notch black: closed shape, top band, solid-black style.
        static let notchBlack = Color.black

        static let primaryText = Color.white
        static let secondaryText = Color.white.opacity(0.62)
        static let tertiaryText = Color.white.opacity(0.38)
        /// Separators between the Home columns and list sections.
        static let hairline = Color.white.opacity(0.12)
        /// Row / tile hover background.
        static let hoverFill = Color.white.opacity(0.08)
        /// Row / tile pressed or selected background.
        static let selectedFill = Color.white.opacity(0.14)
        /// Neutral control background (small buttons, drop zones at rest).
        static let controlFill = Color.white.opacity(0.10)
        /// Unfilled part of progress and usage bars.
        static let trackFill = Color.white.opacity(0.18)
        /// Filled part of the progress bar and neutral usage bars.
        static let barFill = Color.white.opacity(0.85)

        // Traffic lights: macOS dark-appearance system colours, fixed so they never shift with the glass tint.
        /// 🔴 needs you (#FF453A).
        static let trafficRed = Color(.sRGB, red: 1.0, green: 0.271, blue: 0.227, opacity: 1)
        /// 🟡 working (#FFD60A).
        static let trafficYellow = Color(.sRGB, red: 1.0, green: 0.839, blue: 0.039, opacity: 1)
        /// 🟢 done (#30D158).
        static let trafficGreen = Color(.sRGB, red: 0.188, green: 0.820, blue: 0.345, opacity: 1)
        /// Idle / unknown (#8E8E93).
        static let trafficGrey = Color(.sRGB, red: 0.557, green: 0.557, blue: 0.576, opacity: 1)

        /// Usage warning (≥ threshold) and the closed-notch warning dot (#FF9F0A).
        static let warningOrange = Color(.sRGB, red: 1.0, green: 0.624, blue: 0.039, opacity: 1)
        /// Links, focused controls (#0A84FF).
        static let accent = Color(.sRGB, red: 0.039, green: 0.518, blue: 1.0, opacity: 1)
        /// Dangerous permission requests: text/border and the card tint.
        static let danger = trafficRed
        static let dangerTint = trafficRed.opacity(0.16)
        /// Drop zone highlight while a file hovers over it.
        static let dropHighlight = accent.opacity(0.28)

        /// The dot colour for a session's traffic light.
        static func trafficLight(_ light: TrafficLight) -> Color {
            switch light {
            case .grey: return trafficGrey
            case .green: return trafficGreen
            case .yellow: return trafficYellow
            case .red: return trafficRed
            }
        }

        /// Usage bar colour (§D.9): neutral below the threshold, orange at the threshold, red at ≥ 95 %.
        /// - Parameters:
        ///   - fraction: 0…1 of the window used.
        ///   - threshold: `AppSettings.usageWarningThreshold` (0…1).
        static func usage(fraction: Double, threshold: Double) -> Color {
            if fraction >= 0.95 { return trafficRed }
            if fraction >= threshold { return warningOrange }
            return barFill
        }
    }

    // MARK: - Fonts (SF Pro; compact sizes for a small notch)

    enum Fonts {
        /// Track title, peek headline.
        static let title = Font.system(size: 13, weight: .semibold)
        /// Default text.
        static let body = Font.system(size: 12, weight: .regular)
        static let bodyEmphasized = Font.system(size: 12, weight: .medium)
        /// Session row title.
        static let rowTitle = Font.system(size: 12, weight: .medium)
        /// Row metadata ("2m", "now"), times, percentages.
        static let rowMeta = Font.system(size: 10.5, weight: .regular).monospacedDigit()
        /// Artist, project name, small labels.
        static let caption = Font.system(size: 10.5, weight: .medium)
        /// Tiny labels ("5h", "7d").
        static let micro = Font.system(size: 9, weight: .semibold)
        /// Bash commands on the permission card.
        static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
        /// Tab icons and the gear in the top band.
        static let tabIcon = Font.system(size: 12, weight: .semibold)
        /// Transport controls (⏮ ⏯ ⏭).
        static let transport = Font.system(size: 14, weight: .semibold)
        static let transportPrimary = Font.system(size: 18, weight: .semibold)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        /// Horizontal inset of tab/peek content inside the shape (applied by the shell).
        static let content: CGFloat = NotchMetrics.contentPadding
        /// Gap on each side of the hairline between the Home columns.
        static let columnGap: CGFloat = 10
    }

    // MARK: - Corner radii

    enum Radius {
        /// Island artwork (22 pt), small chips.
        static let small: CGFloat = NotchMetrics.islandArtworkCornerRadius
        /// Buttons, rows, Home artwork (56 pt).
        static let medium: CGFloat = 8
        /// Shelf tiles, drop zones, permission card.
        static let large: CGFloat = 12
    }

    // MARK: - Sizes

    enum Size {
        /// Tap target for small icon buttons (gear, tab icons, row actions).
        static let iconButton: CGFloat = 22
        /// Traffic-light dot in session rows.
        static let rowDot: CGFloat = 7
        static let hairline: CGFloat = 1
    }

    // MARK: - Motion (§A.2)

    enum Motion {
        /// Opening morph (closed → peek/expanded).
        static let open = Animation.spring(
            response: NotchMetrics.openSpringResponse, dampingFraction: NotchMetrics.openSpringDamping)
        /// Closing morph (→ closed). No bounce.
        static let close = Animation.spring(
            response: NotchMetrics.closeSpringResponse, dampingFraction: NotchMetrics.closeSpringDamping)
        /// Content fade-in after the shape starts opening.
        static let contentFadeIn = Animation.easeOut(duration: 0.18).delay(NotchMetrics.contentFadeInDelay)
        /// Content fade-out before the shape closes.
        static let contentFadeOut = Animation.easeIn(duration: 0.10)
        /// Hover highlights.
        static let hover = Animation.easeOut(duration: 0.12)
        /// 🟡 working pulse and 🔴 glow (run only while visible, SPEC §F.1).
        static let pulse = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
    }

    // MARK: - Glass look (§A.3)

    /// Alias kept for code written against an early draft of SPEC §D.10 (`DesignTokens.Glass.…`).
    /// Inside `DesignTokens` write `SwiftUI.Glass` for the SwiftUI material type.
    typealias Glass = GlassLook

    enum GlassLook {
        /// Black at the top (merges into the hardware notch) fading to clear at ~65 % of the shape height.
        /// Use as the content's `.background` inside the glass shape of peek/expanded.
        static func gradient(notchHeight: CGFloat, shapeHeight: CGFloat) -> LinearGradient {
            let stops = NotchMetrics.glassGradientStops(notchHeight: notchHeight, shapeHeight: shapeHeight)
            return LinearGradient(
                stops: [
                    Gradient.Stop(color: .black, location: 0),
                    Gradient.Stop(color: .black, location: stops.solidEnd),
                    Gradient.Stop(color: .clear, location: stops.clearAt),
                ],
                startPoint: .top,
                endPoint: .bottom)
        }

        /// `.glassEffect(DesignTokens.GlassLook.glass(style:reduceTransparency:), in: shape)`: switch glass
        /// on and off with `.identity`, never by adding/removing the modifier.
        static func glass(style: NotchStyle, reduceTransparency: Bool) -> SwiftUI.Glass {
            usesGlass(style: style, reduceTransparency: reduceTransparency) ? .regular : .identity
        }

        /// Whether peek/expanded use real glass (`NotchStyle.usesGlass(reduceTransparency:)`).
        static func usesGlass(style: NotchStyle, reduceTransparency: Bool) -> Bool {
            style.usesGlass(reduceTransparency: reduceTransparency)
        }

        /// Fill behind the content when glass is off (solid-black style, Reduce Transparency, closed state).
        static let solidFill = Color.black
    }
}
