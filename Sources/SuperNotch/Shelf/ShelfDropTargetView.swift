// Owner: shelf-clipboard (SPEC §A.5). The AppKit drop destination laid over the whole Shelf tab.
//
// Why AppKit and not SwiftUI `.onDrop`: file promises (Mail, Photos, Safari images) need
// `NSFilePromiseReceiver`, and we want the dragging location to pick the zone ("Shelf" | "AirDrop").
// The view is transparent: it draws nothing and lets clicks through (`hitTest` → nil) unless a drag is in
// progress, so tiles and buttons underneath keep working. It stays mounted while the tab swaps between the item
// row and `DropZonesView`, so a drag never loses its destination mid-flight.
import AppKit
import SuperNotchCore
import SwiftUI

final class ShelfDropTargetNSView: NSView {
    weak var shelf: ShelfModel?
    /// True while a drag is (or is about to be) over the tab: then the view takes hit tests so AppKit routes
    /// the drop here even if it resolves destinations by hit testing.
    var isInterceptingDrops = false

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return types
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInterceptingDrops ? super.hitTest(point) : nil
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateHover(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateHover(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        shelf?.dropHover(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        accepts(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard accepts(sender), let shelf else { return false }
        let zone = zone(for: sender)
        let accepted = shelf.acceptDrop(from: sender.draggingPasteboard, zone: zone)
        Log.shelf.info("Drop on \(zone.rawValue, privacy: .public): \(accepted ? "accepted" : "nothing usable", privacy: .public)")
        return accepted
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        shelf?.dropSessionEnded()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        shelf?.dropSessionEnded()
    }

    // MARK: Private

    /// Drags that start on our own tiles never drop back onto the shelf.
    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        guard let shelf, shelf.isEnabled else { return false }
        return !(sender.draggingSource is ShelfTileInteractionNSView)
    }

    private func zone(for sender: any NSDraggingInfo) -> ShelfDropZone {
        let point = convert(sender.draggingLocation, from: nil)
        return ShelfDropZone.zone(
            atX: point.x, width: bounds.width, airDropAvailable: shelf?.showsAirDropZone ?? false)
    }

    private func updateHover(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else {
            shelf?.dropHover(nil)
            return []
        }
        shelf?.dropHover(zone(for: sender))
        return .copy
    }
}

/// SwiftUI wrapper; `ShelfTabView` puts it on top of its content.
struct ShelfDropTargetView: NSViewRepresentable {
    let shelf: ShelfModel
    let isIntercepting: Bool

    func makeNSView(context: Context) -> ShelfDropTargetNSView {
        let view = ShelfDropTargetNSView(frame: .zero)
        view.shelf = shelf
        view.isInterceptingDrops = isIntercepting
        return view
    }

    func updateNSView(_ nsView: ShelfDropTargetNSView, context: Context) {
        nsView.shelf = shelf
        nsView.isInterceptingDrops = isIntercepting
    }
}
