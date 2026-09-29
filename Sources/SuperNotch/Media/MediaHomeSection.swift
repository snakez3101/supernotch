// Owner: media stream. Left column of the Home tab (SPEC §A.5, §D.5): 200 pt wide, compact.
//
//   [cover 56]  Title (marquee)
//               Artist
//   1:02 ━━━●────── -2:33
//        ⏮    ⏯    ⏭
//
// Empty states keep the same footprint (the layout never changes size): Spotify off, not running ("Open
// Spotify"), Automation not allowed yet / waiting / no answer / denied (see `MediaPermissionPresentation`),
// nothing playing.
import SuperNotchCore
import SwiftUI

struct MediaHomeSection: View {
    @Environment(MediaModel.self) private var media

    init() {}

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        if !media.isEnabled {
            MediaEmptyStateView(
                symbol: "music.note", title: "Spotify is off", detail: "Turn it on in Settings > Music.")
        } else if !media.isSpotifyRunning {
            MediaEmptyStateView(
                symbol: "music.note", title: "Spotify isn't running", buttonTitle: "Open Spotify",
                action: { media.openSpotify() })
        } else if let snapshot = media.snapshot, let track = snapshot.track {
            MediaNowPlayingView(snapshot: snapshot, track: track)
        } else {
            noTrackState
        }
    }

    /// Spotify runs but there is nothing to show: either nothing plays, or Automation is not (yet) allowed. The
    /// permission states come from `MediaPermissionPresentation` (same logic as onboarding and Settings).
    @ViewBuilder
    private var noTrackState: some View {
        let presentation = media.permissionPresentation
        if presentation.tone == .allowed {
            MediaEmptyStateView(
                symbol: "music.note", title: "Nothing playing", buttonTitle: "Open Spotify",
                action: { media.openSpotify() })
        } else {
            MediaPermissionEmptyState(presentation: presentation)
        }
    }
}

/// Permission state in the 200 pt column: headline, a short sentence, the first two actions.
private struct MediaPermissionEmptyState: View {
    @Environment(MediaModel.self) private var media

    let presentation: MediaPermissionPresentation

    init(presentation: MediaPermissionPresentation) {
        self.presentation = presentation
    }

    var body: some View {
        let primary = presentation.actions.first
        let secondary = presentation.actions.dropFirst().first
        MediaEmptyStateView(
            symbol: presentation.symbol, title: presentation.title, detail: presentation.compactDetail,
            buttonTitle: primary?.shortTitle, action: handler(for: primary),
            secondaryButtonTitle: secondary?.shortTitle, secondaryAction: handler(for: secondary),
            isBusy: presentation.isBusy)
    }

    private func handler(for action: MediaPermissionAction?) -> (() -> Void)? {
        guard let action else { return nil }
        let model = media
        return { model.perform(action) }
    }
}

/// Cover, title/artist, scrubber and transport controls for the current track.
private struct MediaNowPlayingView: View {
    @Environment(MediaModel.self) private var media

    let snapshot: PlaybackSnapshot
    let track: TrackInfo

    private var tint: Color { media.accent?.color ?? DesignTokens.Colors.barFill }
    private var canSkip: Bool { MediaDisplay.canSkip(track) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: DesignTokens.Spacing.m)
            if media.canControl {
                MediaScrubber(
                    snapshot: snapshot, tint: tint, isEnabled: MediaDisplay.canSeek(track),
                    onSeek: { media.seek(to: $0) })
                Spacer(minLength: DesignTokens.Spacing.s)
                controls
            } else {
                permissionPrompt
            }
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.l) {
            MediaArtworkView(
                image: media.artwork, size: NotchMetrics.homeArtworkSize, cornerRadius: DesignTokens.Radius.medium
            )
            .shadow(color: (media.accent?.color ?? .clear).opacity(0.35), radius: 8, y: 2)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                MediaMarqueeText(text: MediaDisplay.title(for: track), font: DesignTokens.Fonts.title, height: 17)
                    .foregroundStyle(DesignTokens.Colors.primaryText)
                    .id(track.id)
                Text(MediaDisplay.subtitle(for: track))
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            MediaTransportButton(
                symbol: "backward.fill", label: "Previous track", font: DesignTokens.Fonts.transport, width: 26,
                isEnabled: canSkip, action: { media.previousTrack() })
            MediaTransportButton(
                symbol: snapshot.isPlaying ? "pause.fill" : "play.fill", label: snapshot.isPlaying ? "Pause" : "Play",
                font: DesignTokens.Fonts.transportPrimary, width: 36, action: { media.playPause() })
            MediaTransportButton(
                symbol: "forward.fill", label: "Next track", font: DesignTokens.Fonts.transport, width: 26,
                isEnabled: canSkip, action: { media.nextTrack() })
        }
        .frame(maxWidth: .infinity)
    }

    /// Track info still arrives through Spotify's notification, but commands need Automation.
    @ViewBuilder
    private var permissionPrompt: some View {
        let presentation = media.permissionPresentation
        VStack(spacing: DesignTokens.Spacing.s) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if presentation.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(presentation.title)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
                    .lineLimit(1)
            }
            HStack(spacing: DesignTokens.Spacing.s) {
                ForEach(Array(presentation.actions.prefix(2)), id: \.self) { action in
                    Button(action.shortTitle) { media.perform(action) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
