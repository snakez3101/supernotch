// Owner: FOUNDATION (SPEC §D.5, §D.10).
//
// The only place that references stream views for the notch. The shell (NotchContainerView) renders:
// * `islandLeading()` / `islandTrailing()` in the closed state (left / right wing, sized by `closedWings`),
// * `peek(request)` for an auto popup,
// * `tab(tab)` when expanded (below the top band, inset by `NotchMetrics.contentPadding`).
// All slot views read their models from the environment (`AppModel.inject(_:)`).
//
// Closed-state rules (compact on purpose, the user does not want a fat notch):
// * island content = a track is **playing**, or a Claude session is 🟡 working / 🔴 needs you;
// * right wing: Claude dots (`ClaudeIslandIndicator`) while Claude is active, otherwise the visualizer while
//   playing, plus the orange usage-warning dot when needed;
// * without island content (or in invisible mode) only the usage-warning dot may show, in a 14 pt right wing.
import SuperNotchCore
import SwiftUI

enum NotchSlots {

    // MARK: Closed

    /// Left wing of the closed island: album artwork (22 × 22) while a track is playing; nothing otherwise.
    static func islandLeading() -> some View {
        NotchIslandLeadingSlot()
    }

    /// Right wing of the closed notch: Claude dots, or the visualizer, and/or the usage-warning dot.
    static func islandTrailing() -> some View {
        NotchIslandTrailingSlot()
    }

    /// Leading/trailing wing widths of the closed shape (single rule: `NotchMetrics.closedWings`).
    /// Reads observable state, so calling it from a view body tracks it.
    static func closedWings(
        settings: AppSettings, media: MediaModel, claude: ClaudeSessionsModel
    ) -> (leading: CGFloat, trailing: CGFloat) {
        NotchMetrics.closedWings(
            mode: settings.closedMode,
            hasIslandContent: hasIslandContent(settings: settings, media: media, claude: claude),
            showsUsageWarning: showsUsageWarning(settings: settings, claude: claude))
    }

    /// Total wing width, for `NotchGeometry.size(for: .closed, closedWidthExtra:)`.
    static func closedWidthExtra(settings: AppSettings, media: MediaModel, claude: ClaudeSessionsModel) -> CGFloat {
        let wings = closedWings(settings: settings, media: media, claude: claude)
        return wings.leading + wings.trailing
    }

    /// Whether the island (both 36 pt wings) has anything to show.
    static func hasIslandContent(settings: AppSettings, media: MediaModel, claude: ClaudeSessionsModel) -> Bool {
        isPlaying(settings: settings, media: media) || isClaudeActive(settings: settings, claude: claude)
    }

    // MARK: Open

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

    // MARK: Rules (shared with the private slot views below)

    fileprivate static func isPlaying(settings: AppSettings, media: MediaModel) -> Bool {
        settings.spotifyEnabled && media.hasTrack && media.isPlaying
    }

    /// 🟡 or 🔴. Finished (🟢) and idle sessions do not keep the island open; 🟢 is announced by its peek.
    fileprivate static func isClaudeActive(settings: AppSettings, claude: ClaudeSessionsModel) -> Bool {
        guard settings.claudeEnabled, let light = claude.aggregateLight else { return false }
        return light >= .yellow
    }

    fileprivate static func showsUsageWarning(settings: AppSettings, claude: ClaudeSessionsModel) -> Bool {
        settings.claudeEnabled && settings.showUsageLimits && claude.isUsageWarning
    }
}

// MARK: - Slot views

private struct NotchIslandLeadingSlot: View {
    @Environment(SettingsStore.self) private var store
    @Environment(MediaModel.self) private var media

    var body: some View {
        let settings = store.settings
        if settings.closedMode == .island && NotchSlots.isPlaying(settings: settings, media: media) {
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
        let island = settings.closedMode == .island
            && NotchSlots.hasIslandContent(settings: settings, media: media, claude: claude)
        let warning = NotchSlots.showsUsageWarning(settings: settings, claude: claude)
        if island && NotchSlots.isClaudeActive(settings: settings, claude: claude) {
            // Dots for the sessions + the usage-warning dot (drawn by claude-app).
            ClaudeIslandIndicator()
        } else if island {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if settings.showVisualizer {
                    MediaIslandVisualizer()
                }
                if warning {
                    NotchUsageWarningDot()
                }
            }
        } else if warning {
            NotchUsageWarningDot()
        }
    }
}

/// The orange dot in the closed notch when Claude usage is at or above the threshold (§A.2, §D.9).
private struct NotchUsageWarningDot: View {
    var body: some View {
        Circle()
            .fill(DesignTokens.Colors.warningOrange)
            .frame(width: NotchMetrics.warningDotDiameter, height: NotchMetrics.warningDotDiameter)
            .accessibilityLabel("Claude usage limit warning")
    }
}
