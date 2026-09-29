// Owner: shelf-clipboard (SPEC §A.5). Mouse + keyboard handling for one shelf tile, laid over the SwiftUI tile.
//
// * Drag out: an AppKit `NSDraggingSource` hands the REAL stored file URLs to the destination (SwiftUI's
//   `.draggable`/`.onDrag` would hand over a temporary copy, Apple forum 837005). Copy semantics only; the whole
//   selection travels when the drag starts on a selected tile. The notch is held open during the drag.
// * Click selects (⌘ toggles, ⇧ extends), double-click opens, right-click shows the context menu, space shows
//   Quick Look, ⌘⌫ removes, ⌘C copies, ⌘A selects all (keys need the panel to be key, i.e. after a click).
import AppKit
import SuperNotchCore
import SwiftUI

final class ShelfTileInteractionNSView: NSView, NSDraggingSource {
    weak var shelf: ShelfModel?
    var itemID = UUID()
    var onHover: ((Bool) -> Void)?

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false
    private var hoverArea: NSTrackingArea?
    /// Minimum pointer travel before a press becomes a drag (keeps clicks working).
    private static let dragThreshold: CGFloat = 3

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didStartDrag = false
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !didStartDrag else { return }
        let start = convert(down.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) >= Self.dragThreshold else { return }
        didStartDrag = true
        beginDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !didStartDrag, let shelf else { return }
        if event.clickCount >= 2 {
            shelf.open(id: itemID)
            return
        }
        let flags = event.modifierFlags
        let modifier: ShelfSelection.Modifier =
            flags.contains(.command) ? .toggle : (flags.contains(.shift) ? .extend : .none)
        shelf.select(itemID, modifier: modifier)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let shelf else { return nil }
        shelf.prepareContextMenu(for: itemID)
        return ShelfContextMenu.make(for: itemID, shelf: shelf, anchor: self)
    }

    // MARK: Keyboard (panel is key after a click)

    override func keyDown(with event: NSEvent) {
        guard let shelf else {
            super.keyDown(with: event)
            return
        }
        // Only the real modifiers (arrow/delete keys also carry .function / .numericPad).
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let targets = shelf.targetIDs(for: itemID)
        switch (event.keyCode, flags) {
        case (49, []):  // space
            shelf.toggleQuickLook(for: targets)
        case (51, .command), (117, []):  // ⌘⌫, forward delete
            shelf.remove(ids: targets)
        case (36, []), (76, []):  // return
            shelf.open(id: itemID)
        case (53, []):  // esc
            shelf.clearSelection()
        default:
            if flags == .command, let characters = event.charactersIgnoringModifiers?.lowercased() {
                switch characters {
                case "c":
                    shelf.copyToPasteboard(ids: targets)
                    return
                case "a":
                    shelf.selectAll()
                    return
                default:
                    break
                }
            }
            super.keyDown(with: event)
        }
    }

    // MARK: Drag out (NSDraggingSource)

    private func beginDrag(with event: NSEvent) {
        guard let shelf else { return }
        if !shelf.selection.contains(itemID) { shelf.select(itemID, modifier: .none) }
        let payloads = shelf.dragPayloads(for: shelf.targetIDs(for: itemID))
        guard !payloads.isEmpty else { return }
        let side = min(bounds.width, bounds.height, 56)
        var draggingItems: [NSDraggingItem] = []
        for (index, payload) in payloads.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: payload.writer)
            let offset = CGFloat(min(index, 4)) * 4
            let frame = NSRect(
                x: (bounds.width - side) / 2 + offset, y: (bounds.height - side) / 2 - offset, width: side,
                height: side)
            item.setDraggingFrame(frame, contents: shelf.dragImage(for: payload.id))
            draggingItems.append(item)
        }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = payloads.count > 1 ? .pile : .default
    }

    // AppKit calls these on the main thread; `nonisolated` + `assumeIsolated` compiles whether or not the SDK
    // marks NSDraggingSource as main-actor isolated.
    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Copy only: the shelf keeps its item (REQUIREMENTS "drag-out copies").
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        MainActor.assumeIsolated { self.shelf?.dragOutBegan() }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        MainActor.assumeIsolated { self.shelf?.dragOutEnded() }
    }
}

/// SwiftUI wrapper laid over each tile.
struct ShelfTileInteractionView: NSViewRepresentable {
    let itemID: UUID
    let shelf: ShelfModel
    let tooltip: String
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> ShelfTileInteractionNSView {
        let view = ShelfTileInteractionNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ShelfTileInteractionNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: ShelfTileInteractionNSView) {
        view.itemID = itemID
        view.shelf = shelf
        view.onHover = onHover
        view.toolTip = tooltip
    }
}

// MARK: - Context menu

/// Closure-backed menu items (NSMenuItem only holds its target weakly, so the target rides along as the
/// represented object).
final class ShelfMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        handler()
    }

    static func item(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) -> NSMenuItem {
        let action = ShelfMenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(ShelfMenuAction.invoke(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}

enum ShelfContextMenu {
    static func make(for id: UUID, shelf: ShelfModel, anchor: NSView) -> NSMenu {
        let menu = NSMenu(title: "Shelf")
        menu.autoenablesItems = false
        let targets = shelf.targetIDs(for: id)
        let chosen = targets.compactMap { shelf.item(id: $0) }
        let count = chosen.count
        let hasFiles = chosen.contains { $0.kind == .file || $0.kind == .folder || $0.kind == .image }
        let suffix = count > 1 ? " \(count) Items" : ""

        menu.addItem(ShelfMenuAction.item("Open", symbol: "arrow.up.forward.app") { shelf.open(id: id) })
        if hasFiles {
            menu.addItem(ShelfMenuAction.item("Quick Look", symbol: "eye") { shelf.quickLook(ids: targets) })
            menu.addItem(
                ShelfMenuAction.item("Show in Finder", symbol: "folder") { shelf.revealInFinder(ids: targets) })
        }
        if count == 1, let item = chosen.first, shelf.originalURL(for: item) != nil {
            menu.addItem(ShelfMenuAction.item("Show Original", symbol: "arrow.uturn.backward") {
                shelf.revealOriginal(id: id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(
            ShelfMenuAction.item("Copy" + suffix, symbol: "doc.on.doc") { shelf.copyToPasteboard(ids: targets) })
        if shelf.isAirDropAvailable {
            menu.addItem(
                ShelfMenuAction.item("AirDrop" + suffix, symbol: "dot.radiowaves.left.and.right") {
                    shelf.airDrop(itemIDs: targets)
                })
        }
        menu.addItem(
            ShelfMenuAction.item("Share…", symbol: "square.and.arrow.up") { [weak anchor] in
                guard let anchor else { return }
                shelf.share(ids: targets, from: anchor)
            })
        menu.addItem(.separator())
        if count == 1, let item = chosen.first {
            menu.addItem(
                ShelfMenuAction.item(item.pinned ? "Unpin" : "Pin", symbol: item.pinned ? "pin.slash" : "pin") {
                    shelf.togglePin(id: id)
                })
        }
        menu.addItem(ShelfMenuAction.item("Remove" + suffix, symbol: "trash") { shelf.remove(ids: targets) })
        return menu
    }
}
