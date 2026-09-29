import Foundation

// Owner: shelf-clipboard. On-disk index of the shelf (`SuperNotchPaths.shelfIndex`, Shelf/items.json).
// Pure encode/decode so it is tested on Linux; the app writes the bytes atomically.
//
// Format: `{ "version": 1, "items": [ShelfItem, …] }`, newest first. Decoding is tolerant:
// * a bare `[ShelfItem]` array (early builds) is accepted,
// * a single corrupt entry is skipped instead of losing the whole shelf,
// * entries whose stored path is not a safe relative path are dropped (a tampered index must never make
//   the app delete or share files outside the shelf folder).

public enum ShelfIndex {
    public static let currentVersion = 1

    public struct DecodeResult: Sendable, Hashable {
        public var items: [ShelfItem]
        /// Entries that could not be decoded or were rejected as unsafe.
        public var droppedCount: Int
        public init(items: [ShelfItem], droppedCount: Int) {
            self.items = items
            self.droppedCount = droppedCount
        }
    }

    public struct DecodeError: Error, Sendable, Hashable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    private struct FileV1: Encodable {
        var version: Int
        var items: [ShelfItem]
    }

    private struct LossyItem: Decodable {
        var item: ShelfItem?
        init(from decoder: any Decoder) throws {
            item = try? ShelfItem(from: decoder)
        }
    }

    private struct LossyFile: Decodable {
        var version: Int?
        var items: [LossyItem]?
    }

    public static func encode(_ items: [ShelfItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(FileV1(version: currentVersion, items: items))
    }

    /// Decodes an index file. Throws only when the data is not an index at all (not JSON, wrong shape, or a
    /// newer major version we do not understand); individual bad entries are skipped.
    public static func decode(_ data: Data) throws -> DecodeResult {
        let decoder = JSONDecoder()
        let lossy: [LossyItem]
        if let file = try? decoder.decode(LossyFile.self, from: data), let items = file.items {
            if let version = file.version, version > currentVersion {
                throw DecodeError("unsupported shelf index version \(version)")
            }
            lossy = items
        } else if let array = try? decoder.decode([LossyItem].self, from: data) {
            lossy = array
        } else {
            throw DecodeError("not a shelf index")
        }
        var seen = Set<UUID>()
        var items: [ShelfItem] = []
        var dropped = 0
        for entry in lossy {
            guard let item = entry.item, isValid(item), !seen.contains(item.id) else {
                dropped += 1
                continue
            }
            seen.insert(item.id)
            items.append(item)
        }
        return DecodeResult(items: sortedNewestFirst(items), droppedCount: dropped)
    }

    /// Newest first; items added at the same instant keep their relative order.
    public static func sortedNewestFirst(_ items: [ShelfItem]) -> [ShelfItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.addedAt != rhs.element.addedAt { return lhs.element.addedAt > rhs.element.addedAt }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Structural validation of one entry.
    public static func isValid(_ item: ShelfItem) -> Bool {
        switch item.kind {
        case .file, .folder, .image:
            guard let path = item.storedRelativePath else { return false }
            return ShelfPathSafety.isSafeRelativePath(path)
        case .text:
            return item.text != nil
        case .link:
            return item.urlString != nil
        }
    }
}

/// Guards every path that is joined onto the shelf or clipboard folder.
public enum ShelfPathSafety {
    /// `true` for a non-empty relative path without `..`/`.` components, a leading `/`, `~` or NUL bytes.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\u{0}") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }

    /// The first path component (the per-item folder, e.g. "<uuid>" of "<uuid>/Report.pdf").
    public static func itemFolder(ofRelativePath path: String) -> String? {
        guard isSafeRelativePath(path) else { return nil }
        return path.split(separator: "/").first.map(String.init)
    }
}
