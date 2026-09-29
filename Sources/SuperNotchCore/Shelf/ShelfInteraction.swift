import Foundation

// Owner: shelf-clipboard. Pure interaction rules for the shelf: multi-selection, drop-zone hit testing,
// "is a file drag near the notch" geometry and drag-pasteboard type checks.

// MARK: - Selection

/// Finder-like selection over the ordered shelf items.
public struct ShelfSelection: Sendable, Hashable {
    public enum Modifier: Sendable, Hashable {
        /// Plain click: select only this item.
        case none
        /// ⌘-click: toggle this item.
        case toggle
        /// ⇧-click: select the range from the anchor to this item.
        case extend
    }

    public private(set) var selected: Set<UUID>
    public private(set) var anchor: UUID?

    public init(selected: Set<UUID> = [], anchor: UUID? = nil) {
        self.selected = selected
        self.anchor = anchor
    }

    public var isEmpty: Bool { selected.isEmpty }

    public func contains(_ id: UUID) -> Bool { selected.contains(id) }

    public mutating func click(_ id: UUID, orderedIDs: [UUID], modifier: Modifier) {
        switch modifier {
        case .none:
            selected = [id]
            anchor = id
        case .toggle:
            if selected.contains(id) {
                selected.remove(id)
                if anchor == id { anchor = orderedIDs.first(where: { selected.contains($0) }) }
            } else {
                selected.insert(id)
                anchor = id
            }
        case .extend:
            guard let anchor, let from = orderedIDs.firstIndex(of: anchor),
                let to = orderedIDs.firstIndex(of: id)
            else {
                selected = [id]
                self.anchor = id
                return
            }
            let range = min(from, to)...max(from, to)
            selected = Set(orderedIDs[range])
        }
    }

    public mutating func selectAll(_ orderedIDs: [UUID]) {
        selected = Set(orderedIDs)
        anchor = orderedIDs.first
    }

    public mutating func clear() {
        selected = []
        anchor = nil
    }

    /// Drops ids that no longer exist.
    public mutating func prune(keeping existing: Set<UUID>) {
        selected.formIntersection(existing)
        if let anchor, !existing.contains(anchor) { self.anchor = nil }
    }

    /// Items a drag starting on `id` carries: the whole selection (in shelf order) when `id` is part of it,
    /// otherwise just `id`.
    public func dragIDs(startingAt id: UUID, orderedIDs: [UUID]) -> [UUID] {
        guard selected.contains(id), selected.count > 1 else { return [id] }
        return orderedIDs.filter { selected.contains($0) }
    }

    /// Selected ids in shelf order.
    public func orderedSelection(_ orderedIDs: [UUID]) -> [UUID] {
        orderedIDs.filter { selected.contains($0) }
    }
}

// MARK: - Drop zones

/// The two drop targets shown while a file drag is over the open notch (§A.5).
public enum ShelfDropZone: String, Sendable, Hashable, CaseIterable {
    case shelf
    case airDrop

    /// Zone under `x` for the side-by-side layout of `DropZonesView` (two equal halves). Without the AirDrop
    /// zone the whole area is the shelf.
    public static func zone(atX x: CGFloat, width: CGFloat, airDropAvailable: Bool) -> ShelfDropZone {
        guard airDropAvailable, width > 0 else { return .shelf }
        return x < width / 2 ? .shelf : .airDrop
    }
}

// MARK: - Drag detection geometry

/// Decides whether a global file drag is "near the notch" (AppKit screen coordinates, origin bottom-left).
public enum ShelfDragGeometry {
    /// Horizontal reach around the physical notch that counts as approaching it.
    public static let approachSlackX: CGFloat = 56
    /// Vertical reach below the physical notch that counts as approaching it.
    public static let approachSlackY: CGFloat = 44
    /// Once open, the drag keeps the notch open while it stays within the open shape plus this margin.
    public static let openSlack: CGFloat = 24

    /// Rect a drag has to enter to open the notch.
    public static func activationRect(notchRect: CGRect) -> CGRect {
        notchRect.insetBy(dx: -approachSlackX, dy: -approachSlackY)
    }

    /// Whether the drag at `point` should keep (or put) the shelf in drop mode.
    /// - Parameters:
    ///   - notchRect: the physical notch.
    ///   - openRect: the expanded shape in screen coordinates (nil when unknown).
    ///   - isActive: whether drop mode is already on (then the larger open rect counts).
    public static func isNear(point: CGPoint, notchRect: CGRect, openRect: CGRect?, isActive: Bool) -> Bool {
        if activationRect(notchRect: notchRect).contains(point) { return true }
        guard isActive, let openRect else { return false }
        return openRect.insetBy(dx: -openSlack, dy: -openSlack).contains(point)
    }
}

// MARK: - Drag pasteboard types

public enum ShelfDragTypes {
    /// Plain file URLs (Finder, most apps) and the legacy filenames type.
    public static let fileURLTypes: Set<String> = [
        "public.file-url",
        "NSFilenamesPboardType",
    ]

    /// File promises (Mail, Photos, Safari images, …). The app adds `NSFilePromiseReceiver.readableDraggedTypes`.
    public static let promiseTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-suggested-file-name",
        "Apple files promise pasteboard type",
    ]

    /// Only real file drags auto-open the shelf: plain text, links and browser tabs do not (boring.notch
    /// #1530), they can still be dropped once the Shelf tab is open.
    public static func isFileDrag(types: [String], extraPromiseTypes: [String] = []) -> Bool {
        types.contains { type in
            fileURLTypes.contains(type) || promiseTypes.contains(type) || extraPromiseTypes.contains(type)
        }
    }
}
