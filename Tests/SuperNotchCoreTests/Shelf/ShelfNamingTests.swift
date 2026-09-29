// Owner: shelf-clipboard.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("ShelfNaming")
struct ShelfNamingTests {
    @Test func displayNameUsesFirstNonEmptyLine() {
        #expect(ShelfNaming.displayName(forText: "\n\n   Hello   world  \nsecond") == "Hello world")
        #expect(ShelfNaming.displayName(forText: "   \n\t ") == "Text")
        let long = String(repeating: "a", count: 100)
        let name = ShelfNaming.displayName(forText: long)
        #expect(name.count == ShelfNaming.maxDisplayNameLength)
        #expect(name.hasSuffix("…"))
    }

    @Test func sanitizesFileNames() {
        #expect(ShelfNaming.sanitizedFileName("a/b:c.txt") == "a-b-c.txt")
        #expect(ShelfNaming.sanitizedFileName("  ") == "Untitled")
        #expect(ShelfNaming.sanitizedFileName("..") == "Untitled")
        #expect(ShelfNaming.sanitizedFileName("line\nbreak.txt") == "linebreak.txt")
        #expect(ShelfNaming.sanitizedFileName(".env") == ".env")
        let long = String(repeating: "é", count: 300) + ".pdf"
        let short = ShelfNaming.sanitizedFileName(long)
        #expect(short.utf8.count <= ShelfNaming.maxFileNameBytes)
        #expect(short.hasSuffix(".pdf"))
    }

    @Test func storedRelativePathIsSafe() {
        let id = UUID()
        let path = ShelfNaming.storedRelativePath(id: id, fileName: "../../evil")
        #expect(path.hasPrefix(id.uuidString + "/"))
        #expect(ShelfPathSafety.isSafeRelativePath(path))
    }

    @Test func textFileName() {
        #expect(ShelfNaming.textFileName(forText: "Meeting notes: Monday\nmore") == "Meeting notes- Monday.txt")
        #expect(ShelfNaming.textFileName(forText: "").hasSuffix(".txt"))
    }

    @Test func kinds() {
        #expect(ShelfNaming.kind(isDirectory: true, isPackage: false, isImage: false) == .folder)
        #expect(ShelfNaming.kind(isDirectory: true, isPackage: true, isImage: false) == .file)
        #expect(ShelfNaming.kind(isDirectory: false, isPackage: false, isImage: true) == .image)
        #expect(ShelfNaming.kind(isDirectory: false, isPackage: false, isImage: false) == .file)
    }

    @Test func textItems() throws {
        let now = Date(timeIntervalSince1970: 0)
        let link = try #require(ShelfNaming.textItem(for: "  https://www.example.com/path?q=1 \n", now: now))
        #expect(link.kind == .link)
        #expect(link.urlString == "https://www.example.com/path?q=1")
        #expect(link.displayName == "example.com/path")
        let text = try #require(ShelfNaming.textItem(for: "Buy milk\nand eggs", now: now))
        #expect(text.kind == .text)
        #expect(text.text == "Buy milk\nand eggs")
        #expect(text.displayName == "Buy milk")
        #expect(ShelfNaming.textItem(for: " \n ", now: now) == nil)
        #expect(ShelfIndex.isValid(link) && ShelfIndex.isValid(text))
    }

    @Test func linkDisplayNames() {
        #expect(ShelfNaming.linkDisplayName("mailto:me@example.com") == "me@example.com")
        #expect(ShelfNaming.linkDisplayName("https://github.com/") == "github.com")
        #expect(ShelfNaming.linkDisplayName("spotify:track:1") == "spotify:track:1")
    }
}
