// Owner: shelf-clipboard. One row of the clipboard history panel, plus the small type glyph shared with the
// Shelf tab's clipboard strip.
import AppKit
import SuperNotchCore
import SwiftUI

struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let index: Int
    let isSelected: Bool

    @Environment(ClipboardModel.self) private var clipboard
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            ClipboardEntryPreview(entry: entry)
                .frame(width: 34, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.previewText)
                    .font(DesignTokens.Fonts.body)
                    .foregroundStyle(DesignTokens.Colors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(metadata)
                    .font(DesignTokens.Fonts.rowMeta)
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignTokens.Spacing.xs)

            if isHovering || isSelected {
                ClipboardRowButton(symbol: entry.pinned ? "pin.slash" : "pin", help: entry.pinned ? "Unpin" : "Pin") {
                    clipboard.togglePin(entry.id)
                }
                ClipboardRowButton(symbol: "trash", help: "Delete") {
                    clipboard.delete(entry.id)
                }
            } else if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignTokens.Colors.warningOrange)
                    .accessibilityLabel("Pinned")
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(DesignTokens.Fonts.micro)
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
                    .frame(width: 22, alignment: .trailing)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, DesignTokens.Spacing.s)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
                .fill(rowFill)
        }
        .contentShape(Rectangle())
        .onTapGesture { clipboard.paste(entry.id) }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Paste") { clipboard.paste(entry.id) }
            Button("Copy") { clipboard.copy(entry.id) }
            Button(entry.pinned ? "Unpin" : "Pin") { clipboard.togglePin(entry.id) }
            Divider()
            Button("Delete", role: .destructive) { clipboard.delete(entry.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Pastes into the frontmost app")
    }

    private var rowFill: Color {
        if isSelected { return DesignTokens.Colors.accent.opacity(0.32) }
        return isHovering ? DesignTokens.Colors.hoverFill : .clear
    }

    private var metadata: String {
        var parts: [String] = []
        if let app = entry.sourceAppName { parts.append(app) }
        parts.append(entry.capturedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
        return parts.joined(separator: " · ")
    }
}

private struct ClipboardRowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.secondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Thumbnail for image entries, a glyph for everything else.
private struct ClipboardEntryPreview: View {
    let entry: ClipboardEntry

    @Environment(ClipboardModel.self) private var clipboard
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                .fill(DesignTokens.Colors.controlFill)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
            } else {
                ClipboardEntryGlyph(entry: entry, size: 12)
            }
        }
        .task(id: entry.id) {
            guard case .image = entry.content else { return }
            thumbnail = await clipboard.thumbnail(for: entry, pointSize: 34, scale: max(displayScale, 1))
        }
    }
}

/// SF Symbol for the kind of a clipboard entry.
struct ClipboardEntryGlyph: View {
    let entry: ClipboardEntry
    let size: CGFloat

    var body: some View {
        Image(systemName: Self.symbol(for: entry.content))
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(DesignTokens.Colors.secondaryText)
            .accessibilityHidden(true)
    }

    static func symbol(for content: ClipboardContent) -> String {
        switch content {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .files(let paths): return paths.count > 1 ? "doc.on.doc" : "doc"
        }
    }
}
