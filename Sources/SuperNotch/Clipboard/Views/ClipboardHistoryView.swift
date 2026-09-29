// Owner: shelf-clipboard (SPEC §A.4). Content of the ⌥⌘V history panel: search field, list, key hints.
// Keyboard handling lives in `ClipboardHistoryPanelController` (local key monitor); this view only renders.
// Depends on `ClipboardModel` alone (the panel is hosted outside the notch hierarchy).
import AppKit
import SuperNotchCore
import SwiftUI

struct ClipboardHistoryView: View {
    @Environment(ClipboardModel.self) private var clipboard
    @FocusState private var searchFocused: Bool

    private static let cornerRadius: CGFloat = 16

    var body: some View {
        @Bindable var clipboard = clipboard
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.m) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
                TextField("Search clipboard history", text: $clipboard.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(DesignTokens.Colors.primaryText)
                    .focused($searchFocused)
                Button {
                    clipboard.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(DesignTokens.Fonts.tabIcon)
                        .foregroundStyle(DesignTokens.Colors.secondaryText)
                        .frame(width: DesignTokens.Size.iconButton, height: DesignTokens.Size.iconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clipboard settings")
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.vertical, DesignTokens.Spacing.m + 2)

            Rectangle()
                .fill(DesignTokens.Colors.hairline)
                .frame(height: DesignTokens.Size.hairline)

            ClipboardHistoryList()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(DesignTokens.Colors.hairline)
                .frame(height: DesignTokens.Size.hairline)

            ClipboardHistoryFooter()
                .padding(.horizontal, DesignTokens.Spacing.l)
                .frame(height: 30)
        }
        .frame(
            width: ClipboardHistoryPanelController.panelSize.width,
            height: ClipboardHistoryPanelController.panelSize.height)
        .background(DesignTokens.Colors.notchBlack.opacity(0.55), in: shape)
        .glassEffect(.regular, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(DesignTokens.Colors.hairline, lineWidth: 1) }
        .environment(\.colorScheme, .dark)
        .task {
            // The window becomes key right after the view is installed; focus once it is.
            try? await Task.sleep(for: .milliseconds(40))
            searchFocused = true
        }
    }
}

/// The scrolling list (or an empty / disabled state).
private struct ClipboardHistoryList: View {
    @Environment(ClipboardModel.self) private var clipboard

    var body: some View {
        let visible = clipboard.filteredEntries
        if !clipboard.isEnabled {
            ClipboardPanelMessage(
                symbol: "clipboard", title: "Clipboard history is off",
                detail: "Turn it on to keep text, links and images you copy.",
                actionTitle: "Turn On", action: { clipboard.enableHistory() })
        } else if !clipboard.pasteboardAccess.allowsAutomaticCapture && clipboard.history.isEmpty {
            ClipboardPanelMessage(
                symbol: "hand.raised", title: "macOS is blocking clipboard access",
                detail: "Allow SuperNotch under Privacy & Security › Paste from Other Apps.",
                actionTitle: "Open Privacy Settings", action: { clipboard.openPrivacySettings() })
        } else if clipboard.history.isEmpty {
            ClipboardPanelMessage(
                symbol: "doc.on.clipboard", title: "Nothing copied yet",
                detail: "Copy some text, a link or an image and it shows up here.", actionTitle: nil, action: {})
        } else if visible.isEmpty {
            ClipboardPanelMessage(
                symbol: "magnifyingglass", title: "No matches", detail: "Try a different search.",
                actionTitle: nil, action: {})
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: DesignTokens.Spacing.xxs) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                            ClipboardEntryRow(
                                entry: entry, index: index, isSelected: entry.id == clipboard.panelSelectionID
                            )
                            .id(entry.id)
                        }
                    }
                    .padding(DesignTokens.Spacing.s)
                }
                .scrollIndicators(.automatic)
                .onChange(of: clipboard.panelSelectionID) { _, selection in
                    guard let selection else { return }
                    proxy.scrollTo(selection)
                }
            }
        }
    }
}

private struct ClipboardPanelMessage: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.tertiaryText)
            Text(title)
                .font(DesignTokens.Fonts.title)
                .foregroundStyle(DesignTokens.Colors.primaryText)
            Text(detail)
                .font(DesignTokens.Fonts.body)
                .foregroundStyle(DesignTokens.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Key hints, the paste-permission hint, or a transient status.
private struct ClipboardHistoryFooter: View {
    @Environment(ClipboardModel.self) private var clipboard

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            if let status = clipboard.statusMessage {
                Text(status)
                    .foregroundStyle(DesignTokens.Colors.primaryText)
                    .lineLimit(2)
            } else if !clipboard.canPaste {
                Text("↩ copies · allow paste to insert directly")
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.Spacing.s)
                Button("Allow Paste…") { clipboard.requestPastePermission() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.Colors.accent)
            } else {
                Text("↩ Paste   ⌘↩ Copy   ⌘P Pin   ⌘⌫ Delete")
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if clipboard.statusMessage == nil, clipboard.canPaste {
                Text(countText)
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
            }
        }
        .font(DesignTokens.Fonts.caption)
    }

    private var countText: String {
        let count = clipboard.history.count
        return count == 1 ? "1 item" : "\(count) items"
    }
}
