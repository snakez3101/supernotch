// Owner: shelf-clipboard (SPEC §A.5, §D.4 `ShelfModel`, FROZEN API + additive extras).
//
// The shelf: files, folders, images, text and links dropped on the notch, stored as copies in
// Application Support/SuperNotch/Shelf/<uuid>/ (never references), persisted in Shelf/items.json and
// auto-cleaned per `settings.retention` (pinned items never expire).
//
// Drag in:  ShelfDragDetector (global, file drags only) ⇒ `isDragActive` ⇒ `notch.setFileDragActive(_:)` opens
//           the Shelf tab and holds it open; `ShelfTabView` shows `DropZonesView`; the drop itself lands on
//           ShelfDropTargetView (AppKit, handles file promises).
// Drag out: ShelfTileInteractionView (AppKit NSDraggingSource with the real file URLs, copy semantics).
// AirDrop:  ShelfSharingCoordinator (NSSharingService, holds the notch open while its UI is up).
import AppKit
import Observation
import SuperNotchCore
import UniformTypeIdentifiers

@Observable
final class ShelfModel {
    // MARK: FROZEN API state

    /// Newest first.
    private(set) var items: [ShelfItem] = []
    /// A file drag is in progress near/over the notch (drop mode).
    private(set) var isDragActive = false

    // MARK: Additive state (views)

    private(set) var selection = ShelfSelection()
    /// Files being copied / promises being received (the tab shows a spinner tile per import).
    private(set) var pendingImports = 0
    /// Drop zone under a drag over the open Shelf tab (set by the AppKit drop target).
    private(set) var dropTargetZone: ShelfDropZone?
    /// Quick Look: the previewed file and its siblings (`.quickLookPreview` in `ShelfTabView`).
    /// Settable so the SwiftUI binding can clear it when the preview panel closes.
    var quickLookURL: URL? {
        get { quickLookSelection }
        set {
            quickLookSelection = newValue
            quickLookSelectionChanged()
        }
    }
    private(set) var quickLookURLs: [URL] = []
    private var quickLookSelection: URL?
    /// A short user-facing status line ("Copied", "AirDrop can't send this") shown briefly in the tab.
    private(set) var statusMessage: String?

    var isEnabled: Bool { settingsStore.settings.shelfEnabled }
    var showsAirDropZone: Bool { settingsStore.settings.showAirDropZone && isAirDropAvailable }
    let isAirDropAvailable: Bool
    /// Drop zones replace the item row while a drag is over (or approaching) the notch.
    var isDropModeVisible: Bool { isDragActive || dropTargetZone != nil }
    var shelfFolderURL: URL { store.shelfDirectory }

    // MARK: Dependencies

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let notch: NotchViewModel
    @ObservationIgnored private let paths: SuperNotchPaths
    @ObservationIgnored private let store: ShelfStore
    @ObservationIgnored private let thumbnails = ShelfThumbnailCache()
    @ObservationIgnored private let dragDetector = ShelfDragDetector()
    @ObservationIgnored private let sharing: ShelfSharingCoordinator
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.snakez3101.supernotch.shelf-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    // MARK: Private state

    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var settingsToken: SettingsStore.ObserverToken?
    @ObservationIgnored private var quickLookHold: NotchHoldToken?
    @ObservationIgnored private var dragOutHold: NotchHoldToken?
    @ObservationIgnored private var chooseFilesHold: NotchHoldToken?
    @ObservationIgnored private var cleanupTimer: Timer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Last thumbnail per item for drag images (not observed; tiles keep their own copy in @State).
    @ObservationIgnored private var dragImages: [UUID: NSImage] = [:]

    // MARK: Init / lifecycle

    init(settings: SettingsStore, notch: NotchViewModel) {
        settingsStore = settings
        self.notch = notch
        paths = SuperNotchPaths(homeDirectory: NSHomeDirectory())
        store = ShelfStore(paths: paths)
        sharing = ShelfSharingCoordinator(notch: notch)
        isAirDropAvailable = ShelfSharingCoordinator.isAirDropAvailable
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        dragDetector.onNearChange = { [weak self] near in self?.setDragActive(near) }
        dragDetector.geometryProvider = { [weak self] in self?.dragGeometry() }
        settingsToken = settingsStore.observe { [weak self] old, new in
            self?.settingsChanged(old: old, new: new)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }
        applyEnabledState()
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.store.load()
            self.didLoad(loaded)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        dragDetector.stop()
        dragDetector.onNearChange = nil
        dragDetector.geometryProvider = nil
        settingsToken?.cancel()
        settingsToken = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        statusTask?.cancel()
        sharing.cancel()
        releaseHolds()
        isDragActive = false
        dropTargetZone = nil
        if hasLoaded {
            saveTask?.cancel()
            saveTask = nil
            store.saveNow(items)
        }
    }

    // MARK: FROZEN API

    /// Copies the files (or folders) into the shelf. Files already inside the shelf folder are ignored.
    func add(fileURLs: [URL]) {
        let shelfPath = store.shelfDirectory.standardizedFileURL.path + "/"
        let urls = fileURLs.filter { url in
            url.isFileURL && !url.standardizedFileURL.path.hasPrefix(shelfPath)
        }
        guard !urls.isEmpty else { return }
        importFiles(urls, move: false)
    }

    /// Adds text; a single URL becomes a link item.
    func addText(_ text: String) {
        guard let item = ShelfNaming.textItem(for: text, now: Date()) else { return }
        insert([item])
    }

    func remove(id: UUID) {
        remove(ids: [id])
    }

    func togglePin(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        scheduleSave()
        scheduleCleanup()
    }

    func removeAll() {
        let removed = items
        guard !removed.isEmpty else { return }
        items = []
        selection.clear()
        dragImages.removeAll()
        scheduleSave()
        scheduleCleanup()
        Task { [store, thumbnails] in
            await store.removeStorage(for: removed)
            await thumbnails.removeAll()
        }
        Log.shelf.info("Cleared the shelf (\(removed.count, privacy: .public) items)")
    }

    /// Absolute URL of the stored copy (nil for text and link items).
    func fileURL(for item: ShelfItem) -> URL? {
        store.url(for: item)
    }

    /// AirDrop the given items (files as stored copies, links as URLs, text as a .txt file).
    func airDrop(itemIDs: [UUID]) {
        let chosen = itemIDs.compactMap { id in items.first { $0.id == id } }
        guard !chosen.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let shareItems = await self.shareItems(for: chosen)
            if !self.sharing.airDrop(shareItems) {
                self.showStatus("AirDrop can't send \(chosen.count == 1 ? "this item" : "these items")")
            }
        }
    }

    // MARK: Additive API: selection

    func select(_ id: UUID, modifier: ShelfSelection.Modifier) {
        selection.click(id, orderedIDs: items.map(\.id), modifier: modifier)
    }

    /// Right-click on an unselected item selects just that item (Finder behaviour).
    func prepareContextMenu(for id: UUID) {
        if !selection.contains(id) { select(id, modifier: .none) }
    }

    func selectAll() {
        selection.selectAll(items.map(\.id))
    }

    func clearSelection() {
        selection.clear()
    }

    /// The selected items in shelf order, or just `id` when it is not part of the selection.
    func targetIDs(for id: UUID) -> [UUID] {
        selection.dragIDs(startingAt: id, orderedIDs: items.map(\.id))
    }

    func item(id: UUID) -> ShelfItem? {
        items.first { $0.id == id }
    }

    // MARK: Additive API: item actions

    func remove(ids: [UUID]) {
        let doomed = Set(ids)
        let removed = items.filter { doomed.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { doomed.contains($0.id) }
        selection.prune(keeping: Set(items.map(\.id)))
        for id in doomed { dragImages[id] = nil }
        scheduleSave()
        scheduleCleanup()
        let folders = removed.compactMap { store.url(for: $0)?.deletingLastPathComponent().path }
        Task { [store, thumbnails] in
            await store.removeStorage(for: removed)
            for folder in folders { await thumbnails.invalidate(pathPrefix: folder) }
        }
    }

    /// Double-click: Quick Look for files (the selection when the item is part of it), links open in the
    /// browser, text is copied.
    func primaryAction(id: UUID) {
        guard let item = item(id: id) else { return }
        switch item.kind {
        case .file, .folder, .image:
            quickLook(ids: targetIDs(for: id))
        case .link, .text:
            open(id: id)
        }
    }

    /// "Open" / Return: files open in their default app, links in the browser, text is copied.
    func open(id: UUID) {
        guard let item = item(id: id) else { return }
        switch item.kind {
        case .file, .folder, .image:
            guard let url = fileURL(for: item) else { return }
            if !NSWorkspace.shared.open(url) { showStatus("No app can open \(item.displayName)") }
        case .link:
            guard let string = item.urlString, let url = URL(string: string) else { return }
            if !NSWorkspace.shared.open(url) { showStatus("Can't open this link") }
        case .text:
            copyToPasteboard(ids: [id])
        }
    }

    /// Quick Look for the file items among `ids` (space bar / context menu).
    func quickLook(ids: [UUID]) {
        let urls = ids.compactMap { id in item(id: id).flatMap { fileURL(for: $0) } }
        guard let first = urls.first else { return }
        quickLookURLs = urls
        quickLookURL = first
    }

    func toggleQuickLook(for ids: [UUID]) {
        if quickLookURL != nil { quickLookURL = nil } else { quickLook(ids: ids) }
    }

    func revealInFinder(ids: [UUID]) {
        let urls = ids.compactMap { id in item(id: id).flatMap { fileURL(for: $0) } }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Where the item came from, if that file still exists.
    func originalURL(for item: ShelfItem) -> URL? {
        guard let path = item.originalPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func revealOriginal(id: UUID) {
        guard let item = item(id: id), let url = originalURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copies the items to the general pasteboard (files as file URLs, links as URL + string, text as string).
    func copyToPasteboard(ids: [UUID]) {
        let chosen = ids.compactMap { item(id: $0) }
        var writers: [any NSPasteboardWriting] = []
        for item in chosen {
            switch item.kind {
            case .file, .folder, .image:
                if let url = fileURL(for: item) { writers.append(url as NSURL) }
            case .link:
                if let string = item.urlString {
                    let pasteboardItem = NSPasteboardItem()
                    pasteboardItem.setString(string, forType: .string)
                    if URL(string: string) != nil { pasteboardItem.setString(string, forType: .URL) }
                    writers.append(pasteboardItem)
                }
            case .text:
                if let text = item.text { writers.append(text as NSString) }
            }
        }
        guard !writers.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects(writers) {
            showStatus(chosen.count == 1 ? "Copied" : "Copied \(chosen.count) items")
        }
    }

    /// Share menu anchored to the tile view that was right-clicked.
    func share(ids: [UUID], from view: NSView) {
        let chosen = ids.compactMap { item(id: $0) }
        guard !chosen.isEmpty else { return }
        Task { [weak self, weak view] in
            guard let self, let view else { return }
            let shareItems = await self.shareItems(for: chosen)
            self.sharing.showSharePicker(items: shareItems, relativeTo: view)
        }
    }

    /// AirDrop tile click: the selection, or (nothing selected) an Open panel to pick files to send.
    func airDropSelectionOrChooseFiles() {
        let selected = selection.orderedSelection(items.map(\.id))
        if !selected.isEmpty {
            airDrop(itemIDs: selected)
        } else {
            chooseFilesForAirDrop()
        }
    }

    func openShelfFolder() {
        let url = store.shelfDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        NSWorkspace.shared.open(url)
    }

    // MARK: Additive API: drag out (called by ShelfTileInteractionView)

    /// Pasteboard writers for a drag of `ids`: real file URLs (no temp copies), link URLs, text.
    func dragPayloads(for ids: [UUID]) -> [ShelfDragPayload] {
        var payloads: [ShelfDragPayload] = []
        for id in ids {
            guard let item = item(id: id) else { continue }
            switch item.kind {
            case .file, .folder, .image:
                if let url = fileURL(for: item) { payloads.append(ShelfDragPayload(id: id, writer: url as NSURL)) }
            case .link:
                if let string = item.urlString, let url = URL(string: string) {
                    payloads.append(ShelfDragPayload(id: id, writer: url as NSURL))
                }
            case .text:
                if let text = item.text { payloads.append(ShelfDragPayload(id: id, writer: text as NSString)) }
            }
        }
        return payloads
    }

    /// Image shown under the cursor while dragging an item out.
    func dragImage(for id: UUID) -> NSImage {
        if let image = dragImages[id] { return image }
        if let item = item(id: id) { return fallbackIcon(for: item) }
        return NSImage(size: NSSize(width: 32, height: 32))
    }

    func dragOutBegan() {
        dragOutHold?.release()
        dragOutHold = notch.holdOpen(reason: "shelf.drag-out")
    }

    func dragOutEnded() {
        dragOutHold?.release()
        dragOutHold = nil
    }

    // MARK: Additive API: drop in (called by ShelfDropTargetView)

    func dropHover(_ zone: ShelfDropZone?) {
        if dropTargetZone != zone { dropTargetZone = zone }
    }

    func dropSessionEnded() {
        dropTargetZone = nil
        if isDragActive { dragDetector.dropFinished() }
    }

    /// Handles a drop. File URLs and file promises are copied (shelf) or sent (AirDrop); otherwise web URLs,
    /// text and raw image data. Returns false when nothing usable was on the pasteboard.
    func acceptDrop(from pasteboard: NSPasteboard, zone: ShelfDropZone) -> Bool {
        let targetZone: ShelfDropZone = (zone == .airDrop && showsAirDropZone) ? .airDrop : .shelf
        let objects =
            pasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self, NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) ?? []
        var fileURLs: [URL] = []
        var receivers: [NSFilePromiseReceiver] = []
        for object in objects {
            if let receiver = object as? NSFilePromiseReceiver {
                receivers.append(receiver)
            } else if let url = object as? URL, url.isFileURL {
                fileURLs.append(url)
            }
        }

        if !fileURLs.isEmpty || !receivers.isEmpty {
            receivePromises(receivers) { [weak self] (promised: [URL]) in
                guard let self else { return }
                switch targetZone {
                case .shelf:
                    self.add(fileURLs: fileURLs)
                    if !promised.isEmpty { self.importFiles(promised, move: true) }
                case .airDrop:
                    if !self.sharing.airDrop(fileURLs + promised) {
                        self.showStatus("AirDrop can't send these files")
                    }
                }
            }
            return true
        }

        // No files: links, text, raw images.
        let droppedURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let webURL = droppedURLs.first { !$0.isFileURL }
        let string = pasteboard.string(forType: .string)
        let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        let imageName = pasteboard.data(forType: .png) != nil ? "Image.png" : "Image.tiff"

        switch targetZone {
        case .shelf:
            if let webURL {
                addText(webURL.absoluteString)
            } else if let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addText(string)
            } else if let imageData {
                importData(imageData, fileName: imageName)
            } else {
                return false
            }
        case .airDrop:
            if let webURL {
                if !sharing.airDrop([webURL]) { showStatus("AirDrop can't send this link") }
            } else if let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                airDropText(string)
            } else if let imageData {
                Task { [weak self] in
                    guard let self, let url = await self.store.makeShareDataFile(imageData, fileName: imageName)
                    else { return }
                    if !self.sharing.airDrop([url]) { self.showStatus("AirDrop can't send this image") }
                }
            } else {
                return false
            }
        }
        return true
    }

    // MARK: Additive API: thumbnails

    /// Quick Look thumbnail, falling back to the Finder icon. Also remembered for drag images.
    func thumbnail(for item: ShelfItem, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        guard let url = fileURL(for: item) else { return nil }
        let generated = await thumbnails.thumbnail(for: url, pointSize: pointSize, scale: scale)
        let image = generated ?? fallbackIcon(for: item)
        dragImages[item.id] = image
        return image
    }

    func fallbackIcon(for item: ShelfItem) -> NSImage {
        if let url = fileURL(for: item) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .plainText)
    }

    // MARK: Private: loading, saving, retention

    private func didLoad(_ loaded: [ShelfItem]) {
        // Anything added before the index finished loading (a very early drop) is kept on top.
        let known = Set(items.map(\.id))
        items = ShelfIndex.sortedNewestFirst(items + loaded.filter { !known.contains($0.id) })
        hasLoaded = true
        Log.shelf.info("Shelf loaded (\(self.items.count, privacy: .public) items)")
        applyRetention()
        let snapshot = items
        Task { [store] in await store.sweep(keeping: snapshot) }
    }

    private func insert(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        items = ShelfIndex.sortedNewestFirst(newItems + items)
        scheduleSave()
        scheduleCleanup()
    }

    private func scheduleSave() {
        guard hasLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.store.save(self.items)
        }
    }

    /// Removes expired unpinned items and schedules one timer for the next expiry (no polling).
    private func applyRetention() {
        guard hasLoaded else { return }
        let period = settingsStore.settings.retention
        let expired = RetentionPolicy.partition(items, period: period, now: Date()).expired
        if !expired.isEmpty {
            Log.shelf.info("Auto-cleanup removed \(expired.count, privacy: .public) shelf items")
            remove(ids: expired.map(\.id))
        }
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        let period = settingsStore.settings.retention
        guard isStarted, hasLoaded, let delay = RetentionPolicy.nextCleanupDelay(items, period: period, now: Date())
        else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }
        timer.tolerance = min(max(delay * 0.1, 1), 60)
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    // MARK: Private: settings, drag mode

    private func settingsChanged(old: AppSettings, new: AppSettings) {
        if old.shelfEnabled != new.shelfEnabled { applyEnabledState() }
        if old.retention != new.retention { applyRetention() }
    }

    private func applyEnabledState() {
        if isStarted && isEnabled {
            dragDetector.start()
        } else {
            dragDetector.stop()
            setDragActive(false)
        }
    }

    /// Drop mode on/off. The shell opens the Shelf tab, holds the notch open and keeps the panel hit-testable
    /// for the drop (`NotchViewModel.setFileDragActive`); calling it here (as well as from the container view)
    /// is idempotent and also works while the panel is hidden in fullscreen.
    private func setDragActive(_ active: Bool) {
        guard active != isDragActive else { return }
        if active {
            guard isEnabled, notch.geometry != nil else { return }
            isDragActive = true
            notch.setFileDragActive(true)
            Log.shelf.debug("Drop mode on")
        } else {
            isDragActive = false
            dropTargetZone = nil
            notch.setFileDragActive(false)
            Log.shelf.debug("Drop mode off")
        }
    }

    private func dragGeometry() -> (notch: CGRect, open: CGRect?)? {
        guard let geometry = notch.geometry else { return nil }
        let size = geometry.size(for: .expanded(.shelf), closedWidthExtra: 0)
        return (geometry.notchRect, geometry.shapeRectInScreen(for: size))
    }

    private func releaseHolds() {
        if isDragActive { notch.setFileDragActive(false) }
        chooseFilesHold?.release()
        chooseFilesHold = nil
        quickLookHold?.release()
        quickLookHold = nil
        dragOutHold?.release()
        dragOutHold = nil
    }

    private func quickLookSelectionChanged() {
        if quickLookURL != nil {
            if quickLookHold == nil { quickLookHold = notch.holdOpen(reason: "shelf.quicklook") }
        } else {
            quickLookHold?.release()
            quickLookHold = nil
            quickLookURLs = []
        }
    }

    // MARK: Private: importing

    private func importFiles(_ urls: [URL], move: Bool) {
        guard !urls.isEmpty else { return }
        pendingImports += urls.count
        Task { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for url in urls {
                let result = await self.store.importFile(at: url, move: move, now: Date())
                self.pendingImports = max(self.pendingImports - 1, 0)
                switch result {
                case .success(let item): self.insert([item])
                case .failure(let error): failures.append(error.fileName)
                }
            }
            if let first = failures.first {
                let message = failures.count == 1 ? "Couldn't add \(first)" : "Couldn't add \(failures.count) files"
                self.showStatus(message)
            }
        }
    }

    private func importData(_ data: Data, fileName: String) {
        pendingImports += 1
        Task { [weak self] in
            guard let self else { return }
            let result = await self.store.importData(data, fileName: fileName, now: Date())
            self.pendingImports = max(self.pendingImports - 1, 0)
            switch result {
            case .success(let item): self.insert([item])
            case .failure: self.showStatus("Couldn't add the dropped image")
            }
        }
    }

    /// Receives file promises (Mail, Photos, Safari…) into a fresh incoming folder, then calls `completion`
    /// on the main actor with every file that arrived (immediately when there are no promises).
    private func receivePromises(
        _ receivers: [NSFilePromiseReceiver], completion: @escaping @MainActor ([URL]) -> Void
    ) {
        guard !receivers.isEmpty else {
            completion([])
            return
        }
        guard let folder = store.makeIncomingFolder() else {
            showStatus("Couldn't receive the dropped files")
            completion([])
            return
        }
        let receiverCount = receivers.count
        pendingImports += receiverCount
        let expected = receivers.reduce(0) { $0 + max($1.fileTypes.count, 1) }
        let collector = ShelfPromiseCollector(expected: expected)
        collector.onComplete = { [weak self] urls, failures in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingImports = max(self.pendingImports - receiverCount, 0)
                if failures > 0 { self.showStatus("Some dropped files couldn't be received") }
                completion(urls)
            }
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) {
                @Sendable url, error in
                collector.received(url, failed: error != nil)
            }
        }
        collector.armTimeout(seconds: 120)
    }

    private func airDropText(_ text: String) {
        Task { [weak self] in
            guard let self, let url = await self.store.makeShareTextFile(text) else { return }
            if !self.sharing.airDrop([url]) { self.showStatus("AirDrop can't send this text") }
        }
    }

    /// Share items for AirDrop / the Share menu: file URLs, link URLs, and text as a temporary .txt file.
    private func shareItems(for chosen: [ShelfItem]) async -> [Any] {
        var result: [Any] = []
        for item in chosen {
            switch item.kind {
            case .file, .folder, .image:
                if let url = fileURL(for: item) { result.append(url) }
            case .link:
                if let string = item.urlString, let url = URL(string: string) { result.append(url) }
            case .text:
                if let text = item.text, let url = await store.makeShareTextFile(text) { result.append(url) }
            }
        }
        return result
    }

    private func chooseFilesForAirDrop() {
        let panel = NSOpenPanel()
        panel.title = "AirDrop"
        panel.message = "Choose files to send with AirDrop"
        panel.prompt = "AirDrop"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.level = .modalPanel
        chooseFilesHold?.release()
        chooseFilesHold = notch.holdOpen(reason: "shelf.choose-files")
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                self?.chooseFilesHold?.release()
                self?.chooseFilesHold = nil
                guard response == .OK else { return }
                let urls = panel.urls
                guard let self, !urls.isEmpty else { return }
                if !self.sharing.airDrop(urls) { self.showStatus("AirDrop can't send these files") }
            }
        }
        panel.orderFrontRegardless()
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }
}

// MARK: - Drag payload

/// One dragged shelf item and what goes on the drag pasteboard for it.
struct ShelfDragPayload {
    let id: UUID
    let writer: any NSPasteboardWriting
}

// MARK: - File promise collector

/// Counts promised files as they arrive on the promise queue and reports once, on the main queue, when all
/// arrived (or the timeout hits). Thread-safe via a lock.
nonisolated final class ShelfPromiseCollector: @unchecked Sendable {
    /// Called exactly once on the main queue with the received files and the number of failures.
    var onComplete: (@Sendable ([URL], Int) -> Void)?

    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []
    private var failures = 0
    private var finished = false

    init(expected: Int) {
        remaining = max(expected, 1)
    }

    func received(_ url: URL, failed: Bool) {
        lock.lock()
        if failed { failures += 1 } else { urls.append(url) }
        remaining -= 1
        let done = remaining <= 0
        lock.unlock()
        if done { finish() }
    }

    func armTimeout(seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            finish()
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let result = urls
        let failed = failures
        let callback = onComplete
        onComplete = nil
        lock.unlock()
        DispatchQueue.main.async {
            callback?(result, failed)
        }
    }
}
