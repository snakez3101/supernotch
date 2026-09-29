import Foundation

// Owner: shelf-clipboard. Pure naming rules for shelf items (display names, stored file names, kinds).

public enum ShelfNaming {
    /// Longest display name derived from text (characters, before the ellipsis).
    public static let maxDisplayNameLength = 60
    /// Byte budget for a stored file name (APFS allows 255 UTF-8 bytes).
    public static let maxFileNameBytes = 240

    /// First non-empty line of `text`, whitespace collapsed, shortened to `maxDisplayNameLength`.
    public static func displayName(forText text: String) -> String {
        let firstLine =
            text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let collapsed = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard !collapsed.isEmpty else { return "Text" }
        guard collapsed.count > maxDisplayNameLength else { return collapsed }
        return String(collapsed.prefix(maxDisplayNameLength - 1)) + "…"
    }

    /// A file name that is safe to create inside the shelf folder: no `/`, `:` or control characters,
    /// not `.`/`..`, never empty, at most `maxFileNameBytes` UTF-8 bytes (the extension is kept).
    public static func sanitizedFileName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                scalars.append("-")
            } else if scalar.properties.generalCategory == .control || scalar == "\u{0}" {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty || result == "." || result == ".." { result = "Untitled" }
        return truncateToByteBudget(result, maxBytes: maxFileNameBytes)
    }

    /// Path of a stored copy relative to the shelf folder: "<uuid>/<sanitized name>".
    public static func storedRelativePath(id: UUID, fileName: String) -> String {
        id.uuidString + "/" + sanitizedFileName(fileName)
    }

    /// File name used when text has to travel as a file (AirDrop of a text item, drag-out of text).
    public static func textFileName(forText text: String) -> String {
        var base = displayName(forText: text)
        if base.hasSuffix("…") { base.removeLast() }
        let cleaned = sanitizedFileName(base.trimmingCharacters(in: .whitespaces))
        return truncateToByteBudget(cleaned, maxBytes: 80) + ".txt"
    }

    /// Shelf item kind for a dropped file-system object.
    public static func kind(isDirectory: Bool, isPackage: Bool, isImage: Bool) -> ShelfItemKind {
        if isDirectory && !isPackage { return .folder }
        if isImage && !isDirectory { return .image }
        return .file
    }

    /// Builds a text or link item for dropped/added text. Returns nil for empty or whitespace-only text.
    public static func textItem(for text: String, now: Date, id: UUID = UUID()) -> ShelfItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let link = ClipboardLinkDetector.link(in: text) {
            return ShelfItem(
                id: id, kind: .link, displayName: linkDisplayName(link), urlString: link,
                byteSize: Int64(link.utf8.count), addedAt: now)
        }
        return ShelfItem(
            id: id, kind: .text, displayName: displayName(forText: text), text: text,
            byteSize: Int64(text.utf8.count), addedAt: now)
    }

    /// Host + path for web links ("github.com/foo"), the full string otherwise, shortened.
    public static func linkDisplayName(_ link: String) -> String {
        var name = link
        if let components = URLComponents(string: link), let host = components.host, !host.isEmpty {
            var path = components.path
            if path == "/" { path = "" }
            name = host.hasPrefix("www.") ? String(host.dropFirst(4)) + path : host + path
        } else if link.lowercased().hasPrefix("mailto:") {
            name = String(link.dropFirst("mailto:".count))
        }
        guard name.count > maxDisplayNameLength else { return name }
        return String(name.prefix(maxDisplayNameLength - 1)) + "…"
    }

    /// Shortens `string` to at most `maxBytes` UTF-8 bytes on a character boundary, keeping a short
    /// extension (".pdf") intact when there is one.
    static func truncateToByteBudget(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var stem = string
        var ext = ""
        if let dot = string.lastIndex(of: "."), dot != string.startIndex {
            let candidate = String(string[dot...])
            if candidate.utf8.count <= 16 {
                ext = candidate
                stem = String(string[..<dot])
            }
        }
        let budget = max(maxBytes - ext.utf8.count, 1)
        var result = ""
        var used = 0
        for character in stem {
            let size = String(character).utf8.count
            if used + size > budget { break }
            result.append(character)
            used += size
        }
        return result + ext
    }
}
