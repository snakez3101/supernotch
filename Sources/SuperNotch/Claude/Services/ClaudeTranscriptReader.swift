// Owner: claude-app. Reads a session transcript for titles and the interrupt marker (SPEC §E.1/§E.4).
// The JSONL format is undocumented: parsing is Core's `TranscriptTailParser`, which never throws.

import Foundation
import SuperNotchCore

nonisolated enum ClaudeTranscriptReader {
    /// Reads the last `TranscriptTailParser.tailBytes` of `path`, plus the first `headBytes` when the tail
    /// carries no title (long, resumed sessions write their title records early). Nil when the file cannot be
    /// read. Blocking; call off the main thread.
    static func readSignals(path: String) -> TranscriptSignals? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let tail = UInt64(TranscriptTailParser.tailBytes)
            let offset = size > tail ? size - tail : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            let signals = TranscriptTailParser.parse(tail: data, isTruncated: offset > 0)
            let hasTitle = signals.customTitle != nil || signals.aiTitle != nil || signals.summary != nil
            guard offset > 0, !hasTitle else { return signals }
            try handle.seek(toOffset: 0)
            let head = try handle.read(upToCount: TranscriptTailParser.headBytes) ?? Data()
            return signals.fillingTitles(from: TranscriptTailParser.parse(head: head))
        } catch {
            return nil
        }
    }
}
