// Owner: notch-shell (SPEC §A.5).
//
// The expanded notch's top band (height = hardware notch height, pure black): tab icons left of the notch,
// the Settings gear right of it. Nothing is drawn under the hardware notch itself.
import SuperNotchCore
import SwiftUI

struct NotchHeaderView: View {
    @Environment(NotchViewModel.self) private var notch
    @Environment(SettingsStore.self) private var store

    let selectedTab: NotchTab
    let notchWidth: CGFloat

    init(selectedTab: NotchTab, notchWidth: CGFloat) {
        self.selectedTab = selectedTab
        self.notchWidth = notchWidth
    }

    var body: some View {
        let settings = store.settings
        let showsShelfTab = settings.shelfEnabled || settings.clipboardEnabled
        HStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                NotchHeaderButton(
                    symbol: "house.fill", label: "Home", isSelected: selectedTab == .home
                ) {
                    notch.selectTab(.home)
                }
                if showsShelfTab {
                    NotchHeaderButton(
                        symbol: "tray.full.fill", label: "Shelf", isSelected: selectedTab == .shelf
                    ) {
                        notch.selectTab(.shelf)
                    }
                }
            }
            // Keep clear of the hardware notch in the middle.
            Spacer(minLength: notchWidth + 2 * DesignTokens.Spacing.m)
            NotchHeaderButton(symbol: "gearshape.fill", label: "Settings", isSelected: false) {
                notch.openSettings()
            }
        }
        .padding(.horizontal, NotchMetrics.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small icon button for the top band (tab or gear).
private struct NotchHeaderButton: View {
    let symbol: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DesignTokens.Fonts.tabIcon)
                .foregroundStyle(foreground)
                .frame(width: DesignTokens.Size.iconButton, height: DesignTokens.Size.iconButton)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small + 1, style: .continuous)
                        .fill(background)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(DesignTokens.Motion.hover, value: isHovering)
    }

    private var foreground: Color {
        if isSelected { return DesignTokens.Colors.primaryText }
        return isHovering ? DesignTokens.Colors.secondaryText : DesignTokens.Colors.tertiaryText
    }

    private var background: Color {
        if isSelected { return DesignTokens.Colors.selectedFill }
        return isHovering ? DesignTokens.Colors.hoverFill : Color.clear
    }
}
