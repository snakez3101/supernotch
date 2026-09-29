// Owner: claude-app. Reads the tail of a session transcript (titles, interrupt marker; SPEC §E.1/§E.4).
// The JSONL format is undocumented: parsing is Core's `TranscriptTailParser`, which never throws.

import Foundation
import SuperNotchCore

nonisolated enum ClaudeTranscriptReader {
    /// Reads the last `TranscriptTailParser.tailBytes` of `path`. Nil when the file cannot be read.
    /// Blocking; call off the main thread.
    static func readSignals(path: String) -> TranscriptSignals? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let tail = UInt64(TranscriptTailParser.tailBytes)
            let offset = size > tail ? size - tail : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return TranscriptTailParser.parse(tail: data, isTruncated: offset > 0)
        } catch {
            return nil
        }
    }
}
