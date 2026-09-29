// Owner: notch-shell (SPEC §A.2, §A.3, §A.5, §D.5).
//
// Root view of the notch panel. One continuous surface morphs between the states:
// * closed: pure black NotchShape over the hardware notch (+ island wings from `NotchSlots`), no glass;
// * peek / expanded: real Liquid Glass (`.glassEffect(.regular, in: NotchShape)`) under a black gradient that
//   is solid down to the notch height and clear at ~65 %, so the top merges into the hardware notch and the
//   wallpaper shines through below. Glass is switched with `.identity`, never by removing the modifier;
//   it is never tinted black (macOS 27 renders dark tints opaque). Solid-black style / Reduce Transparency
//   use `.identity` + a black fill.
import Foundation
import SuperNotchCore
import SwiftUI

struct NotchContainerView: View {
    @Environment(NotchViewModel.self) private var notch
    @Environment(SettingsStore.self) private var store
    @Environment(MediaModel.self) private var media
    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(ShelfModel.self) private var shelf
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {}

    var body: some View {
        let settings = store.settings
        let wings = NotchClosedWings(NotchSlots.closedWings(settings: settings, media: media, claude: claude))
        let usesGlass = settings.notchStyle.usesGlass(reduceTransparency: reduceTransparency)
        ZStack(alignment: .top) {
            if let geometry = notch.geometry {
                NotchSurfaceView(
                    geometry: geometry,
                    presentation: notch.presentation,
                    wings: wings,
                    glass: DesignTokens.GlassLook.glass(
                        style: settings.notchStyle, reduceTransparency: reduceTransparency),
                    usesGlass: usesGlass,
                    reduceMotion: reduceMotion)
            }
        }
        .frame(width: NotchMetrics.panelSize.width, height: NotchMetrics.panelSize.height, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onChange(of: wings, initial: true) { _, value in
            notch.updateClosedWings(value)
        }
        .onChange(of: shelf.isDragActive, initial: true) { _, active in
            notch.setFileDragActive(active)
        }
    }
}

// MARK: - Surface

private struct NotchSurfaceView: View {
    let geometry: NotchGeometry
    let presentation: NotchPresentation
    let wings: NotchClosedWings
    let glass: Glass
    let usesGlass: Bool
    let reduceMotion: Bool

    var body: some View {
        let kind = NotchPresentationKind(presentation)
        let radii = NotchShape.radii(for: kind)
        let shape = NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
        let size = geometry.size(for: presentation, closedWidthExtra: wings.total)
        let isOpen = kind != .closed
        let notchHeight = geometry.notchSize.height

        NotchSurfaceContent(presentation: presentation, notchSize: geometry.notchSize, wings: wings)
            .frame(width: size.width, height: size.height, alignment: .top)
            // The concave shoulders sit outside the body (NotchGeometry convention).
            .padding(.horizontal, radii.top)
            .background {
                ZStack {
                    DesignTokens.GlassLook.gradient(notchHeight: notchHeight, shapeHeight: size.height)
                    DesignTokens.GlassLook.solidFill
                        .opacity(isOpen && usesGlass ? 0 : 1)
                }
            }
            .clipShape(shape)
            .glassEffect(isOpen ? glass : .identity, in: shape)
            .overlay {
                if let request = presentation.peekRequest, request.priority == .critical {
                    NotchCriticalGlow(shape: shape, isAnimated: !reduceMotion)
                }
            }
            .contentShape(shape)
            // A lone right wing (usage warning) shifts the closed shape; the physical notch never moves.
            .offset(x: kind == .closed ? wings.centerOffset : 0)
            .animation(morphAnimation, value: presentation)
            .animation(reduceMotion ? nil : DesignTokens.Motion.open, value: wings)
    }

    private var morphAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        return presentation.isClosed ? DesignTokens.Motion.close : DesignTokens.Motion.open
    }
}

private struct NotchSurfaceContent: View {
    let presentation: NotchPresentation
    let notchSize: CGSize
    let wings: NotchClosedWings

    var body: some View {
        switch presentation {
        case .closed:
            NotchClosedContent(notchSize: notchSize, wings: wings)
                .transition(Self.contentTransition)
        case .peek(let request):
            NotchPeekContent(request: request, notchHeight: notchSize.height)
                .transition(Self.contentTransition)
        case .expanded(let tab):
            NotchExpandedContent(tab: tab, notchSize: notchSize)
                .transition(Self.contentTransition)
        }
    }

    /// Content fades in 0.06 s after the shape starts moving and fades out quickly before it closes (§A.2).
    static let contentTransition = AnyTransition.asymmetric(
        insertion: AnyTransition.opacity.animation(DesignTokens.Motion.contentFadeIn),
        removal: AnyTransition.opacity.animation(DesignTokens.Motion.contentFadeOut))
}

// MARK: - Closed

/// The closed notch: black, with the island wings left and right of the hardware notch. A click opens the
/// notch and focuses it (explicit interaction).
private struct NotchClosedContent: View {
    @Environment(NotchViewModel.self) private var notch
    let notchSize: CGSize
    let wings: NotchClosedWings

    var body: some View {
        HStack(spacing: 0) {
            NotchSlots.islandLeading()
                .frame(width: wings.leading, height: notchSize.height)
                .clipped()
            Color.clear
                .frame(width: notchSize.width, height: notchSize.height)
            NotchSlots.islandTrailing()
                .frame(width: wings.trailing, height: notchSize.height)
                .clipped()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            notch.open(tab: nil, focus: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SuperNotch")
        .accessibilityHint("Opens the notch")
        .accessibilityAction {
            notch.open(tab: nil, focus: true)
        }
    }
}

// MARK: - Peek

private struct NotchPeekContent: View {
    let request: PopupRequest
    let notchHeight: CGFloat

    var body: some View {
        GlassEffectContainer(spacing: DesignTokens.Spacing.m) {
            VStack(spacing: 0) {
                // Top band: stays black and empty around the hardware notch.
                Color.clear
                    .frame(height: notchHeight)
                NotchSlots.peek(request)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, NotchMetrics.contentPadding)
                    .padding(.bottom, NotchMetrics.contentPadding)
            }
        }
    }
}

// MARK: - Expanded

private struct NotchExpandedContent: View {
    let tab: NotchTab
    let notchSize: CGSize

    var body: some View {
        // One container for the whole expanded content so glass buttons (play/pause, AirDrop) blend (§A.3).
        GlassEffectContainer(spacing: DesignTokens.Spacing.m) {
            VStack(spacing: 0) {
                NotchHeaderView(selectedTab: tab, notchWidth: notchSize.width)
                    .frame(height: notchSize.height)
                NotchSlots.tab(tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, NotchMetrics.contentPadding)
                    .padding(.bottom, NotchMetrics.contentPadding)
            }
        }
    }
}

// MARK: - 🔴 glow

/// Subtle red pulse along the edge of a critical peek (§A.6). 30 fps cap, exists only while the peek is on
/// screen (SPEC §F.1); static with Reduce Motion.
private struct NotchCriticalGlow: View {
    let shape: NotchShape
    let isAnimated: Bool

    var body: some View {
        Group {
            if isAnimated {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    glow(intensity: Self.intensity(at: context.date))
                }
            } else {
                glow(intensity: 0.6)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(intensity: Double) -> some View {
        shape
            .stroke(DesignTokens.Colors.trafficRed.opacity(0.2 + 0.5 * intensity), lineWidth: 3)
            .clipShape(shape)
    }

    private static func intensity(at date: Date) -> Double {
        let period = 1.6
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return 0.5 - 0.5 * cos(phase * 2 * Double.pi)
    }
}
