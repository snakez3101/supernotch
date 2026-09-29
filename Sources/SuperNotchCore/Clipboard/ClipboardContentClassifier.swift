import Foundation

// Owner: shelf-clipboard. Pure decision *what* a pasteboard change is recorded as (the app reads the
// pasteboard into a snapshot, this picks the representation). Whether to record at all is
// `ClipboardCaptureFilter.decide`.

/// What the app read from the general pasteboard (first item's representations, merged like Maccy does).
public struct ClipboardPasteboardSnapshot: Sendable, Hashable {
    /// Raw type identifiers present on the pasteboard.
    public var types: [String]
    /// `public.utf8-plain-text`.
    public var string: String?
    /// `public.url` (web links copied as URL objects, e.g. from a browser's address bar or "Copy Link").
    public var urlString: String?
    /// Absolute paths of `public.file-url` items (Finder copies).
    public var filePaths: [String]
    /// The best image type present (see `ClipboardContentClassifier.imageTypes`), nil without image data.
    public var imageType: String?

    public init(
        types: [String], string: String? = nil, urlString: String? = nil, filePaths: [String] = [],
        imageType: String? = nil
    ) {
        self.types = types
        self.string = string
        self.urlString = urlString
        self.filePaths = filePaths
        self.imageType = imageType
    }
}

/// The representation to record.
public enum ClipboardCaptureKind: Sendable, Hashable {
    case text(String)
    case link(String)
    case files([String])
    /// Image data of this pasteboard type must be read and stored as a PNG file by the app.
    case image(type: String)
}

public enum ClipboardContentClassifier {
    /// Image types in order of preference (the first present one is read).
    public static let imageTypes: [String] = ["public.png", "public.tiff", "public.jpeg", "public.heic"]
    /// Rich text types; their presence means "this is text, even if an image rendition is attached".
    public static let richTextTypes: Set<String> = ["public.rtf", "public.html", "com.apple.flat-rtfd"]
    /// Text longer than this (UTF-8 bytes) is not recorded (keeps the history file small: 1000 entries at most).
    public static let defaultMaxTextBytes = 256 * 1024

    /// The first of `imageTypes` contained in `types`.
    public static func preferredImageType(in types: [String]) -> String? {
        imageTypes.first { types.contains($0) }
    }

    /// Picks the representation, or nil when there is nothing worth recording.
    ///
    /// Order: files → image (when there is no real text, or the only text is the image's URL) → link →
    /// text → bare `public.url`.
    public static func classify(
        _ snapshot: ClipboardPasteboardSnapshot, captureImages: Bool, maxTextBytes: Int = defaultMaxTextBytes
    ) -> ClipboardCaptureKind? {
        let paths = snapshot.filePaths.filter { !$0.isEmpty }
        if !paths.isEmpty { return .files(paths) }

        let text: String? = {
            guard let string = snapshot.string,
                !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return string
        }()
        let textLink = text.flatMap { ClipboardLinkDetector.link(in: $0) }
        let hasRichText = snapshot.types.contains { richTextTypes.contains($0) }

        // No text at all ⇒ the image. Text that is only the image's URL (browser "Copy Image") ⇒ the image,
        // unless rich text is present too (then the user copied a document selection that contains a link).
        if captureImages, let imageType = snapshot.imageType, text == nil || (textLink != nil && !hasRichText) {
            return .image(type: imageType)
        }
        if let text {
            guard text.utf8.count <= maxTextBytes else { return nil }
            if let textLink { return .link(textLink) }
            return .text(text)
        }
        if let url = snapshot.urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
            url.utf8.count <= ClipboardLinkDetector.maxLinkLength
        {
            return .link(url)
        }
        return nil
    }
}
