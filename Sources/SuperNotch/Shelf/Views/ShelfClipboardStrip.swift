// Owner: shelf-clipboard (SPEC §A.5). The last 5 clipboard entries under the shelf row. Click copies an entry
// back to the clipboard; the clock button opens the full history panel (⌥⌘V).
import AppKit
import SuperNotchCore
import SwiftUI

struct ShelfClipboardStrip: View {
    @Environment(ClipboardModel.self) private var clipboard
    @Environment(ShelfModel.self) private var shelf
    @Environment(SettingsStore.self) private var settingsStore

    private static let visibleCount = 5

    var body: some View {
        let recent = Array(clipboard.recentEntries.prefix(Self.visibleCount))
        HStack(spacing: DesignTokens.Spacing.s) {
            Image(systemName: "doc.on.clipboard")
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.tertiaryText)
                .accessibilityHidden(true)

            if let message = shelf.statusMessage ?? clipboard.statusMessage {
                ShelfStatusLine(message: message)
            } else if recent.isEmpty {
                Text(clipboard.isEnabled ? "Things you copy show up here" : "Clipboard history is off")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(recent) { entry in
                        ShelfClipboardChip(entry: entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                clipboard.showHistoryPanel()
            } label: {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: "clock.arrow.circlepath")
                    if let combo = settingsStore.settings.clipboardHotkey {
                        Text(combo.description)
                    }
                }
                .font(DesignTokens.Fonts.micro)
                .foregroundStyle(DesignTokens.Colors.secondaryText)
                .padding(.horizontal, DesignTokens.Spacing.s)
                .frame(height: 20)
                .background(Capsule().fill(DesignTokens.Colors.controlFill))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Clipboard history")
            .accessibilityLabel("Open clipboard history")
        }
        .frame(height: ShelfTileMetrics.stripHeight)
    }
}

private struct ShelfClipboardChip: View {
    let entry: ClipboardEntry

    @Environment(ClipboardModel.self) private var clipboard
    @State private var isHovering = false

    var body: some View {
        Button {
            clipboard.copy(entry.id)
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ClipboardEntryGlyph(entry: entry, size: 12)
                Text(entry.previewText)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, DesignTokens.Spacing.s)
            .frame(maxWidth: 104, minHeight: 20, maxHeight: 20, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small + 1, style: .continuous)
                    .fill(isHovering ? DesignTokens.Colors.selectedFill : DesignTokens.Colors.controlFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        "Copy “" + String(entry.previewText.prefix(80)) + "”"
    }
}
