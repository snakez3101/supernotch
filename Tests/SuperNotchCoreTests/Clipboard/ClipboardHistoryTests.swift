// Owner: shelf-clipboard.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("ClipboardHistory")
struct ClipboardHistoryTests {
    let now = Date(timeIntervalSince1970: 100 * 86_400)

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/shelf"))
        return try Data(contentsOf: url)
    }

    @Test func decodesFixtureTolerantly() throws {
        let entries = try ClipboardHistory.decode(fixture("history-v1"))
        #expect(entries.map(\.previewText) == ["hello", "Image 10×20", "2 files"])
        #expect(entries[0].sourceAppName == "Safari")
        #expect(entries[1].pinned)
        #expect(ClipboardHistory.imagePaths(entries) == ["images/AAAAAAAA-0000-0000-0000-000000000002.png"])
    }

    @Test func roundTripAndGarbage() throws {
        let entries = [
            ClipboardEntry(content: .text("a"), sourceAppBundleID: "x", sourceAppName: "X", capturedAt: now),
            ClipboardEntry(content: .link("https://a.b"), capturedAt: now - 1, pinned: true),
            ClipboardEntry(
                content: .image(relativePath: "images/1.png", pixelWidth: 3, pixelHeight: 4), capturedAt: now - 2,
                contentHash: "img-abc"),
            ClipboardEntry(content: .files(["/a", "/b"]), capturedAt: now - 3),
        ]
        #expect(try ClipboardHistory.decode(ClipboardHistory.encode(entries)) == entries)
        #expect(throws: ClipboardHistory.DecodeError.self) { try ClipboardHistory.decode(Data("[1".utf8)) }
        #expect(throws: ClipboardHistory.DecodeError.self) {
            try ClipboardHistory.decode(Data("{\"version\":7,\"entries\":[]}".utf8))
        }
    }

    @Test func orderedPutsPinnedFirst() {
        let a = ClipboardEntry(content: .text("a"), capturedAt: now)
        let b = ClipboardEntry(content: .text("b"), capturedAt: now - 1, pinned: true)
        let c = ClipboardEntry(content: .text("c"), capturedAt: now - 2)
        let d = ClipboardEntry(content: .text("d"), capturedAt: now - 3, pinned: true)
        #expect(ClipboardHistory.ordered([a, b, c, d]).map(\.previewText) == ["b", "d", "a", "c"])
    }

    @Test func searchMatchesAllTokensInsensitive() {
        let entries = [
            ClipboardEntry(content: .text("Crème brûlée recipe"), sourceAppName: "Notes", capturedAt: now),
            ClipboardEntry(content: .link("https://github.com/p0deje/Maccy"), capturedAt: now),
            ClipboardEntry(content: .files(["/Users/me/Budget 2026.xlsx"]), capturedAt: now),
            ClipboardEntry(
                content: .image(relativePath: "images/x.png", pixelWidth: 640, pixelHeight: 480), capturedAt: now),
        ]
        #expect(ClipboardHistory.filter(entries, query: "creme RECIPE").count == 1)
        #expect(ClipboardHistory.filter(entries, query: "notes").count == 1)
        #expect(ClipboardHistory.filter(entries, query: "maccy").count == 1)
        #expect(ClipboardHistory.filter(entries, query: "budget").count == 1)
        #expect(ClipboardHistory.filter(entries, query: "image 640").count == 1)
        #expect(ClipboardHistory.filter(entries, query: "   ").count == 4)
        #expect(ClipboardHistory.filter(entries, query: "creme missing").isEmpty)
    }

    @Test func imageBookkeeping() {
        let keep = ClipboardEntry(
            content: .image(relativePath: "images/keep.png", pixelWidth: 1, pixelHeight: 1), capturedAt: now)
        let drop = ClipboardEntry(
            content: .image(relativePath: "images/drop.png", pixelWidth: 1, pixelHeight: 1), capturedAt: now)
        #expect(ClipboardHistory.releasedImagePaths(old: [keep, drop], new: [keep]) == ["images/drop.png"])
        #expect(
            ClipboardHistory.orphanedImagePaths(
                onDisk: ["images/keep.png", "images/stray.png", "images/drop.png"], entries: [keep, drop])
                == ["images/stray.png"])
        let id = UUID()
        #expect(ClipboardHistory.imageRelativePath(id: id) == "images/\(id.uuidString).png")
    }

    @Test func trimmedAppliesRetentionThenLimit() {
        var entries: [ClipboardEntry] = []
        for index in 0..<6 {
            entries.append(ClipboardEntry(content: .text("\(index)"), capturedAt: now - Double(index) * 3_600))
        }
        entries.append(ClipboardEntry(content: .text("old-pinned"), capturedAt: now - 90 * 86_400, pinned: true))
        entries.append(ClipboardEntry(content: .text("old"), capturedAt: now - 90 * 86_400))
        let trimmed = ClipboardHistory.trimmed(entries, period: .sevenDays, limit: 3, now: now)
        #expect(trimmed.map(\.previewText) == ["0", "1", "2", "old-pinned"])
        let off = ClipboardHistory.trimmed(entries, period: .off, limit: 100, now: now)
        #expect(off.count == entries.count)
    }
}
