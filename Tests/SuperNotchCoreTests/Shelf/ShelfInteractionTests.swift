// Owner: shelf-clipboard.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("ShelfInteraction")
struct ShelfInteractionTests {
    let ids = (0..<5).map { _ in UUID() }

    @Test func plainClickSelectsOne() {
        var selection = ShelfSelection()
        selection.click(ids[1], orderedIDs: ids, modifier: .none)
        selection.click(ids[2], orderedIDs: ids, modifier: .none)
        #expect(selection.selected == [ids[2]])
        #expect(selection.anchor == ids[2])
    }

    @Test func commandClickToggles() {
        var selection = ShelfSelection()
        selection.click(ids[0], orderedIDs: ids, modifier: .none)
        selection.click(ids[3], orderedIDs: ids, modifier: .toggle)
        #expect(selection.selected == [ids[0], ids[3]])
        selection.click(ids[3], orderedIDs: ids, modifier: .toggle)
        #expect(selection.selected == [ids[0]])
        selection.click(ids[0], orderedIDs: ids, modifier: .toggle)
        #expect(selection.isEmpty)
        #expect(selection.anchor == nil)
    }

    @Test func shiftClickSelectsRangeBothDirections() {
        var selection = ShelfSelection()
        selection.click(ids[3], orderedIDs: ids, modifier: .none)
        selection.click(ids[1], orderedIDs: ids, modifier: .extend)
        #expect(selection.selected == Set(ids[1...3]))
        selection.click(ids[4], orderedIDs: ids, modifier: .extend)
        #expect(selection.selected == Set(ids[3...4]))
        var fresh = ShelfSelection()
        fresh.click(ids[2], orderedIDs: ids, modifier: .extend)
        #expect(fresh.selected == [ids[2]])
    }

    @Test func dragCarriesSelectionOnlyWhenStartingInside() {
        var selection = ShelfSelection()
        selection.click(ids[4], orderedIDs: ids, modifier: .none)
        selection.click(ids[0], orderedIDs: ids, modifier: .toggle)
        #expect(selection.dragIDs(startingAt: ids[4], orderedIDs: ids) == [ids[0], ids[4]])
        #expect(selection.dragIDs(startingAt: ids[2], orderedIDs: ids) == [ids[2]])
        #expect(selection.orderedSelection(ids) == [ids[0], ids[4]])
    }

    @Test func pruneAndSelectAll() {
        var selection = ShelfSelection()
        selection.selectAll(ids)
        #expect(selection.selected.count == 5)
        selection.prune(keeping: [ids[0], ids[1]])
        #expect(selection.selected == [ids[0], ids[1]])
        selection.clear()
        #expect(selection.isEmpty)
    }

    @Test func dropZoneHalves() {
        #expect(ShelfDropZone.zone(atX: 10, width: 500, airDropAvailable: true) == .shelf)
        #expect(ShelfDropZone.zone(atX: 260, width: 500, airDropAvailable: true) == .airDrop)
        #expect(ShelfDropZone.zone(atX: 490, width: 500, airDropAvailable: false) == .shelf)
        #expect(ShelfDropZone.zone(atX: 10, width: 0, airDropAvailable: true) == .shelf)
    }

    @Test func dragNearNotch() {
        // 14" MacBook Pro: 1512 × 982 screen, notch ~185 × 32 at the top centre.
        let notch = CGRect(x: 663, y: 950, width: 185, height: 32)
        let open = CGRect(x: 486, y: 794, width: 540, height: 188)
        let above = CGPoint(x: 700, y: 960)
        let approaching = CGPoint(x: 640, y: 920)
        let farBelow = CGPoint(x: 700, y: 820)
        let farAway = CGPoint(x: 100, y: 100)
        #expect(ShelfDragGeometry.isNear(point: above, notchRect: notch, openRect: open, isActive: false))
        #expect(ShelfDragGeometry.isNear(point: approaching, notchRect: notch, openRect: open, isActive: false))
        #expect(!ShelfDragGeometry.isNear(point: farBelow, notchRect: notch, openRect: open, isActive: false))
        #expect(ShelfDragGeometry.isNear(point: farBelow, notchRect: notch, openRect: open, isActive: true))
        #expect(!ShelfDragGeometry.isNear(point: farAway, notchRect: notch, openRect: open, isActive: true))
        #expect(!ShelfDragGeometry.isNear(point: farBelow, notchRect: notch, openRect: nil, isActive: true))
    }

    @Test func onlyFileDragsCount() {
        #expect(ShelfDragTypes.isFileDrag(types: ["public.file-url", "public.utf8-plain-text"]))
        #expect(ShelfDragTypes.isFileDrag(types: ["com.apple.NSFilePromiseItemMetaData"]))
        #expect(ShelfDragTypes.isFileDrag(types: ["x.custom.promise"], extraPromiseTypes: ["x.custom.promise"]))
        #expect(!ShelfDragTypes.isFileDrag(types: ["public.url", "public.utf8-plain-text"]))
        #expect(!ShelfDragTypes.isFileDrag(types: []))
    }
}
