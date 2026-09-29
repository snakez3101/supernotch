import Foundation

// Owner: claude-core. Signatures are contract (SPEC §D.1, §E.4 "Title resolution").
//
// Order: custom-title › ai-title › session_title › agents name (unless default "repo-3f") › Haiku-generated ›
// first prompt (cleaned, truncated) › project name. Native titles longer than `maxWords` are shown shortened
// ("Fix flaky login test…"), or replaced by a generated title if one exists.
//
// Generation policy (REQUIREMENTS "only if none exists"): a Haiku title is generated only when Claude Code has
// produced no title of its own. Claude Code writes its `ai-title` in the background shortly after the first
// prompt, so the store asks only after the first turn completed (or `generationGraceSeconds` passed) AND the
// transcript was re-read since (`shouldRequestGeneration`). Compressing long native titles is opt-in
// (`needsCompression`, `SessionStoreConfiguration.compressLongNativeTitles`).

public enum TitleResolver {
    public static let maxWords = 4
    public static let maxCharacters = 28
    /// Characters of source text fed to the Haiku prompt.
    public static let maxGenerationSourceCharacters = 1_000

    /// SPEC §E.4 prompt prefix for `claude -p --model haiku`.
    public static let generationInstruction =
        "Summarise this coding task as a 2–4 word title. Reply with the title only."

    /// The complete prompt argument for the Haiku call.
    public static func haikuPrompt(for sourceText: String) -> String {
        generationInstruction + "\n\n" + String(sourceText.prefix(maxGenerationSourceCharacters))
    }

    /// Picks the display title.
    public static func resolve(_ candidates: TitleCandidates, firstPrompt: String?, projectName: String)
        -> SessionTitle
    {
        if let (text, source) = nativeTitle(candidates, projectName: projectName) {
            if wordCount(text) <= maxWords { return SessionTitle(text: shorten(text), source: source) }
            if let generated = usableGenerated(candidates) {
                return SessionTitle(text: shorten(generated), source: .generated)
            }
            return SessionTitle(text: shorten(text), source: source)
        }
        if let generated = usableGenerated(candidates) {
            return SessionTitle(text: shorten(generated), source: .generated)
        }
        if let prompt = promptTitleText(firstPrompt) {
            return SessionTitle(text: shorten(prompt), source: .firstPrompt)
        }
        return SessionTitle(text: projectName, source: .fallback)
    }

    /// Seconds after the first prompt before a missing native title counts as "none exists".
    public static let generationGraceSeconds: TimeInterval = 30

    /// Whether a Haiku title is wanted at all: no generated title yet, no native title, a usable first prompt.
    /// The generator should re-check this right before spawning `claude -p` (a native title may have arrived).
    public static func needsGeneration(_ candidates: TitleCandidates, firstPrompt: String?) -> Bool {
        guard usableGenerated(candidates) == nil, nativeTitle(candidates, projectName: nil) == nil else {
            return false
        }
        return promptTitleText(firstPrompt) != nil
    }

    /// Opt-in: the best native title is longer than `maxWords` and no generated title exists yet.
    public static func needsCompression(_ candidates: TitleCandidates) -> Bool {
        guard usableGenerated(candidates) == nil, let native = nativeTitle(candidates, projectName: nil) else {
            return false
        }
        return wordCount(native.text) > maxWords
    }

    /// The "has Claude Code had its chance?" rule: generation is requested only after at least one completed
    /// turn or `graceSeconds` since the first prompt, and only when the transcript was read after that point
    /// (so an `ai-title` written meanwhile is known). `transcriptUnavailable` skips the last condition.
    public static func shouldRequestGeneration(
        _ candidates: TitleCandidates, firstPrompt: String?, completedTurns: Int, secondsSinceFirstPrompt: TimeInterval,
        transcriptReadSinceCheckpoint: Bool, transcriptUnavailable: Bool = false,
        graceSeconds: TimeInterval = generationGraceSeconds
    ) -> Bool {
        guard needsGeneration(candidates, firstPrompt: firstPrompt) else { return false }
        guard completedTurns > 0 || secondsSinceFirstPrompt >= graceSeconds else { return false }
        return transcriptReadSinceCheckpoint || transcriptUnavailable
    }

    /// The text to feed the Haiku prompt: the long native title if any, else the cleaned first prompt.
    public static func generationSource(_ candidates: TitleCandidates, firstPrompt: String?) -> String? {
        if let native = nativeTitle(candidates, projectName: nil) { return native.text }
        guard let prompt = firstPrompt.map(sanitizePrompt), !prompt.isEmpty else { return nil }
        return String(prompt.prefix(maxGenerationSourceCharacters))
    }

    /// Claude Code's default interactive names combine the working directory's name with a short suffix,
    /// e.g. "my-app-3f" (also "my-app-3f (2)" for a duplicate). Such names are "no title".
    public static func isDefaultAgentsName(_ name: String, projectName: String) -> Bool {
        var lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasSuffix(")"), let open = lower.lastIndex(of: "("),
            lower[lower.index(after: open)..<lower.index(before: lower.endIndex)].allSatisfy(\.isNumber)
        {
            lower = String(lower[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let prefixes = Set([projectName.lowercased(), slug(projectName)]).filter { !$0.isEmpty }
        for prefix in prefixes where lower.hasPrefix(prefix + "-") {
            let suffix = lower.dropFirst(prefix.count + 1)
            if (1...4).contains(suffix.count), suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                return true
            }
        }
        return false
    }

    /// First `maxWords` words, capped at `maxCharacters`, with a single "…" when anything was cut.
    public static func shorten(_ text: String) -> String {
        let words = clean(text).split(separator: " ").map(String.init)
        var result = words.prefix(maxWords).joined(separator: " ")
        var cut = words.count > maxWords
        if result.count > maxCharacters {
            result = String(result.prefix(maxCharacters - 1))
            cut = true
        }
        guard cut else { return result }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-–—/"))
        return result + "…"
    }

    /// Cleans raw Haiku output. Nil when it is unusable (empty, an error or refusal, or clearly not a title).
    /// The generator should store `sanitizeGenerated(output)` and keep the fallback when it returns nil.
    public static func sanitizeGenerated(_ output: String) -> String? {
        let firstLine =
            output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var text = clean(firstLine)
        for prefix in ["title:", "session title:", "task:"] where text.lowercased().hasPrefix(prefix) {
            text = clean(String(text.dropFirst(prefix.count)))
        }
        guard !text.isEmpty, wordCount(text) <= 10 else { return nil }
        let lower = text.lowercased()
        let rejects = [
            "i'm sorry", "i am sorry", "i cannot", "i can't", "as an ai", "error:", "usage limit", "rate limit",
            "not logged in", "please run", "invalid api key", "credit balance",
        ]
        if rejects.contains(where: { lower.hasPrefix($0) }) || lower.contains("api error") { return nil }
        return shorten(text)
    }

    /// Removes paste markers and other XML-style wrappers Claude Code puts into prompts
    /// (`<pasted_content id="1">`, `<command-name>`…), code fences, and collapses whitespace.
    public static func sanitizePrompt(_ prompt: String) -> String {
        var output = ""
        var index = prompt.startIndex
        while index < prompt.endIndex {
            let character = prompt[index]
            if character == "<", let close = tagEnd(in: prompt, from: index) {
                output.append(" ")
                index = prompt.index(after: close)
                continue
            }
            output.append(character)
            index = prompt.index(after: index)
        }
        output = output.replacingOccurrences(of: "```", with: " ")
        return collapseWhitespace(output)
    }

    // MARK: - Internals

    /// Best native title (non-empty after cleaning). `projectName` nil skips the default-name check.
    static func nativeTitle(_ candidates: TitleCandidates, projectName: String?) -> (text: String, source: TitleSource)? {
        let ordered: [(String?, TitleSource)] = [
            (candidates.customTitle, .customTitle),
            (candidates.aiTitle, .aiTitle),
            (candidates.sessionTitle, .sessionTitle),
            (candidates.agentsName, .agentsName),
        ]
        for (raw, source) in ordered {
            let text = clean(raw)
            guard !text.isEmpty else { continue }
            if source == .agentsName, let projectName, isDefaultAgentsName(text, projectName: projectName) {
                continue
            }
            return (text, source)
        }
        return nil
    }

    static func usableGenerated(_ candidates: TitleCandidates) -> String? {
        let text = clean(candidates.generated)
        return text.isEmpty ? nil : text
    }

    /// First prompt as a title: sanitized, filler openers removed ("hey claude, can you please …"),
    /// first letter capitalised. Nil when nothing is left.
    static func promptTitleText(_ firstPrompt: String?) -> String? {
        guard let firstPrompt else { return nil }
        var text = clean(sanitizePrompt(firstPrompt))
        let fillers = [
            "hey claude", "hi claude", "hello claude", "ok claude", "okay claude", "claude", "please", "pls",
            "can you", "could you", "would you", "will you", "can u", "i want you to", "i'd like you to",
            "i would like you to", "i need you to", "help me", "hey", "hi", "hello", "ok", "okay", "so", "now",
        ]
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            for filler in fillers where lower.hasPrefix(filler) {
                let rest = text.dropFirst(filler.count)
                guard let next = rest.first, next == " " || next == "," || next == "!" || next == ":" else { continue }
                let trimmed = clean(String(rest.drop { $0 == " " || $0 == "," || $0 == "!" || $0 == ":" }))
                if !trimmed.isEmpty {
                    text = trimmed
                    changed = true
                }
                break
            }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "?!. "))
        guard let first = text.first else { return nil }
        return first.uppercased() + text.dropFirst()
    }

    /// Flattens whitespace, trims wrapping quotes/markdown and trailing punctuation.
    static func clean(_ text: String?) -> String {
        guard let text else { return "" }
        var flat = collapseWhitespace(text)
        let wrappers = CharacterSet(charactersIn: " \"'`*_#“”‘’«»")
        flat = flat.trimmingCharacters(in: wrappers)
        flat = flat.trimmingCharacters(in: CharacterSet(charactersIn: ".:;, "))
        return flat.trimmingCharacters(in: wrappers)
    }

    static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            let isSpace =
                CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            if isSpace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    static func wordCount(_ text: String) -> Int { text.split(separator: " ").count }

    /// "My App_v2" → "my-app-v2" (how Claude Code builds the default display name prefix).
    static func slug(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                result.append(character)
            } else if result.last != "-" {
                result.append("-")
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// End of an XML-ish tag starting at `start` (`<name …>` or `</name …>`), at most 160 characters long.
    static func tagEnd(in text: String, from start: String.Index) -> String.Index? {
        let next = text.index(after: start)
        guard next < text.endIndex else { return nil }
        let first = text[next]
        guard first.isLetter || first == "/" else { return nil }
        var index = next
        var length = 0
        while index < text.endIndex, length < 160 {
            let character = text[index]
            if character == ">" { return index }
            if character == "<" || character.isNewline { return nil }
            index = text.index(after: index)
            length += 1
        }
        return nil
    }
}
