import Foundation

// Owner: shelf-clipboard. Pure history bookkeeping for the clipboard (Clipboard/history.json):
// file format, display order, search, image-file bookkeeping and content digests.

public enum ClipboardHistory {
    public static let currentVersion = 1

    public struct DecodeError: Error, Sendable, Hashable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    private struct FileV1: Encodable {
        var version: Int
        var entries: [ClipboardEntry]
    }

    private struct LossyEntry: Decodable {
        var entry: ClipboardEntry?
        init(from decoder: any Decoder) throws {
            entry = try? ClipboardEntry(from: decoder)
        }
    }

    private struct LossyFile: Decodable {
        var version: Int?
        var entries: [LossyEntry]?
    }

    // MARK: File format

    /// `{ "version": 1, "entries": [...] }` in insertion order (newest first).
    public static func encode(_ entries: [ClipboardEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(FileV1(version: currentVersion, entries: entries))
    }

    /// Tolerant decode: corrupt entries, duplicate ids and images with unsafe paths are skipped.
    public static func decode(_ data: Data) throws -> [ClipboardEntry] {
        let decoder = JSONDecoder()
        let lossy: [LossyEntry]
        if let file = try? decoder.decode(LossyFile.self, from: data), let entries = file.entries {
            if let version = file.version, version > currentVersion {
                throw DecodeError("unsupported clipboard history version \(version)")
            }
            lossy = entries
        } else if let array = try? decoder.decode([LossyEntry].self, from: data) {
            lossy = array
        } else {
            throw DecodeError("not a clipboard history file")
        }
        var seen = Set<UUID>()
        var result: [ClipboardEntry] = []
        for item in lossy {
            guard let entry = item.entry, !seen.contains(entry.id), isValid(entry) else { continue }
            seen.insert(entry.id)
            result.append(entry)
        }
        return result
    }

    public static func isValid(_ entry: ClipboardEntry) -> Bool {
        switch entry.content {
        case .image(let path, let width, let height):
            return ShelfPathSafety.isSafeRelativePath(path) && width >= 0 && height >= 0
        case .files(let paths):
            return !paths.isEmpty
        case .text, .link:
            return true
        }
    }

    // MARK: Order and search

    /// Display order: pinned first, then the rest; each group keeps its (newest-first) order.
    public static func ordered(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.filter(\.pinned) + entries.filter { !$0.pinned }
    }

    /// Entries whose text matches every whitespace-separated token of `query` (case- and
    /// diacritic-insensitive). An empty query returns `entries` unchanged.
    public static func filter(_ entries: [ClipboardEntry], query: String) -> [ClipboardEntry] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = searchableText(of: entry)
            return tokens.allSatisfy { token in
                haystack.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Text searched for an entry (long texts are searched in their first 20 000 characters).
    public static func searchableText(of entry: ClipboardEntry) -> String {
        var parts: [String] = []
        switch entry.content {
        case .text(let text): parts.append(text.count > 20_000 ? String(text.prefix(20_000)) : text)
        case .link(let url): parts.append(url)
        case .image(_, let width, let height): parts.append("image picture screenshot \(width)x\(height)")
        case .files(let paths): parts.append(contentsOf: paths.map { ($0 as NSString).lastPathComponent })
        }
        if let app = entry.sourceAppName { parts.append(app) }
        return parts.joined(separator: "\n")
    }

    // MARK: Images

    /// Relative paths of all image files referenced by `entries`.
    public static func imagePaths(_ entries: [ClipboardEntry]) -> Set<String> {
        var paths = Set<String>()
        for entry in entries {
            if case .image(let path, _, _) = entry.content { paths.insert(path) }
        }
        return paths
    }

    /// Image files referenced by `old` but no longer by `new` (to delete after an edit).
    public static func releasedImagePaths(old: [ClipboardEntry], new: [ClipboardEntry]) -> Set<String> {
        imagePaths(old).subtracting(imagePaths(new))
    }

    /// Relative image paths (e.g. "images/<uuid>.png") found on disk that no entry references.
    public static func orphanedImagePaths(onDisk: [String], entries: [ClipboardEntry]) -> [String] {
        let referenced = imagePaths(entries)
        return onDisk.filter { !referenced.contains($0) }.sorted()
    }

    /// Relative path for a new image: "images/<uuid>.png".
    public static func imageRelativePath(id: UUID) -> String {
        "images/" + id.uuidString + ".png"
    }

    // MARK: Retention + limit in one step

    /// Applies retention, then the size limit (pinned entries are exempt from both).
    public static func trimmed(
        _ entries: [ClipboardEntry], period: RetentionPeriod, limit: Int, now: Date
    ) -> [ClipboardEntry] {
        let kept = RetentionPolicy.partition(entries, period: period, now: now).kept
        var unpinned = 0
        let cap = max(limit, 1)
        return kept.filter { entry in
            if entry.pinned { return true }
            unpinned += 1
            return unpinned <= cap
        }
    }
}

/// Deterministic content digests (FNV-1a 64-bit; stable across launches unlike `Hasher`).
public enum ClipboardDigest {
    public static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        return hash
    }

    /// `contentHash` for image entries: identical pixels copied twice collapse into one entry.
    public static func imageContentHash(of data: Data) -> String {
        "img-" + String(fnv1a64(data), radix: 16)
    }
}
