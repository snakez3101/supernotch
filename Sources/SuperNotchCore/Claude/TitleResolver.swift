import Foundation

// Owner: claude-core. Signatures are contract (SPEC §D.1/§E "Title resolution").

public enum TitleResolver {
    public static let maxWords = 4
    public static let maxCharacters = 28

    /// Picks the display title. Order: custom-title › ai-title › session_title › agents name › generated ›
    /// first prompt (truncated) › project name. A native title longer than `maxWords` is replaced by the
    /// generated (compressed) title once available, otherwise shown truncated.
    public static func resolve(_ candidates: TitleCandidates, firstPrompt: String?, projectName: String)
        -> SessionTitle
    {
        let native: [(String?, TitleSource)] = [
            (candidates.customTitle, .customTitle),
            (candidates.aiTitle, .aiTitle),
            (candidates.sessionTitle, .sessionTitle),
            (candidates.agentsName, .agentsName),
        ]
        if let (text, source) = native.first(where: { !clean($0.0).isEmpty }).map({ (clean($0.0), $0.1) }) {
            if wordCount(text) <= maxWords { return SessionTitle(text: shorten(text), source: source) }
            if let generated = candidates.generated.map(clean), !generated.isEmpty {
                return SessionTitle(text: shorten(generated), source: .generated)
            }
            return SessionTitle(text: shorten(text), source: source)
        }
        if let generated = candidates.generated.map(clean), !generated.isEmpty {
            return SessionTitle(text: shorten(generated), source: .generated)
        }
        if let prompt = firstPrompt.map(clean), !prompt.isEmpty {
            return SessionTitle(text: shorten(prompt), source: .firstPrompt)
        }
        return SessionTitle(text: projectName, source: .fallback)
    }

    /// Whether a Haiku title should be generated (at most once per session; caller caches).
    public static func needsGeneration(_ candidates: TitleCandidates, firstPrompt: String?) -> Bool {
        guard candidates.generated == nil else { return false }
        let native = [candidates.customTitle, candidates.aiTitle, candidates.sessionTitle, candidates.agentsName]
            .map(clean).first { !$0.isEmpty }
        if let native { return wordCount(native) > maxWords }
        return !(firstPrompt.map(clean) ?? "").isEmpty
    }

    /// The text to feed the Haiku prompt: the long native title if any, else the first prompt.
    public static func generationSource(_ candidates: TitleCandidates, firstPrompt: String?) -> String? {
        let native = [candidates.customTitle, candidates.aiTitle, candidates.sessionTitle, candidates.agentsName]
            .map(clean).first { !$0.isEmpty }
        return native ?? firstPrompt.map(clean)
    }

    /// Claude Code's default interactive names look like "<project>-3f"; treat them as "no title".
    public static func isDefaultAgentsName(_ name: String, projectName: String) -> Bool {
        guard name.hasPrefix(projectName + "-") else { return false }
        let suffix = name.dropFirst(projectName.count + 1)
        return (1...4).contains(suffix.count) && suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// First `maxWords` words, capped at `maxCharacters` with an ellipsis.
    public static func shorten(_ text: String) -> String {
        let words = clean(text).split(separator: " ")
        var result = words.prefix(maxWords).joined(separator: " ")
        if words.count > maxWords { result += "…" }
        if result.count > maxCharacters { result = String(result.prefix(maxCharacters - 1)) + "…" }
        return result
    }

    static func clean(_ text: String?) -> String {
        guard let text else { return "" }
        var flat = text.replacingOccurrences(of: "\n", with: " ")
        flat = flat.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`.*#"))
        while flat.contains("  ") { flat = flat.replacingOccurrences(of: "  ", with: " ") }
        return flat
    }

    static func wordCount(_ text: String) -> Int { text.split(separator: " ").count }
}
