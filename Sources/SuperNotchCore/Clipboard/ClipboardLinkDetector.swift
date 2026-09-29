import Foundation

// Owner: shelf-clipboard. Decides whether a copied/dropped string is "a link" (a single URL) or plain text.

public enum ClipboardLinkDetector {
    /// Schemes that make a single token a link.
    public static let linkSchemes: Set<String> = [
        "http", "https", "ftp", "sftp", "ssh", "mailto", "tel", "facetime", "file", "spotify", "claude", "vscode",
        "x-apple.systempreferences", "obsidian", "notion", "slack", "zoommtg", "git",
    ]

    /// Longest string still considered a link.
    public static let maxLinkLength = 4_096

    /// The trimmed URL when `text` is exactly one URL (a known scheme, or `www.` + domain), else nil.
    /// "www.example.com" is returned as typed (no scheme is invented), so pasting gives back the original.
    public static func link(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxLinkLength else { return nil }
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("www.") {
            let host = lower.dropFirst(4).split(separator: "/").first.map(String.init) ?? ""
            return host.contains(".") && !host.hasSuffix(".") ? trimmed : nil
        }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let scheme = String(lower[lower.startIndex..<colon])
        guard linkSchemes.contains(scheme) else { return nil }
        let rest = trimmed[trimmed.index(after: colon)...]
        guard !rest.isEmpty else { return nil }

        switch scheme {
        case "http", "https", "ftp", "sftp":
            guard rest.hasPrefix("//"), let components = URLComponents(string: trimmed),
                let host = components.host, !host.isEmpty
            else { return nil }
            return trimmed
        case "mailto":
            return rest.contains("@") ? trimmed : nil
        case "file":
            return rest.hasPrefix("//") ? trimmed : nil
        default:
            return trimmed
        }
    }

    public static func isLink(_ text: String) -> Bool { link(in: text) != nil }
}
