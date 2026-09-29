// Owner: shelf-clipboard (SPEC §A.5). One compact 64 pt shelf tile: Quick Look thumbnail (or icon) + name.
// Mouse/keyboard/drag handling is AppKit (`ShelfTileInteractionView`) laid over the tile.
import AppKit
import SuperNotchCore
import SwiftUI

struct ShelfTileView: View {
    let item: ShelfItem

    @Environment(ShelfModel.self) private var shelf
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        let isSelected = shelf.selection.contains(item.id)
        VStack(spacing: DesignTokens.Spacing.xs) {
            ShelfTilePreview(item: item, thumbnail: thumbnail)
                .frame(width: ShelfTileMetrics.previewSize, height: ShelfTileMetrics.previewSize)
            Text(item.displayName)
                .font(DesignTokens.Fonts.micro)
                .foregroundStyle(isSelected ? DesignTokens.Colors.primaryText : DesignTokens.Colors.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: ShelfTileMetrics.tileWidth - 6)
        }
        .frame(width: ShelfTileMetrics.tileWidth, height: ShelfTileMetrics.tileHeight)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
                .fill(isSelected ? DesignTokens.Colors.selectedFill : (isHovering ? DesignTokens.Colors.hoverFill : .clear))
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
                    .strokeBorder(DesignTokens.Colors.accent.opacity(0.7), lineWidth: 1.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignTokens.Colors.warningOrange)
                    .padding(DesignTokens.Spacing.xs)
                    .accessibilityLabel("Pinned")
            }
        }
        .overlay {
            ShelfTileInteractionView(
                itemID: item.id, shelf: shelf, tooltip: tooltip,
                onHover: { hovering in isHovering = hovering })
        }
        .animation(DesignTokens.Motion.hover, value: isHovering)
        .task(id: item.id) {
            guard item.storedRelativePath != nil else { return }
            thumbnail = await shelf.thumbnail(
                for: item, pointSize: ShelfTileMetrics.previewSize, scale: max(displayScale, 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var tooltip: String {
        var parts = [item.displayName]
        if let size = item.byteSize, item.kind != .text, item.kind != .link {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if item.pinned { parts.append("Pinned") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        let kind: String
        switch item.kind {
        case .file: kind = "File"
        case .folder: kind = "Folder"
        case .image: kind = "Image"
        case .text: kind = "Text"
        case .link: kind = "Link"
        }
        return "\(kind): \(item.displayName)" + (item.pinned ? ", pinned" : "")
    }
}

/// The square preview: thumbnail/icon for files, a glyph card for text and links.
private struct ShelfTilePreview: View {
    let item: ShelfItem
    let thumbnail: NSImage?

    var body: some View {
        switch item.kind {
        case .file, .folder, .image:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            } else {
                Image(systemName: item.kind == .folder ? "folder.fill" : "doc.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
            }
        case .text:
            ShelfGlyphCard(symbol: "text.alignleft", caption: item.text.map { String($0.prefix(40)) } ?? "")
        case .link:
            ShelfGlyphCard(symbol: "link", caption: item.displayName)
        }
    }
}

private struct ShelfGlyphCard: View {
    let symbol: String
    let caption: String

    var body: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
            .fill(DesignTokens.Colors.controlFill)
            .overlay {
                VStack(spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.primaryText)
                    Text(caption)
                        .font(.system(size: 7, weight: .regular))
                        .foregroundStyle(DesignTokens.Colors.tertiaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DesignTokens.Spacing.xxs)
                }
            }
    }
}
