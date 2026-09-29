// Owner: shelf-clipboard.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("ShelfIndex")
struct ShelfIndexTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/shelf"))
        return try Data(contentsOf: url)
    }

    @Test func decodesV1NewestFirst() throws {
        let result = try ShelfIndex.decode(fixture("items-v1"))
        #expect(result.droppedCount == 0)
        #expect(result.items.map(\.displayName) == ["Hello", "Report.pdf", "example.com"])
        let file = try #require(result.items.first { $0.kind == .file })
        #expect(file.storedRelativePath == "11111111-1111-1111-1111-111111111111/Report.pdf")
        #expect(file.byteSize == 1024)
        #expect(file.originalPath == "/Users/me/Desktop/Report.pdf")
        #expect(result.items.first?.pinned == true)
    }

    @Test func skipsCorruptUnsafeAndDuplicateEntries() throws {
        let result = try ShelfIndex.decode(fixture("items-corrupt"))
        #expect(result.items.count == 1)
        #expect(result.items.first?.displayName == "Stuff")
        #expect(result.items.first?.kind == .folder)
        #expect(result.droppedCount == 7)
    }

    @Test func acceptsLegacyBareArray() throws {
        let result = try ShelfIndex.decode(fixture("items-legacy-array"))
        #expect(result.items.count == 1)
        #expect(result.items.first?.kind == .image)
    }

    @Test func rejectsNewerVersionAndGarbage() throws {
        #expect(throws: ShelfIndex.DecodeError.self) { try ShelfIndex.decode(try fixture("items-future-version")) }
        #expect(throws: ShelfIndex.DecodeError.self) { try ShelfIndex.decode(Data("not json".utf8)) }
        #expect(throws: ShelfIndex.DecodeError.self) { try ShelfIndex.decode(Data("{\"a\":1}".utf8)) }
    }

    @Test func roundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = UUID()
        let items = [
            ShelfItem(
                id: id, kind: .file, displayName: "a b.txt",
                storedRelativePath: ShelfNaming.storedRelativePath(id: id, fileName: "a b.txt"), byteSize: 3,
                addedAt: now, pinned: true, originalPath: "/tmp/a b.txt"),
            ShelfItem(kind: .text, displayName: "hi", text: "hi\nthere", addedAt: now - 10),
        ]
        let data = try ShelfIndex.encode(items)
        let decoded = try ShelfIndex.decode(data)
        #expect(decoded.items == items)
        #expect(decoded.droppedCount == 0)
        #expect(String(decoding: data, as: UTF8.self).contains("\"version\" : 1"))
    }

    @Test func sortIsStableForEqualDates() {
        let now = Date(timeIntervalSince1970: 5)
        let a = ShelfItem(kind: .text, displayName: "a", text: "a", addedAt: now)
        let b = ShelfItem(kind: .text, displayName: "b", text: "b", addedAt: now)
        let c = ShelfItem(kind: .text, displayName: "c", text: "c", addedAt: now + 1)
        #expect(ShelfIndex.sortedNewestFirst([a, b, c]).map(\.displayName) == ["c", "a", "b"])
    }

    @Test func pathSafety() {
        #expect(ShelfPathSafety.isSafeRelativePath("abc/def.pdf"))
        #expect(ShelfPathSafety.isSafeRelativePath("images/x.png"))
        #expect(ShelfPathSafety.isSafeRelativePath("a/..b"))
        #expect(!ShelfPathSafety.isSafeRelativePath(""))
        #expect(!ShelfPathSafety.isSafeRelativePath("/etc/passwd"))
        #expect(!ShelfPathSafety.isSafeRelativePath("../x"))
        #expect(!ShelfPathSafety.isSafeRelativePath("a/../../x"))
        #expect(!ShelfPathSafety.isSafeRelativePath("a//b"))
        #expect(!ShelfPathSafety.isSafeRelativePath("a/./b"))
        #expect(!ShelfPathSafety.isSafeRelativePath("~/x"))
        #expect(!ShelfPathSafety.isSafeRelativePath("a/"))
        #expect(ShelfPathSafety.itemFolder(ofRelativePath: "U-1/Report.pdf") == "U-1")
        #expect(ShelfPathSafety.itemFolder(ofRelativePath: "../x") == nil)
    }
}
