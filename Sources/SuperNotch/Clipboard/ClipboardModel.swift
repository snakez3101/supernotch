// Owner: shelf-clipboard (SPEC §A.4, §A.10, §D.4 `ClipboardModel`, FROZEN API + additive extras).
//
// Clipboard history ("second clipboard"): text, links, images (stored as PNG files) and Finder file copies.
// * Capture: `ClipboardMonitor` polls the change count; on a change we first look only at the TYPES and skip
//   concealed/transient/auto-generated data (password managers, nspasteboard.org), our own writes (marker type)
//   and ignored apps, and only then read the content (`ClipboardCaptureFilter`, `ClipboardContentClassifier`).
// * De-duplicated by content hash (images by pixel data), capped at `settings.clipboardLimit` (pinned entries
//   are exempt), auto-cleaned with the shared retention setting, persisted in Clipboard/history.json.
// * ⌥⌘V opens `ClipboardHistoryPanel`; Return pastes (write + ⌘V via CGEvent, needs PostEvent permission),
//   otherwise it copies and shows a hint.
// Never logs clipboard contents (SPEC §F.2).
import AppKit
import Observation
import SuperNotchCore

@Observable
final class ClipboardModel {
    // MARK: FROZEN API state

    /// Insertion order, newest first (the storage order).
    private(set) var history: [ClipboardEntry] = []
    private(set) var isHistoryPanelVisible = false
    /// PostEvent permission granted (Return pastes instead of only copying).
    private(set) var canPaste = false

    /// Newest first, pinned first (SPEC §D.4).
    var entries: [ClipboardEntry] { ClipboardHistory.ordered(history) }

    // MARK: Additive state (views)

    /// Newest first regardless of pins (the Shelf tab's strip).
    var recentEntries: [ClipboardEntry] { history }
    /// Search text of the history panel (bindable; keeps the highlighted row valid).
    var searchQuery: String {
        get { searchText }
        set {
            searchText = newValue
            searchChanged()
        }
    }
    private var searchText = ""
    /// Highlighted row of the history panel.
    private(set) var panelSelectionID: UUID?
    /// Entries shown in the panel for the current search.
    var filteredEntries: [ClipboardEntry] { ClipboardHistory.filter(entries, query: searchQuery) }
    /// macOS pasteboard privacy state (15.4+).
    private(set) var pasteboardAccess: ClipboardPasteboardAccess = .notDecided
    /// A short hint ("Copied — press ⌘V to paste") shown in the panel and the Shelf tab.
    private(set) var statusMessage: String?
    /// Bumped every time the panel opens (the view re-focuses its search field).
    private(set) var panelPresentationCount = 0

    var isEnabled: Bool { settingsStore.settings.clipboardEnabled }

    // MARK: Dependencies

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let notch: NotchViewModel
    @ObservationIgnored private let paths: SuperNotchPaths
    @ObservationIgnored private let store: ClipboardStore
    @ObservationIgnored private let monitor = ClipboardMonitor()
    @ObservationIgnored private let thumbnails = ShelfThumbnailCache()
    @ObservationIgnored private var panelController: ClipboardHistoryPanelController?

    // MARK: Private state

    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var settingsToken: SettingsStore.ObserverToken?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var pasteTask: Task<Void, Never>?
    @ObservationIgnored private var permissionPollTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: Init / lifecycle

    init(settings: SettingsStore, notch: NotchViewModel) {
        settingsStore = settings
        self.notch = notch
        paths = SuperNotchPaths(homeDirectory: NSHomeDirectory())
        store = ClipboardStore(paths: paths)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refreshPermissions()
        monitor.onChange = { [weak self] in self?.pasteboardChanged() }
        settingsToken = settingsStore.observe { [weak self] old, new in
            self?.settingsChanged(old: old, new: new)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.applyRetention() }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            })
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
        monitor.stop()
        monitor.onChange = nil
        settingsToken?.cancel()
        settingsToken = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        permissionPollTask?.cancel()
        pasteTask?.cancel()
        statusTask?.cancel()
        hideHistoryPanel()
        if hasLoaded {
            saveTask?.cancel()
            saveTask = nil
            store.saveNow(history)
        }
    }

    // MARK: FROZEN API: panel

    func toggleHistoryPanel() {
        if isHistoryPanelVisible { hideHistoryPanel() } else { showHistoryPanel() }
    }

    func showHistoryPanel() {
        refreshPermissions()
        if isEnabled { monitor.pollNow() }
        searchQuery = ""
        panelSelectionID = filteredEntries.first?.id
        panelPresentationCount += 1
        // The notch and the panel would overlap, and a key notch panel would catch the ⌘V meant for the app.
        if notch.presentation.isExpanded { notch.close() }
        let controller = panelController ?? ClipboardHistoryPanelController(model: self, notch: notch)
        panelController = controller
        controller.show()
        isHistoryPanelVisible = true
    }

    func hideHistoryPanel() {
        guard isHistoryPanelVisible else { return }
        isHistoryPanelVisible = false
        panelController?.hide()
    }

    /// The panel window closed by itself (lost key status, Esc handled by AppKit).
    func historyPanelDidClose() {
        isHistoryPanelVisible = false
    }

    // MARK: FROZEN API: entries

    /// Writes the entry to the pasteboard, closes the panel and sends ⌘V to the frontmost app. Without the
    /// PostEvent permission it only copies and shows a hint.
    func paste(_ entryID: UUID) {
        guard let entry = entry(id: entryID) else { return }
        guard writeToPasteboard(entry) else {
            showStatus("Couldn't copy this item")
            return
        }
        canPaste = ClipboardPasteService.hasPostEventAccess
        guard canPaste else {
            showStatus("Copied. Press ⌘V to paste (allow SuperNotch in Accessibility to paste with Return).")
            return
        }
        hideHistoryPanel()
        pasteTask?.cancel()
        pasteTask = Task {
            // Let the panel resign key so the keystroke lands in the app underneath.
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            ClipboardPasteService.postCommandV()
        }
    }

    /// Writes the entry to the pasteboard (with our marker, so it is not recorded again).
    func copy(_ entryID: UUID) {
        guard let entry = entry(id: entryID) else { return }
        if writeToPasteboard(entry) {
            showStatus("Copied")
        } else {
            showStatus("Couldn't copy this item")
        }
    }

    func delete(_ entryID: UUID) {
        guard let index = history.firstIndex(where: { $0.id == entryID }) else { return }
        let visible = filteredEntries
        let old = history
        history.remove(at: index)
        if panelSelectionID == entryID {
            let position = visible.firstIndex { $0.id == entryID } ?? 0
            let remaining = filteredEntries
            panelSelectionID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
        }
        historyChanged(old: old)
    }

    func togglePin(_ entryID: UUID) {
        guard let index = history.firstIndex(where: { $0.id == entryID }) else { return }
        let old = history
        history[index].pinned.toggle()
        historyChanged(old: old)
    }

    /// Removes every entry, including pinned ones, and their image files.
    func clearAll() {
        let old = history
        history = []
        panelSelectionID = nil
        historyChanged(old: old)
        Log.clipboard.info("Clipboard history cleared")
    }

    /// Shows the system prompt for the PostEvent permission (first time) and watches for the grant.
    func requestPastePermission() {
        let granted = ClipboardPasteService.requestPostEventAccess()
        canPaste = granted || ClipboardPasteService.hasPostEventAccess
        guard !canPaste else { return }
        // The grant happens in System Settings; poll for up to two minutes (only while waiting).
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if ClipboardPasteService.hasPostEventAccess {
                    self.canPaste = true
                    Log.clipboard.info("Paste permission granted")
                    return
                }
            }
        }
    }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard case .image(let relativePath, _, _) = entry.content else { return nil }
        return store.url(forRelativePath: relativePath)
    }

    // MARK: Additive API

    func entry(id: UUID) -> ClipboardEntry? {
        history.first { $0.id == id }
    }

    func openAccessibilitySettings() {
        ClipboardPasteService.openAccessibilitySettings()
    }

    func openPrivacySettings() {
        ClipboardPasteService.openPrivacySettings()
    }

    /// "Turn On" in the panel's disabled state.
    func enableHistory() {
        settingsStore.update { $0.clipboardEnabled = true }
    }

    /// Settings › Clipboard (closes the panel first).
    func openSettings() {
        hideHistoryPanel()
        notch.openSettings()
    }

    /// Small preview for image entries (Quick Look thumbnail of the stored PNG).
    func thumbnail(for entry: ClipboardEntry, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        guard let url = imageURL(for: entry) else { return nil }
        return await thumbnails.thumbnail(for: url, pointSize: pointSize, scale: scale)
    }

    /// Re-reads the PostEvent grant and the pasteboard privacy setting.
    func refreshPermissions() {
        canPaste = ClipboardPasteService.hasPostEventAccess
        let access = ClipboardPasteService.pasteboardAccess
        if access != pasteboardAccess {
            pasteboardAccess = access
            Log.clipboard.info("Pasteboard access: \(access.summary, privacy: .public)")
        }
    }

    // Panel navigation (keyboard handled by ClipboardHistoryPanelController).

    func selectPanelEntry(_ id: UUID) {
        panelSelectionID = id
    }

    func movePanelSelection(by delta: Int) {
        let visible = filteredEntries
        guard !visible.isEmpty else {
            panelSelectionID = nil
            return
        }
        let current = panelSelectionID.flatMap { id in visible.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), visible.count - 1)
        } else {
            next = delta >= 0 ? 0 : visible.count - 1
        }
        panelSelectionID = visible[next].id
    }

    func pasteSelection() {
        guard let id = panelSelectionID ?? filteredEntries.first?.id else { return }
        paste(id)
    }

    func copySelection() {
        guard let id = panelSelectionID ?? filteredEntries.first?.id else { return }
        copy(id)
        hideHistoryPanel()
    }

    func deleteSelection() {
        guard let id = panelSelectionID else { return }
        delete(id)
    }

    func togglePinSelection() {
        guard let id = panelSelectionID else { return }
        togglePin(id)
    }

    /// ⌘1…⌘9: paste the n-th visible entry.
    func pasteVisibleEntry(at index: Int) {
        let visible = filteredEntries
        guard visible.indices.contains(index) else { return }
        paste(visible[index].id)
    }

    // MARK: Private: capture

    private func pasteboardChanged() {
        guard isEnabled, hasLoaded, pasteboardAccess.allowsAutomaticCapture else { return }
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ignored = settingsStore.settings.clipboardIgnoredApps

        // 1. Decide from the types alone: concealed/transient data is never read.
        if case .skip(let reason) = ClipboardCaptureFilter.decide(
            types: types, sourceBundleID: frontmost?.bundleIdentifier, ignoredBundleIDs: ignored)
        {
            // Only the marker type / our own words are logged, never content.
            Log.clipboard.debug("Skipped a pasteboard change (\(reason, privacy: .public))")
            return
        }
        // 2. An explicit source marker (nspasteboard.org) can name an ignored app.
        let sourceType = NSPasteboard.PasteboardType(ClipboardCaptureFilter.sourceType)
        let marker = types.contains(sourceType.rawValue) ? pasteboard.string(forType: sourceType) : nil
        let source = ClipboardCaptureFilter.sourceBundleID(marker: marker, frontmost: frontmost?.bundleIdentifier)
        if marker != nil,
            case .skip = ClipboardCaptureFilter.decide(types: types, sourceBundleID: source, ignoredBundleIDs: ignored)
        {
            Log.clipboard.debug("Skipped a pasteboard change (ignored app)")
            return
        }

        // 3. Read what we need and pick the representation.
        let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
        var filePaths: [String] = []
        if types.contains(fileURLType) {
            let urls =
                pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL] ?? []
            filePaths = urls.map(\.path)
        }
        let urlString =
            types.contains(NSPasteboard.PasteboardType.URL.rawValue) ? pasteboard.string(forType: .URL) : nil
        let snapshot = ClipboardPasteboardSnapshot(
            types: types, string: pasteboard.string(forType: .string), urlString: urlString, filePaths: filePaths,
            imageType: ClipboardContentClassifier.preferredImageType(in: types))
        let settings = settingsStore.settings
        guard let kind = ClipboardContentClassifier.classify(snapshot, captureImages: settings.captureImages) else {
            return
        }
        let appName = Self.appName(bundleID: source, frontmost: frontmost)

        switch kind {
        case .text(let text):
            record(.text(text), contentHash: nil, source: source, appName: appName)
        case .link(let link):
            record(.link(link), contentHash: nil, source: source, appName: appName)
        case .files(let paths):
            record(.files(paths), contentHash: nil, source: source, appName: appName)
        case .image(let type):
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) else { return }
            captureImage(data, source: source, appName: appName)
        }
    }

    private func captureImage(_ data: Data, source: String?, appName: String?) {
        guard data.count <= ClipboardStore.maxImageBytes else {
            Log.clipboard.notice("Skipped a copied image larger than the limit")
            return
        }
        let capturedAt = Date()
        Task { [weak self] in
            guard let self, let prepared = await self.store.prepareImage(data) else { return }
            // Same pixels again: move the existing entry up instead of writing another file.
            if let existing = self.history.first(where: { $0.contentHash == prepared.contentHash }) {
                self.record(existing.content, contentHash: prepared.contentHash, source: source, appName: appName)
                return
            }
            let relativePath = ClipboardHistory.imageRelativePath(id: UUID())
            guard await self.store.writeImage(prepared.png, relativePath: relativePath) else { return }
            self.record(
                .image(relativePath: relativePath, pixelWidth: prepared.pixelWidth, pixelHeight: prepared.pixelHeight),
                contentHash: prepared.contentHash, source: source, appName: appName, capturedAt: capturedAt)
        }
    }

    private func record(
        _ content: ClipboardContent, contentHash: String?, source: String?, appName: String?,
        capturedAt: Date = Date()
    ) {
        let entry = ClipboardEntry(
            content: content, sourceAppBundleID: source, sourceAppName: appName, capturedAt: capturedAt,
            contentHash: contentHash)
        let old = history
        history = ClipboardCaptureFilter.insert(entry, into: history, limit: settingsStore.settings.clipboardLimit)
        historyChanged(old: old)
    }

    /// Writes an entry back and moves it to the top (a pasted item is "recent" again).
    private func writeToPasteboard(_ entry: ClipboardEntry) -> Bool {
        guard let changeCount = ClipboardPasteService.write(entry, imageURL: imageURL(for: entry)) else {
            return false
        }
        monitor.noteOwnWrite(changeCount: changeCount)
        if let index = history.firstIndex(where: { $0.id == entry.id }), index > 0 {
            let old = history
            var bumped = history.remove(at: index)
            bumped.capturedAt = Date()
            history.insert(bumped, at: 0)
            historyChanged(old: old)
        }
        return true
    }

    private static func appName(bundleID: String?, frontmost: NSRunningApplication?) -> String? {
        guard let bundleID else { return nil }
        if let frontmost, frontmost.bundleIdentifier == bundleID { return frontmost.localizedName }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
    }

    // MARK: Private: persistence, retention, settings

    private func didLoad(_ loaded: [ClipboardEntry]) {
        // Entries captured before loading finished stay on top.
        let known = Set(history.map(\.contentHash))
        let settings = settingsStore.settings
        history = ClipboardHistory.trimmed(
            history + loaded.filter { !known.contains($0.contentHash) }, period: settings.retention,
            limit: settings.clipboardLimit, now: Date())
        hasLoaded = true
        Log.clipboard.info("Clipboard history loaded (\(self.history.count, privacy: .public) entries)")
        let snapshot = history
        Task { [store] in await store.sweepOrphans(keeping: snapshot) }
        if loaded.count != history.count { scheduleSave() }
        scheduleCleanup()
    }

    private func historyChanged(old: [ClipboardEntry]) {
        let released = ClipboardHistory.releasedImagePaths(old: old, new: history)
        if !released.isEmpty {
            store.deleteImages(released)
            let prefixes = released.compactMap { store.url(forRelativePath: $0)?.path }
            Task { [thumbnails] in
                for prefix in prefixes { await thumbnails.invalidate(pathPrefix: prefix) }
            }
        }
        if let selection = panelSelectionID, !history.contains(where: { $0.id == selection }) {
            panelSelectionID = filteredEntries.first?.id
        }
        scheduleSave()
        scheduleCleanup()
    }

    private func scheduleSave() {
        guard hasLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.store.save(self.history)
        }
    }

    private func applyRetention() {
        guard hasLoaded else { return }
        let settings = settingsStore.settings
        let trimmed = ClipboardHistory.trimmed(
            history, period: settings.retention, limit: settings.clipboardLimit, now: Date())
        if trimmed.count != history.count {
            let old = history
            Log.clipboard.info("Auto-cleanup removed \(old.count - trimmed.count, privacy: .public) clipboard entries")
            history = trimmed
            historyChanged(old: old)
        } else {
            scheduleCleanup()
        }
    }

    /// One timer for the next expiry (no polling for retention).
    private func scheduleCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        guard isStarted, hasLoaded,
            let delay = RetentionPolicy.nextCleanupDelay(
                history, period: settingsStore.settings.retention, now: Date())
        else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }
        timer.tolerance = min(max(delay * 0.1, 1), 60)
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    private func settingsChanged(old: AppSettings, new: AppSettings) {
        if old.clipboardEnabled != new.clipboardEnabled { applyEnabledState() }
        if old.retention != new.retention || old.clipboardLimit != new.clipboardLimit { applyRetention() }
    }

    private func applyEnabledState() {
        if isStarted && isEnabled {
            monitor.start()
        } else {
            monitor.stop()
        }
    }

    private func searchChanged() {
        let visible = filteredEntries
        if let selection = panelSelectionID, visible.contains(where: { $0.id == selection }) { return }
        panelSelectionID = visible.first?.id
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }
}
