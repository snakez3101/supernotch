// Owner: shelf-clipboard (SPEC §A.5, §D.5 `DropZonesView`). The two drop targets shown while a file drag is
// over or approaching the notch: "Shelf" (keep a copy) and "AirDrop" (send right away).
//
// Purely visual: the drop itself is received by `ShelfDropTargetView`, which ShelfTabView lays over this view
// and which picks the zone by the drag's x position (two equal halves, `ShelfDropZone.zone(atX:…)`). Keep the
// two zones the same width so the halves line up.
import SuperNotchCore
import SwiftUI

struct DropZonesView: View {
    @Environment(ShelfModel.self) private var shelf

    init() {}

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            ShelfDropZoneTile(
                zone: .shelf, title: "Shelf", subtitle: "Keep a copy here",
                isTargeted: shelf.dropTargetZone == .shelf)
            if shelf.showsAirDropZone {
                ShelfDropZoneTile(
                    zone: .airDrop, title: "AirDrop", subtitle: "Send to a nearby device",
                    isTargeted: shelf.dropTargetZone == .airDrop)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfDropZoneTile: View {
    let zone: ShelfDropZone
    let title: String
    let subtitle: String
    let isTargeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
        VStack(spacing: DesignTokens.Spacing.s) {
            icon
                .scaleEffect(isTargeted ? 1.12 : 1)
            Text(title)
                .font(DesignTokens.Fonts.title)
                .foregroundStyle(DesignTokens.Colors.primaryText)
            Text(subtitle)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(isTargeted ? DesignTokens.Colors.dropHighlight : DesignTokens.Colors.controlFill))
        .overlay {
            shape.strokeBorder(
                isTargeted ? DesignTokens.Colors.accent : DesignTokens.Colors.hairline,
                style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: isTargeted ? [] : [5, 4]))
        }
        .animation(DesignTokens.Motion.hover, value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isTargeted ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        switch zone {
        case .shelf:
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.primaryText)
                .frame(width: 30, height: 30)
        case .airDrop:
            ShelfAirDropIcon(size: 30)
        }
    }
}
