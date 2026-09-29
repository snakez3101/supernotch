import Foundation

// FOUNDATION-OWNED contract (SPEC §D.3). One clipboard history entry. Persisted in Clipboard/history.json.

public enum ClipboardContent: Sendable, Hashable, Codable {
    case text(String)
    /// A single URL copied as text or as public.url.
    case link(String)
    /// Image stored as PNG at `relativePath` (relative to `SuperNotchPaths.clipboardDirectory`).
    case image(relativePath: String, pixelWidth: Int, pixelHeight: Int)
    /// File URLs (absolute paths; not copied).
    case files([String])
}

public struct ClipboardEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var content: ClipboardContent
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var capturedAt: Date
    public var pinned: Bool
    /// Stable hash of the content used for de-duplication (see `ClipboardEntry.hash(of:)`).
    public var contentHash: String

    public init(
        id: UUID = UUID(), content: ClipboardContent, sourceAppBundleID: String? = nil, sourceAppName: String? = nil,
        capturedAt: Date, pinned: Bool = false, contentHash: String? = nil
    ) {
        self.id = id
        self.content = content
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.capturedAt = capturedAt
        self.pinned = pinned
        self.contentHash = contentHash ?? ClipboardEntry.hash(of: content)
    }

    /// One-line preview for list rows (≤ 200 chars, newlines collapsed).
    public var previewText: String {
        switch content {
        case .text(let text):
            let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return flat.count > 200 ? String(flat.prefix(199)) + "…" : flat
        case .link(let url): return url
        case .image(_, let width, let height): return "Image \(width)×\(height)"
        case .files(let paths):
            let names = paths.map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names.count) files"
        }
    }

    /// FNV-1a 64-bit over a canonical representation (deterministic across launches, unlike Hasher).
    /// Images hash their relative path; the clipboard stream may pass a pixel-data hash via `contentHash`.
    public static func hash(of content: ClipboardContent) -> String {
        let canonical: String
        switch content {
        case .text(let text): canonical = "t:" + text
        case .link(let url): canonical = "l:" + url
        case .image(let path, let width, let height): canonical = "i:\(path):\(width)x\(height)"
        case .files(let paths): canonical = "f:" + paths.joined(separator: "\u{0}")
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

extension ClipboardEntry: RetentionSubject {
    public var addedDate: Date { capturedAt }
    public var isPinned: Bool { pinned }
}
