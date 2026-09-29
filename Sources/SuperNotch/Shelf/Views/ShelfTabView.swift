// Owner: shelf-clipboard (SPEC §A.5, §D.5 `ShelfTabView()`). The expanded notch's Shelf tab.
//
// Layout (inside the ~512 × 156 pt area the shell gives the tab, below the top band):
//   [ tile ][ tile ][ tile ] …  (horizontal scroller, 64 pt tiles)      [ AirDrop ]
//   📋 [ chip ][ chip ][ chip ][ chip ][ chip ]                              ⌥⌘V
// While a drag is over/near the notch the row is replaced by `DropZonesView` ("Shelf" | "AirDrop").
// `ShelfDropTargetView` (AppKit) lies on top of everything and receives the drops.
import AppKit
import QuickLook  // SwiftUI's `.quickLookPreview` modifiers live in QuickLook's SwiftUI overlay.
import SuperNotchCore
import SwiftUI

struct ShelfTabView: View {
    @Environment(ShelfModel.self) private var shelf
    @Environment(SettingsStore.self) private var settingsStore

    init() {}

    var body: some View {
        @Bindable var shelf = shelf
        let enabled = settingsStore.settings.shelfEnabled
        ZStack {
            content(enabled: enabled)
            if enabled {
                ShelfDropTargetView(shelf: shelf, isIntercepting: shelf.isDropModeVisible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(DesignTokens.Motion.hover, value: shelf.isDropModeVisible)
        .quickLookPreview($shelf.quickLookURL, in: shelf.quickLookURLs)
    }

    @ViewBuilder
    private func content(enabled: Bool) -> some View {
        if !enabled {
            ShelfDisabledView()
        } else if shelf.isDropModeVisible {
            DropZonesView()
                .transition(.opacity)
        } else {
            ShelfContentView()
                .transition(.opacity)
        }
    }
}

/// Item row + AirDrop tile + clipboard strip.
private struct ShelfContentView: View {
    @Environment(ShelfModel.self) private var shelf
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.m) {
                ShelfItemsRow()
                if shelf.showsAirDropZone {
                    ShelfAirDropTile()
                }
            }
            .frame(height: ShelfTileMetrics.tileHeight)

            if settingsStore.settings.clipboardEnabled {
                ShelfClipboardStrip()
            } else if let message = shelf.statusMessage {
                ShelfStatusLine(message: message)
            }
        }
        .padding(.top, DesignTokens.Spacing.s)
        .padding(.bottom, DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The scrolling row of tiles, or the empty state.
private struct ShelfItemsRow: View {
    @Environment(ShelfModel.self) private var shelf

    var body: some View {
        if shelf.items.isEmpty && shelf.pendingImports == 0 {
            ShelfEmptyState()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: DesignTokens.Spacing.s) {
                    ForEach(0..<shelf.pendingImports, id: \.self) { _ in
                        ShelfPendingTile()
                    }
                    ForEach(shelf.items) { item in
                        ShelfTileView(item: item)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xxs)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { shelf.clearSelection() }
        }
    }
}

private struct ShelfEmptyState: View {
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.secondaryText)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Drop files here")
                    .font(DesignTokens.Fonts.bodyEmphasized)
                    .foregroundStyle(DesignTokens.Colors.primaryText)
                Text("Drag them back out whenever you need them.")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
                .strokeBorder(
                    DesignTokens.Colors.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ShelfPendingTile: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
                .fill(DesignTokens.Colors.controlFill)
                .frame(width: ShelfTileMetrics.previewSize, height: ShelfTileMetrics.previewSize)
                .overlay { ProgressView().controlSize(.small) }
            Text("Adding…")
                .font(DesignTokens.Fonts.micro)
                .foregroundStyle(DesignTokens.Colors.tertiaryText)
        }
        .frame(width: ShelfTileMetrics.tileWidth, height: ShelfTileMetrics.tileHeight)
        .accessibilityLabel("Adding a file")
    }
}

/// AirDrop tile at the end of the row: sends the selection, or lets the user pick files.
private struct ShelfAirDropTile: View {
    @Environment(ShelfModel.self) private var shelf

    var body: some View {
        let hasSelection = !shelf.selection.isEmpty
        Button {
            shelf.airDropSelectionOrChooseFiles()
        } label: {
            VStack(spacing: DesignTokens.Spacing.xs) {
                ShelfAirDropIcon(size: 26)
                Text("AirDrop")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
            }
            .frame(width: ShelfTileMetrics.tileWidth - 8, height: ShelfTileMetrics.tileHeight - 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: DesignTokens.Radius.large))
        .help(hasSelection ? "AirDrop the selected items" : "Choose files to send with AirDrop")
        .accessibilityLabel(hasSelection ? "AirDrop selected items" : "AirDrop files")
    }
}

/// The system AirDrop glyph, or an SF Symbol stand-in.
struct ShelfAirDropIcon: View {
    let size: CGFloat

    var body: some View {
        if let image = ShelfSharingCoordinator.airDropIcon {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: size * 0.7, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.primaryText)
                .frame(width: size, height: size)
        }
    }
}

private struct ShelfDisabledView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            Text("The shelf is turned off")
                .font(DesignTokens.Fonts.bodyEmphasized)
                .foregroundStyle(DesignTokens.Colors.secondaryText)
            Button("Open Settings") { appModel.showSettings() }
                .buttonStyle(.plain)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A transient one-line message ("Copied", "AirDrop can't send this").
struct ShelfStatusLine: View {
    let message: String

    var body: some View {
        Text(message)
            .font(DesignTokens.Fonts.caption)
            .foregroundStyle(DesignTokens.Colors.secondaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ShelfTileMetrics.stripHeight)
            .transition(.opacity)
    }
}

/// Sizes of the Shelf tab (tiles follow `NotchMetrics.shelfTileSize`).
enum ShelfTileMetrics {
    static let tileWidth: CGFloat = NotchMetrics.shelfTileSize
    static let previewSize: CGFloat = 46
    static let tileHeight: CGFloat = 80
    static let stripHeight: CGFloat = 24
}
