// Owner: FOUNDATION (SPEC §A.5, §D.5, §D.10).
//
// Home tab composition, below the top band (the shell insets it by `NotchMetrics.contentPadding`):
//
//   ┌──────────────────┬──────────────────────────┐
//   │ MediaHomeSection │ ClaudeHomeSection        │   rows (26 pt, max 4 visible)
//   │ (200 pt)         │ … UsageBarsView (bottom) │   ← drawn by ClaudeHomeSection itself
//   └──────────────────┴──────────────────────────┘
//
// The layout never changes size: a disabled feature leaves a quiet hint instead of collapsing the notch.
import SuperNotchCore
import SwiftUI

struct HomeTabView: View {
    @Environment(SettingsStore.self) private var store

    init() {}

    var body: some View {
        let settings = store.settings
        HStack(alignment: .top, spacing: 0) {
            if settings.spotifyEnabled {
                MediaHomeSection()
                    .frame(width: NotchMetrics.musicColumnWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                HomeTabColumnDivider()
            }
            if settings.claudeEnabled {
                ClaudeHomeSection()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HomeTabDisabledHint(
                    symbol: "sparkles",
                    message: settings.spotifyEnabled
                        ? "Claude sessions are turned off."
                        : "Claude and Spotify are turned off.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Hairline between the music and Claude columns.
private struct HomeTabColumnDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignTokens.Colors.hairline)
            .frame(width: DesignTokens.Size.hairline)
            .frame(maxHeight: .infinity)
            .padding(.vertical, DesignTokens.Spacing.s)
            .padding(.horizontal, DesignTokens.Spacing.columnGap)
            .accessibilityHidden(true)
    }
}

/// Shown in place of a column whose feature is disabled; the gear opens Settings to turn it back on.
private struct HomeTabDisabledHint: View {
    @Environment(NotchViewModel.self) private var notch
    let symbol: String
    let message: String

    init(symbol: String, message: String) {
        self.symbol = symbol
        self.message = message
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            Image(systemName: symbol)
                .font(DesignTokens.Fonts.title)
                .foregroundStyle(DesignTokens.Colors.tertiaryText)
            Text(message)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.secondaryText)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                notch.openSettings()
            }
            .buttonStyle(.plain)
            .font(DesignTokens.Fonts.caption)
            .foregroundStyle(DesignTokens.Colors.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
