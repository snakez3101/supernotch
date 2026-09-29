// Owner: shelf-clipboard. Seed tests by the foundation.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("ClipboardCaptureFilter")
struct ClipboardCaptureFilterTests {
    @Test func skipsConcealedOwnAndIgnored() {
        #expect(ClipboardCaptureFilter.decide(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
            sourceBundleID: nil, ignoredBundleIDs: []) != .capture)
        #expect(ClipboardCaptureFilter.decide(types: ["public.utf8-plain-text", ClipboardCaptureFilter.ownMarkerType],
            sourceBundleID: nil, ignoredBundleIDs: []) != .capture)
        #expect(ClipboardCaptureFilter.decide(types: ["public.utf8-plain-text"], sourceBundleID: "com.bitwarden.desktop",
            ignoredBundleIDs: AppSettings.defaultIgnoredApps) != .capture)
        #expect(ClipboardCaptureFilter.decide(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Safari",
            ignoredBundleIDs: AppSettings.defaultIgnoredApps) == .capture)
    }

    @Test func dedupeAndLimit() {
        let t = Date(timeIntervalSince1970: 0)
        var entries: [ClipboardEntry] = []
        for index in 0..<5 {
            entries = ClipboardCaptureFilter.insert(ClipboardEntry(content: .text("\(index)"), capturedAt: t),
                into: entries, limit: 3)
        }
        #expect(entries.map(\.previewText) == ["4", "3", "2"])
        entries = ClipboardCaptureFilter.insert(ClipboardEntry(content: .text("2"), capturedAt: t), into: entries,
            limit: 3)
        #expect(entries.map(\.previewText) == ["2", "4", "3"])
        #expect(ClipboardEntry.hash(of: .text("a")) == ClipboardEntry.hash(of: .text("a")))
    }
}
