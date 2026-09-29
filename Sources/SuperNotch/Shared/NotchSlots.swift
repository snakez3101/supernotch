// Owner: FOUNDATION (SPEC §D.5, §D.10).
//
// The only place that references stream views for the notch. The shell (NotchContainerView) renders:
// * `islandLeading()` / `islandTrailing()` in the closed state (left / right wing),
// * `peek(request)` for an auto popup,
// * `tab(tab)` when expanded (below the top band, inset by `NotchMetrics.contentPadding`).
// All slot views read their models from the environment (`AppModel.inject(_:)`).
import SuperNotchCore
import SwiftUI

enum NotchSlots {

    /// Left wing of the closed island: album artwork (22 × 22) while a track is loaded; nothing otherwise.
    static func islandLeading() -> some View {
        NotchIslandLeadingSlot()
    }

    /// Right wing of the closed notch: visualizer and/or Claude dots + usage-warning dot.
    static func islandTrailing() -> some View {
        NotchIslandTrailingSlot()
    }

    /// Content of a peek (auto popup). `.id(request.id)` gives every request fresh view state
    /// (e.g. a queued permission card never inherits the previous card's "Confirm allow" step).
    @ViewBuilder
    static func peek(_ request: PopupRequest) -> some View {
        switch request.payload {
        case .claudeSession(let sessionID):
            ClaudePeekView(sessionID: sessionID)
                .id(request.id)
        case .claudePermission(let requestID):
            PermissionCardView(requestID: requestID)
                .id(request.id)
        }
    }

    /// Content of an expanded tab.
    @ViewBuilder
    static func tab(_ tab: NotchTab) -> some View {
        switch tab {
        case .home:
            HomeTabView()
        case .shelf:
            ShelfTabView()
        }
    }

    /// `closedWidthExtra` for `NotchGeometry.size(for: .closed, closedWidthExtra:)` (see
    /// `NotchMetrics.closedWidthExtra`). Reads observable state, so calling it from a view body tracks it.
    static func closedWidthExtra(settings: AppSettings, media: MediaModel, claude: ClaudeSessionsModel) -> CGFloat {
        NotchMetrics.closedWidthExtra(
            mode: settings.closedMode,
            hasTrack: showsTrack(settings: settings, media: media),
            hasActiveSessions: settings.claudeEnabled && claude.hasActiveSessions,
            showsUsageWarning: showsUsageWarning(settings: settings, claude: claude))
    }

    // MARK: Shared rules (also used by the private slot views below)

    fileprivate static func showsTrack(settings: AppSettings, media: MediaModel) -> Bool {
        settings.spotifyEnabled && media.hasTrack
    }

    fileprivate static func showsUsageWarning(settings: AppSettings, claude: ClaudeSessionsModel) -> Bool {
        settings.claudeEnabled && settings.showUsageLimits && claude.isUsageWarning
    }

    /// The visualizer only gets the right wing when no Claude session needs the dots (36 pt is not enough
    /// for 4 bars + 4 dots).
    fileprivate static func showsVisualizer(
        settings: AppSettings, media: MediaModel, claude: ClaudeSessionsModel
    ) -> Bool {
        settings.closedMode == .island && settings.showVisualizer && showsTrack(settings: settings, media: media)
            && !(settings.claudeEnabled && claude.hasActiveSessions)
    }
}

// MARK: - Slot views

private struct NotchIslandLeadingSlot: View {
    @Environment(SettingsStore.self) private var store
    @Environment(MediaModel.self) private var media

    var body: some View {
        let settings = store.settings
        if settings.closedMode == .island && NotchSlots.showsTrack(settings: settings, media: media) {
            MediaIslandArtwork()
        }
    }
}

private struct NotchIslandTrailingSlot: View {
    @Environment(SettingsStore.self) private var store
    @Environment(MediaModel.self) private var media
    @Environment(ClaudeSessionsModel.self) private var claude

    var body: some View {
        let settings = store.settings
        HStack(spacing: DesignTokens.Spacing.xs) {
            if NotchSlots.showsVisualizer(settings: settings, media: media, claude: claude) {
                MediaIslandVisualizer()
            }
            if settings.claudeEnabled {
                // Reads settings.closedMode itself: dots + warning in island mode, warning dot only when invisible.
                ClaudeIslandIndicator()
            }
        }
    }
}
