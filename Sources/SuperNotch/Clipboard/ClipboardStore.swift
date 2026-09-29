// Owner: shelf-clipboard (SPEC §A.10, §D.4). Disk side of the clipboard history.
//
// Layout (`SuperNotchPaths`):  Clipboard/history.json          entries (atomic writes)
//                              Clipboard/images/<uuid>.png     captured images
// Everything runs on one private serial queue (never the main thread): reading/writing JSON, converting
// copied TIFF/JPEG/HEIC to PNG with ImageIO, hashing pixels for de-duplication, deleting files.
import Foundation
import ImageIO
import SuperNotchCore
import UniformTypeIdentifiers

/// An image read from the pasteboard, converted and measured off the main thread.
nonisolated struct ClipboardPreparedImage: Sendable {
    let png: Data
    let pixelWidth: Int
    let pixelHeight: Int
    /// `ClipboardDigest.imageContentHash` of the original data (identical copies collapse into one entry).
    let contentHash: String
}

nonisolated final class ClipboardStore: @unchecked Sendable {
    let directory: URL
    let indexURL: URL
    let imagesDirectory: URL
    /// Larger pasteboard images are not recorded (keeps the history folder small).
    static let maxImageBytes = 40 * 1024 * 1024

    private let queue = DispatchQueue(label: "io.github.snakez3101.supernotch.clipboard-store", qos: .utility)
    private let fileManager = FileManager()

    init(paths: SuperNotchPaths) {
        directory = URL(fileURLWithPath: paths.clipboardDirectory, isDirectory: true)
        indexURL = URL(fileURLWithPath: paths.clipboardIndex, isDirectory: false)
        imagesDirectory = URL(fileURLWithPath: paths.clipboardImagesDirectory, isDirectory: true)
    }

    // MARK: Async API

    func load() async -> [ClipboardEntry] {
        await run { $0.loadSync() }
    }

    func save(_ entries: [ClipboardEntry]) async {
        await run { $0.saveSync(entries) }
    }

    /// Blocking save for app termination.
    func saveNow(_ entries: [ClipboardEntry]) {
        queue.sync { saveSync(entries) }
    }

    /// Hashes, measures and (if needed) converts pasteboard image data to PNG. nil if it is not a readable
    /// image or too large.
    func prepareImage(_ data: Data) async -> ClipboardPreparedImage? {
        await run { _ in Self.prepareImageSync(data) }
    }

    /// Writes PNG data to `images/<uuid>.png` (the relative path comes from `ClipboardHistory.imageRelativePath`).
    func writeImage(_ png: Data, relativePath: String) async -> Bool {
        await run { $0.writeImageSync(png, relativePath: relativePath) }
    }

    /// Deletes image files no entry references any more.
    func deleteImages(_ relativePaths: Set<String>) {
        guard !relativePaths.isEmpty else { return }
        queue.async { [self] in
            for path in relativePaths where ShelfPathSafety.isSafeRelativePath(path) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(path, isDirectory: false))
            }
        }
    }

    /// Removes image files that no entry references (crash leftovers, entries removed while not running).
    func sweepOrphans(keeping entries: [ClipboardEntry]) async {
        await run { $0.sweepSync(keeping: entries) }
    }

    /// Deletes the history file and every image.
    func deleteAll() async {
        await run { store in
            try? store.fileManager.removeItem(at: store.imagesDirectory)
            try? store.fileManager.removeItem(at: store.indexURL)
        }
    }

    func url(forRelativePath path: String) -> URL? {
        guard ShelfPathSafety.isSafeRelativePath(path) else { return nil }
        return directory.appendingPathComponent(path, isDirectory: false)
    }

    // MARK: Queue plumbing

    private func run<T: Sendable>(_ work: @escaping @Sendable (ClipboardStore) -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { [self] in
                continuation.resume(returning: work(self))
            }
        }
    }

    // MARK: Synchronous implementation (queue only)

    private func loadSync() -> [ClipboardEntry] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: indexURL)
            return try ClipboardHistory.decode(data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = directory.appendingPathComponent("history.json.corrupt-\(stamp)", isDirectory: false)
            try? fileManager.moveItem(at: indexURL, to: backup)
            Log.clipboard.error("The clipboard history was unreadable; moved it aside and started empty")
            return []
        }
    }

    private func saveSync(_ entries: [ClipboardEntry]) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try ClipboardHistory.encode(entries)
            try data.write(to: indexURL, options: [.atomic])
            // The history can contain secrets the user copied: keep it private to this user.
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            Log.clipboard.error("Could not save the clipboard history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeImageSync(_ png: Data, relativePath: String) -> Bool {
        guard let url = url(forRelativePath: relativePath) else { return false }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try png.write(to: url, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            Log.clipboard.error("Could not store a copied image: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func sweepSync(keeping entries: [ClipboardEntry]) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        let onDisk = names.map { "images/" + $0 }
        let orphans = ClipboardHistory.orphanedImagePaths(onDisk: onDisk, entries: entries)
        for path in orphans {
            try? fileManager.removeItem(at: directory.appendingPathComponent(path, isDirectory: false))
        }
        if !orphans.isEmpty {
            Log.clipboard.info("Removed \(orphans.count, privacy: .public) unreferenced clipboard images")
        }
    }

    private static func prepareImageSync(_ data: Data) -> ClipboardPreparedImage? {
        guard !data.isEmpty, data.count <= maxImageBytes,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let hash = ClipboardDigest.imageContentHash(of: data)

        var isPNG = false
        if let type = CGImageSourceGetType(source) {
            isPNG = (type as String) == UTType.png.identifier
        }
        if isPNG, width > 0, height > 0 {
            return ClipboardPreparedImage(png: data, pixelWidth: width, pixelHeight: height, contentHash: hash)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        width = image.width
        height = image.height
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ClipboardPreparedImage(
            png: output as Data, pixelWidth: width, pixelHeight: height, contentHash: hash)
    }
}
