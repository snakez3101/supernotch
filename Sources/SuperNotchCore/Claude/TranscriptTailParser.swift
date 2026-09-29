import Foundation

// Owner: claude-core. Signature is contract (SPEC §D.1).
// Transcript JSONL is undocumented and version-dependent: never throw, never trust shape.
//
// What we read (observed formats, all optional):
//   {"type":"custom-title","customTitle":"…","sessionId":"…"}   /rename, --name; Claude Code 2.x also rewrites
//                                                                  the title shown in its UI here on every turn
//   {"type":"ai-title","aiTitle":"…"}                             auto title from the first prompt
//   {"type":"summary","summary":"…","leafUuid":"…"}               legacy (1.x) conversation summary
//   {"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},
//    "timestamp":"2026-09-29T12:00:00.000Z","isSidechain":false}
// Only the newest main-thread user/assistant entry decides `interrupted`; sidechain (subagent) and meta
// entries are skipped.

public enum TranscriptTailParser {
    /// Bytes to read from the end of the transcript.
    public static let tailBytes = 64 * 1024
    /// Bytes to read from the start when the tail has no title (first read of a long, resumed session).
    public static let headBytes = 16 * 1024
    public static let interruptMarker = "[Request interrupted by user"

    /// Parses the last `tailBytes` of a transcript. The first (possibly partial) line is ignored when
    /// `isTruncated` is true.
    public static func parse(tail: Data, isTruncated: Bool) -> TranscriptSignals {
        var lines = splitLines(tail)
        if isTruncated, !lines.isEmpty { lines.removeFirst() }
        return scan(lines, detectInterrupt: true)
    }

    /// Parses the first bytes of a transcript for titles only (`interrupted` is always false). A partial last
    /// line is skipped because it does not parse.
    public static func parse(head: Data) -> TranscriptSignals {
        scan(splitLines(head), detectInterrupt: false)
    }

    static func splitLines(_ data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).map { line in
            var bytes = Data(line)
            if bytes.last == 0x0D { bytes.removeLast() }
            return bytes
        }
    }

    static func scan(_ lines: [Data], detectInterrupt: Bool) -> TranscriptSignals {
        var signals = TranscriptSignals()
        var lastConversational: JSONValue?
        for line in lines {
            // Cheap pre-filter: every entry we care about is an object that has a "type" key.
            guard line.first == UInt8(ascii: "{"), let entry = try? JSONValue.parse(line) else { continue }
            switch entry["type"]?.stringValue {
            case "custom-title":
                if let title = nonEmpty(entry["customTitle"] ?? entry["title"]) { signals.customTitle = title }
            case "ai-title":
                if let title = nonEmpty(entry["aiTitle"] ?? entry["title"]) { signals.aiTitle = title }
            case "summary":
                if let summary = nonEmpty(entry["summary"]) { signals.summary = summary }
            case "user", "assistant":
                if isMainThread(entry) { lastConversational = entry }
            default:
                break
            }
        }
        if detectInterrupt, let last = lastConversational, last["type"]?.stringValue == "user",
            containsInterruptMarker(last["message"])
        {
            signals.interrupted = true
            signals.interruptedAt = last["timestamp"]?.stringValue.flatMap(parseTimestamp)
        }
        return signals
    }

    static func nonEmpty(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// Skips subagent (sidechain) entries and meta entries (caveats, local command output).
    static func isMainThread(_ entry: JSONValue) -> Bool {
        if entry["isSidechain"]?.boolValue == true { return false }
        if entry["isMeta"]?.boolValue == true { return false }
        return true
    }

    static func containsInterruptMarker(_ message: JSONValue?) -> Bool {
        guard let content = message?["content"] else { return false }
        if let text = content.stringValue { return text.hasPrefix(interruptMarker) }
        for part in content.arrayValue ?? [] {
            if let text = part["text"]?.stringValue, text.hasPrefix(interruptMarker) { return true }
        }
        return false
    }

    /// ISO 8601 with or without fractional seconds ("2026-09-29T12:00:00.123Z").
    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
