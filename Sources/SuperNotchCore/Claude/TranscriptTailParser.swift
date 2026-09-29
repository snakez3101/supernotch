import Foundation

// Owner: claude-core. Signature is contract; baseline implementation, harden with real fixtures.
// Transcript JSONL is undocumented and version-dependent: never throw, never trust shape.

public enum TranscriptTailParser {
    /// Bytes to read from the end of the transcript.
    public static let tailBytes = 64 * 1024
    public static let interruptMarker = "[Request interrupted by user"

    /// Parses the last `tailBytes` of a transcript. The first (possibly partial) line is ignored when
    /// `isTruncated` is true.
    public static func parse(tail: Data, isTruncated: Bool) -> TranscriptSignals {
        var signals = TranscriptSignals()
        var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        if isTruncated, !lines.isEmpty { lines.removeFirst() }
        var lastConversationalEntryWasInterrupt = false
        for line in lines {
            guard let entry = try? JSONValue.parse(Data(line)) else { continue }
            switch entry["type"]?.stringValue {
            case "custom-title":
                if let title = entry["customTitle"]?.stringValue { signals.customTitle = title }
            case "ai-title":
                if let title = entry["aiTitle"]?.stringValue { signals.aiTitle = title }
            case "summary":
                if let summary = entry["summary"]?.stringValue { signals.summary = summary }
            case "user":
                lastConversationalEntryWasInterrupt = containsInterruptMarker(entry["message"])
            case "assistant":
                lastConversationalEntryWasInterrupt = false
            default:
                break
            }
        }
        signals.interrupted = lastConversationalEntryWasInterrupt
        return signals
    }

    static func containsInterruptMarker(_ message: JSONValue?) -> Bool {
        guard let content = message?["content"] else { return false }
        if let text = content.stringValue { return text.hasPrefix(interruptMarker) }
        for part in content.arrayValue ?? [] {
            if let text = part["text"]?.stringValue, text.hasPrefix(interruptMarker) { return true }
        }
        return false
    }
}
