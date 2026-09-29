// Owner: claude-app. Reads a session transcript for titles and the interrupt marker (SPEC §E.1/§E.4).
// The JSONL format is undocumented: parsing is Core's `TranscriptTailParser`, which never throws.

import Foundation
import SuperNotchCore

nonisolated enum ClaudeTranscriptReader {
    /// Bytes read from the start when the tail carries no title (long, resumed sessions write the
    /// title records early).
    static let headBytes = 16 * 1024

    /// Reads the last `TranscriptTailParser.tailBytes` of `path` (plus the head when the tail has no title).
    /// Nil when the file cannot be read. Blocking; call off the main thread.
    static func readSignals(path: String) -> TranscriptSignals? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let tail = UInt64(TranscriptTailParser.tailBytes)
            let offset = size > tail ? size - tail : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            var signals = TranscriptTailParser.parse(tail: data, isTruncated: offset > 0)
            let hasTitle = signals.customTitle != nil || signals.aiTitle != nil || signals.summary != nil
            if offset > 0, !hasTitle {
                try handle.seek(toOffset: 0)
                let head = try handle.read(upToCount: headBytes) ?? Data()
                // Only complete lines: drop the partial last line of the head.
                let complete = head.lastIndex(of: 0x0A).map { head[head.startIndex...$0] } ?? Data()
                let headSignals = TranscriptTailParser.parse(tail: Data(complete), isTruncated: false)
                signals.customTitle = headSignals.customTitle
                signals.aiTitle = headSignals.aiTitle
                signals.summary = headSignals.summary
            }
            return signals
        } catch {
            return nil
        }
    }
}
