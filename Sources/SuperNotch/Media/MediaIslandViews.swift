// Owner: media stream. Closed-island wings (SPEC §A.2, §D.5).
import SuperNotchCore
import SwiftUI

/// Left wing: 22 x 22 rounded cover (corner radius 5). `NotchSlots` only shows it while a track is loaded.
struct MediaIslandArtwork: View {
    @Environment(MediaModel.self) private var media

    init() {}

    var body: some View {
        MediaArtworkView(
            image: media.artwork, size: NotchMetrics.islandArtworkSize, cornerRadius: DesignTokens.Radius.small)
    }
}

/// Right wing: four fake animated bars (no audio capture, no permission). At most 18 x 14 pt.
/// Animates ONLY while Spotify plays and the panel is on screen: the `TimelineView` is paused otherwise, so a
/// paused song, a hidden panel or a fullscreen app costs zero frames. 20 fps is plenty for four 3 pt bars.
/// (It only exists in the closed island: `NotchSlots` removes it while the notch is open.)
struct MediaIslandVisualizer: View {
    @Environment(MediaModel.self) private var media
    @Environment(NotchViewModel.self) private var notch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {}

    private var isAnimating: Bool {
        media.isPlaying && !reduceMotion && notch.isPanelVisible && !notch.isFullscreenActive
            && notch.geometry != nil
    }

    var body: some View {
        let barColor = DesignTokens.Colors.primaryText.opacity(0.9)
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isAnimating)) { context in
            let levels =
                isAnimating
                ? MediaVisualizerModel.levels(at: context.date.timeIntervalSinceReferenceDate)
                : MediaVisualizerModel.restingLevels()
            Canvas { graphics, size in
                let count = levels.count
                guard count > 0 else { return }
                let gap: CGFloat = 2
                let barWidth = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                for (index, level) in levels.enumerated() {
                    let height = max(2, size.height * CGFloat(level))
                    let rect = CGRect(
                        x: CGFloat(index) * (barWidth + gap), y: size.height - height, width: barWidth,
                        height: height)
                    graphics.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(barColor))
                }
            }
        }
        .frame(width: 18, height: NotchMetrics.islandVisualizerSize.height)
        .accessibilityHidden(true)
    }
}
