// Owner: shelf-clipboard (SPEC §A.5, §D.4). Disk side of the shelf.
//
// Layout (`SuperNotchPaths`):  Shelf/items.json            index (atomic writes)
//                              Shelf/<uuid>/<file name>     one folder per stored copy
//                              Shelf/.incoming/<uuid>/      file promises land here before they are moved in
//                              Shelf/.share/<uuid>/         temporary files for AirDrop / Share of text
// Every file-system call runs on one private serial queue (never on the main thread); the async API hops there
// with a continuation. All state is confined to that queue, hence `@unchecked Sendable`.
import Foundation
import SuperNotchCore
import UniformTypeIdentifiers

nonisolated struct ShelfStoreError: Error, Sendable, CustomStringConvertible {
    let fileName: String
    let reason: String
    var description: String { "\(fileName): \(reason)" }
}

nonisolated final class ShelfStore: @unchecked Sendable {
    let shelfDirectory: URL
    let indexURL: URL
    /// File promises are received here (same volume ⇒ the move into the shelf is a rename).
    let incomingDirectory: URL
    /// Temporary files created for sharing text/images (cleaned at launch).
    let shareDirectory: URL

    private let queue = DispatchQueue(label: "io.github.snakez3101.supernotch.shelf-store", qos: .utility)
    private let fileManager = FileManager()

    init(paths: SuperNotchPaths) {
        shelfDirectory = URL(fileURLWithPath: paths.shelfDirectory, isDirectory: true)
        indexURL = URL(fileURLWithPath: paths.shelfIndex, isDirectory: false)
        incomingDirectory = shelfDirectory.appendingPathComponent(".incoming", isDirectory: true)
        shareDirectory = shelfDirectory.appendingPathComponent(".share", isDirectory: true)
    }

    // MARK: Async API (called from the main actor)

    /// Loads the index, dropping entries whose stored copy has disappeared. Never throws: a corrupt index is
    /// moved aside (items.json.corrupt-<date>) and the shelf starts empty.
    func load() async -> [ShelfItem] {
        await run { $0.loadSync() }
    }

    /// Atomically replaces the index.
    func save(_ items: [ShelfItem]) async {
        await run { $0.saveSync(items) }
    }

    /// Blocking save for app termination.
    func saveNow(_ items: [ShelfItem]) {
        queue.sync { saveSync(items) }
    }

    /// Copies (or, for received promises, moves) a file-system object into `Shelf/<uuid>/`.
    func importFile(at source: URL, move: Bool, now: Date) async -> Result<ShelfItem, ShelfStoreError> {
        await run { $0.importSync(source: source, move: move, now: now) }
    }

    /// Writes raw data (a dropped image without a file) as a new stored file.
    func importData(_ data: Data, fileName: String, now: Date) async -> Result<ShelfItem, ShelfStoreError> {
        await run { $0.importDataSync(data, fileName: fileName, now: now) }
    }

    /// Deletes the stored copies of `items` (text/link items have none).
    func removeStorage(for items: [ShelfItem]) async {
        await run { store in
            for item in items { store.removeStorageSync(for: item) }
        }
    }

    /// Removes per-item folders that no index entry references, and stale incoming/share leftovers.
    func sweep(keeping items: [ShelfItem]) async {
        await run { $0.sweepSync(keeping: items) }
    }

    /// A fresh, empty folder for receiving file promises.
    func makeIncomingFolder() -> URL? {
        queue.sync { makeFolderSync(in: incomingDirectory) }
    }

    /// Writes `text` into a temporary .txt file for AirDrop/Share (services often refuse plain strings).
    func makeShareTextFile(_ text: String) async -> URL? {
        await run { store in
            guard let folder = store.makeFolderSync(in: store.shareDirectory) else { return nil }
            let url = folder.appendingPathComponent(ShelfNaming.textFileName(forText: text), isDirectory: false)
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                return url
            } catch {
                Log.shelf.error("Could not write share text file: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// Writes image data (PNG/TIFF from a drop) into a temporary file for AirDrop.
    func makeShareDataFile(_ data: Data, fileName: String) async -> URL? {
        await run { store in
            guard let folder = store.makeFolderSync(in: store.shareDirectory) else { return nil }
            let url = folder.appendingPathComponent(ShelfNaming.sanitizedFileName(fileName), isDirectory: false)
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                Log.shelf.error("Could not write share data file: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// Absolute URL of a stored copy (nil for text/link items or unsafe paths).
    func url(for item: ShelfItem) -> URL? {
        guard let relative = item.storedRelativePath, ShelfPathSafety.isSafeRelativePath(relative) else {
            return nil
        }
        return shelfDirectory.appendingPathComponent(relative, isDirectory: item.kind == .folder)
    }

    // MARK: Queue plumbing

    private func run<T: Sendable>(_ work: @escaping @Sendable (ShelfStore) -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { [self] in
                continuation.resume(returning: work(self))
            }
        }
    }

    // MARK: Synchronous implementation (queue only)

    private func loadSync() -> [ShelfItem] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            Log.shelf.error("Could not read the shelf index: \(error.localizedDescription, privacy: .public)")
            return []
        }
        do {
            let result = try ShelfIndex.decode(data)
            if result.droppedCount > 0 {
                Log.shelf.notice("Skipped \(result.droppedCount, privacy: .public) unreadable shelf entries")
            }
            let present = result.items.filter { item in
                guard let url = url(for: item) else { return item.storedRelativePath == nil }
                return fileManager.fileExists(atPath: url.path)
            }
            if present.count != result.items.count {
                let missing = result.items.count - present.count
                Log.shelf.notice("Removed \(missing, privacy: .public) shelf entries whose files are gone")
            }
            return present
        } catch {
            moveAsideCorruptIndex()
            return []
        }
    }

    private func moveAsideCorruptIndex() {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = shelfDirectory.appendingPathComponent("items.json.corrupt-\(stamp)", isDirectory: false)
        do {
            try fileManager.moveItem(at: indexURL, to: backup)
            Log.shelf.error("The shelf index was unreadable; moved it aside and started empty")
        } catch {
            Log.shelf.error("The shelf index was unreadable and could not be moved aside")
        }
    }

    private func saveSync(_ items: [ShelfItem]) {
        do {
            try ensureDirectory(shelfDirectory)
            let data = try ShelfIndex.encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Log.shelf.error("Could not save the shelf index: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func importSync(source: URL, move: Bool, now: Date) -> Result<ShelfItem, ShelfStoreError> {
        let originalName = source.lastPathComponent
        guard source.isFileURL, fileManager.fileExists(atPath: source.path) else {
            return .failure(ShelfStoreError(fileName: originalName, reason: "the file no longer exists"))
        }
        let id = UUID()
        let relative = ShelfNaming.storedRelativePath(id: id, fileName: originalName)
        let itemFolder = shelfDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = shelfDirectory.appendingPathComponent(relative, isDirectory: false)
        do {
            try ensureDirectory(itemFolder)
            if move {
                try fileManager.moveItem(at: source, to: destination)
            } else {
                // On APFS a same-volume copy is a clone (near-instant, no extra space).
                try fileManager.copyItem(at: source, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: itemFolder)
            let reason = error.localizedDescription
            Log.shelf.error("Could not store a dropped file: \(reason, privacy: .public)")
            return .failure(ShelfStoreError(fileName: originalName, reason: reason))
        }
        let item = describe(
            destination, id: id, relativePath: relative, displayName: originalName,
            originalPath: move ? nil : source.path, now: now)
        return .success(item)
    }

    private func importDataSync(_ data: Data, fileName: String, now: Date) -> Result<ShelfItem, ShelfStoreError> {
        let id = UUID()
        let relative = ShelfNaming.storedRelativePath(id: id, fileName: fileName)
        let itemFolder = shelfDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = shelfDirectory.appendingPathComponent(relative, isDirectory: false)
        do {
            try ensureDirectory(itemFolder)
            try data.write(to: destination, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: itemFolder)
            return .failure(ShelfStoreError(fileName: fileName, reason: error.localizedDescription))
        }
        return .success(
            describe(destination, id: id, relativePath: relative, displayName: fileName, originalPath: nil, now: now))
    }

    private func describe(
        _ url: URL, id: UUID, relativePath: String, displayName: String, originalPath: String?, now: Date
    ) -> ShelfItem {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentTypeKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        let isImage = values?.contentType?.conforms(to: .image) ?? false
        let kind = ShelfNaming.kind(isDirectory: isDirectory, isPackage: isPackage, isImage: isImage)
        let size = (isDirectory ? nil : values?.fileSize).map { Int64($0) }
        return ShelfItem(
            id: id, kind: kind, displayName: displayName, storedRelativePath: relativePath, byteSize: size,
            addedAt: now, pinned: false, originalPath: originalPath)
    }

    private func removeStorageSync(for item: ShelfItem) {
        guard let relative = item.storedRelativePath,
            let folder = ShelfPathSafety.itemFolder(ofRelativePath: relative),
            UUID(uuidString: folder) != nil
        else { return }
        let url = shelfDirectory.appendingPathComponent(folder, isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Log.shelf.error("Could not delete a shelf item: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sweepSync(keeping items: [ShelfItem]) {
        let referenced = Set(
            items.compactMap { item in item.storedRelativePath.flatMap { ShelfPathSafety.itemFolder(ofRelativePath: $0) } }
        )
        if let names = try? fileManager.contentsOfDirectory(atPath: shelfDirectory.path) {
            for name in names where UUID(uuidString: name) != nil && !referenced.contains(name) {
                try? fileManager.removeItem(at: shelfDirectory.appendingPathComponent(name, isDirectory: true))
            }
        }
        // Promise and share leftovers from earlier runs (anything older than an hour).
        for folder in [incomingDirectory, shareDirectory] {
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names {
                let url = folder.appendingPathComponent(name, isDirectory: true)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(modified) > 3_600 { try? fileManager.removeItem(at: url) }
            }
        }
    }

    private func makeFolderSync(in parent: URL) -> URL? {
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try ensureDirectory(folder)
            return folder
        } catch {
            Log.shelf.error("Could not create a temporary folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }
}
