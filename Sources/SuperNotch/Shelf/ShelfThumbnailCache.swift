// Owner: shelf-clipboard. Quick Look thumbnails for shelf tiles (QLThumbnailGenerator), cached in memory.
//
// An actor so concurrent tiles asking for the same file share one request (in-flight map) and the cache is
// never touched from two threads. Generation itself runs inside QuickLook's own queues.
import AppKit
import QuickLookThumbnailing

actor ShelfThumbnailCache {
    private var cache: [String: NSImage] = [:]
    /// Insertion order for a simple size cap (oldest out first).
    private var order: [String] = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let limit = 160

    /// Best thumbnail for the file at `url`, nil if Quick Look has none (the caller falls back to the icon).
    func thumbnail(for url: URL, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let key = Self.key(path: url.path, pointSize: pointSize, scale: scale)
        if let hit = cache[key] { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task<NSImage?, Never> {
            await Self.generate(url: url, pointSize: pointSize, scale: scale)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { insert(image, for: key) }
        return image
    }

    /// Drops cached thumbnails of files under `path` (after an item was removed).
    func invalidate(pathPrefix path: String) {
        let doomed = cache.keys.filter { $0.hasPrefix(path) }
        for key in doomed { cache[key] = nil }
        order.removeAll { doomed.contains($0) }
    }

    func removeAll() {
        cache.removeAll()
        order.removeAll()
    }

    private func insert(_ image: NSImage, for key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = image
        while order.count > limit {
            let oldest = order.removeFirst()
            cache[oldest] = nil
        }
    }

    private nonisolated static func key(path: String, pointSize: CGFloat, scale: CGFloat) -> String {
        "\(path)|\(Int(pointSize.rounded()))@\(Int((scale * 10).rounded()))"
    }

    private nonisolated static func generate(url: URL, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: pointSize, height: pointSize), scale: max(scale, 1),
            representationTypes: .all)
        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }
}
