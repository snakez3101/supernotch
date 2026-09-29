// Owner: shelf-clipboard.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("ClipboardContentClassifier")
struct ClipboardClassifierTests {
    typealias Snapshot = ClipboardPasteboardSnapshot

    @Test func filesWin() {
        let snapshot = Snapshot(
            types: ["public.file-url", "public.utf8-plain-text", "public.tiff"], string: "Report.pdf",
            filePaths: ["/Users/me/Report.pdf"], imageType: "public.tiff")
        #expect(ClipboardContentClassifier.classify(snapshot, captureImages: true) == .files(["/Users/me/Report.pdf"]))
    }

    @Test func plainTextAndLinks() {
        #expect(
            ClipboardContentClassifier.classify(Snapshot(types: ["public.utf8-plain-text"], string: "hello"),
                captureImages: true) == .text("hello"))
        #expect(
            ClipboardContentClassifier.classify(
                Snapshot(types: ["public.utf8-plain-text"], string: " https://apple.com \n"), captureImages: true)
                == .link("https://apple.com"))
        #expect(
            ClipboardContentClassifier.classify(Snapshot(types: ["public.url"], urlString: "https://a.b/c"),
                captureImages: true) == .link("https://a.b/c"))
    }

    @Test func whitespaceOnlyAndEmptyAreIgnored() {
        #expect(
            ClipboardContentClassifier.classify(Snapshot(types: ["public.utf8-plain-text"], string: "  \n\t"),
                captureImages: true) == nil)
        #expect(ClipboardContentClassifier.classify(Snapshot(types: ["dyn.xyz"]), captureImages: true) == nil)
    }

    @Test func imagesRespectSettingAndText() {
        let image = Snapshot(types: ["public.png", "public.tiff"], imageType: "public.png")
        #expect(ClipboardContentClassifier.classify(image, captureImages: true) == .image(type: "public.png"))
        #expect(ClipboardContentClassifier.classify(image, captureImages: false) == nil)

        // Spreadsheet cells: text + rich text + an image rendition ⇒ text.
        let cells = Snapshot(
            types: ["public.utf8-plain-text", "public.rtf", "public.png"], string: "A\tB", imageType: "public.png")
        #expect(ClipboardContentClassifier.classify(cells, captureImages: true) == .text("A\tB"))

        // Browser "Copy Image": the only text is the image URL ⇒ image.
        let webImage = Snapshot(
            types: ["public.tiff", "public.utf8-plain-text"], string: "https://x.y/cat.png", imageType: "public.tiff")
        #expect(ClipboardContentClassifier.classify(webImage, captureImages: true) == .image(type: "public.tiff"))
        #expect(ClipboardContentClassifier.classify(webImage, captureImages: false) == .link("https://x.y/cat.png"))

        // Chrome "Copy image": png + html, no plain text ⇒ image.
        let chrome = Snapshot(types: ["public.html", "public.png"], imageType: "public.png")
        #expect(ClipboardContentClassifier.classify(chrome, captureImages: true) == .image(type: "public.png"))
    }

    @Test func hugeTextIsSkipped() {
        let big = String(repeating: "x", count: 2_000)
        #expect(
            ClipboardContentClassifier.classify(Snapshot(types: ["public.utf8-plain-text"], string: big),
                captureImages: true, maxTextBytes: 1_000) == nil)
    }

    @Test func preferredImageType() {
        #expect(ClipboardContentClassifier.preferredImageType(in: ["public.tiff", "public.png"]) == "public.png")
        #expect(ClipboardContentClassifier.preferredImageType(in: ["public.jpeg"]) == "public.jpeg")
        #expect(ClipboardContentClassifier.preferredImageType(in: ["public.utf8-plain-text"]) == nil)
    }

    @Test(arguments: [
        ("https://example.com", true), ("http://localhost:8080/x", true), ("www.example.com/a", true),
        ("mailto:me@example.com", true), ("spotify:track:123", true), ("file:///Users/me", true),
        ("example.com", false), ("https://", false), ("http:/oops", false), ("hello world", false),
        ("https://a.com and more", false), ("mailto:nobody", false), ("www.", false), ("12:30", false),
        ("", false), ("see: https://a.com", false),
    ])
    func linkDetection(input: String, isLink: Bool) {
        #expect(ClipboardLinkDetector.isLink(input) == isLink)
    }
}
