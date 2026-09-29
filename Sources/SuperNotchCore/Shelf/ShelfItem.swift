import Foundation

// FOUNDATION-OWNED contract (SPEC §D.3). One item on the shelf. Persisted in Shelf/items.json.

public enum ShelfItemKind: String, Sendable, Hashable, Codable {
    case file
    case folder
    case text
    case link
    case image
}

public struct ShelfItem: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: ShelfItemKind
    /// File name or first line of text.
    public var displayName: String
    /// For file/folder/image: path of the stored copy relative to `SuperNotchPaths.shelfDirectory`,
    /// e.g. "<uuid>/Report.pdf". nil for text/link.
    public var storedRelativePath: String?
    /// For text items.
    public var text: String?
    /// For link items.
    public var urlString: String?
    public var byteSize: Int64?
    public var addedAt: Date
    public var pinned: Bool
    /// Where the item was dragged from (display only, "Reveal original").
    public var originalPath: String?

    public init(
        id: UUID = UUID(), kind: ShelfItemKind, displayName: String, storedRelativePath: String? = nil,
        text: String? = nil, urlString: String? = nil, byteSize: Int64? = nil, addedAt: Date, pinned: Bool = false,
        originalPath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.storedRelativePath = storedRelativePath
        self.text = text
        self.urlString = urlString
        self.byteSize = byteSize
        self.addedAt = addedAt
        self.pinned = pinned
        self.originalPath = originalPath
    }

    /// Absolute path of the stored copy for a given shelf directory.
    public func storedPath(inShelfDirectory directory: String) -> String? {
        storedRelativePath.map { directory + "/" + $0 }
    }
}

/// Anything with an age that can be auto-cleaned (shelf items and clipboard entries).
public protocol RetentionSubject {
    var addedDate: Date { get }
    var isPinned: Bool { get }
}

extension ShelfItem: RetentionSubject {
    public var addedDate: Date { addedAt }
    public var isPinned: Bool { pinned }
}
