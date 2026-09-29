// Owner: notch-shell (SPEC §A.2–§A.8, §D.4 FROZEN API).
//
// The notch's state machine: presentation (closed / peek / expanded), hover intent, popup coordination,
// hold-open tokens, fullscreen visibility and keyboard-focus policy. Pure decisions live in Core
// (`HoverIntent`, `PopupPolicy`, `NotchPopupQueue`, `NotchGeometry`); AppKit work (panel, monitors, screens,
// hotkeys) is done by `NotchWindowController` through `NotchPanelHost`.
//
// Energy (SPEC §F.1): no repeating timers. One deadline task for hover dwell/grace and one for popup
// deadlines exist only while something is actually pending.
import AppKit
import Observation
import SuperNotchCore
import os

/// What the view model asks of the AppKit side (implemented by `NotchWindowController`).
protocol NotchPanelHost: AnyObject {
    /// Presentation, geometry or visibility changed: order the panel in/out, refresh monitors and hit-testing.
    func notchStateDidChange()
    /// Make the panel key (explicit interaction only: hotkey, menu, click).
    func notchRequestsKeyFocus()
    /// Give keyboard focus back to the previously active app (the notch collapsed or a new popup appeared).
    func notchRelinquishesKeyFocus()
    /// Pause/resume the global hotkeys (while a shortcut recorder is capturing keys).
    func notchSetHotkeysSuspended(_ suspended: Bool)
}

@Observable
final class NotchViewModel {

    // MARK: - Frozen API (SPEC §D.4)

    /// Drives the UI.
    private(set) var presentation: NotchPresentation = .closed
    /// The last tab (kept while closed). Change it with `open(tab:)` / `selectTab(_:)` while expanded.
    var selectedTab: NotchTab = .home
    /// nil ⇒ no built-in notch display (clamshell, external only, below-notch mode).
    private(set) var geometry: NotchGeometry?
    /// The frontmost app is fullscreen on the notch display.
    private(set) var isFullscreenActive = false
    /// The pointer is over the notch (the physical notch / closed shape, or the open shape + margin).
    private(set) var isHovering = false
    /// The panel is key: keyboard shortcuts (Return/Esc on the permission card) are allowed.
    private(set) var isKeyFocused = false
    /// Popups waiting to be shown (critical first, then oldest). Claude rows may pulse while non-empty.
    private(set) var queuedPopups: [PopupRequest] = []
    /// Set by AppDelegate: shows the Settings window.
    @ObservationIgnored var openSettingsHandler: (() -> Void)?

    // MARK: - Additional state (shell views, Settings, other streams may read)

    /// Closed-state wings (`NotchSlots.closedWings`, rule in `NotchMetrics.closedWings`), reported by
    /// `NotchContainerView`.
    private(set) var closedWings: NotchClosedWings = .none
    /// A file drag hovers near the notch (mirrors `ShelfModel.isDragActive`), reported by `NotchContainerView`.
    private(set) var isFileDragActive = false
    /// True while the panel should be on screen.
    private(set) var isPanelVisible = false
    /// Global shortcuts macOS refused to register (usually taken by another app).
    private(set) var hotkeyConflicts: Set<HotkeyAction> = []

    var isOpen: Bool { !presentation.isClosed }
    /// Total closed wing width (`NotchGeometry.size(for:closedWidthExtra:)`).
    var closedWidthExtra: CGFloat { closedWings.total }
    /// The popup on screen, if any.
    var currentPopup: PopupRequest? { presentation.peekRequest }
    /// Fullscreen is active and the user wants the notch hidden then (only 🔴 popups show).
    var isHiddenByFullscreen: Bool { isFullscreenActive && settings.settings.hideInFullscreen }
    /// The panel may become key (only while open; AppKit asks on clicks, the shell asks on hotkeys).
    var allowsKeyFocus: Bool { isOpen && isPanelVisible }

    // MARK: - Internals

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored weak var host: NotchPanelHost?
    @ObservationIgnored private var hoverIntent: HoverIntent
    @ObservationIgnored private var popupQueue = NotchPopupQueue()
    @ObservationIgnored private let hoverTimer = NotchDeadlineTimer()
    @ObservationIgnored private let popupTimer = NotchDeadlineTimer()
    @ObservationIgnored private var holds: [Int: String] = [:]
    @ObservationIgnored private var nextHoldID = 0
    @ObservationIgnored private var dragHold: NotchHoldToken?
    @ObservationIgnored private var settingsToken: SettingsStore.ObserverToken?
    @ObservationIgnored private var isStarted = false
    /// The current expanded state was opened explicitly (hotkey, menu, click): shown even in fullscreen.
    @ObservationIgnored private var openedExplicitly = false

    init(settings: SettingsStore) {
        self.settings = settings
        let current = settings.settings
        hoverIntent = HoverIntent(openDelay: current.hoverOpenDelay, closeDelay: current.hoverCloseDelay)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        settingsToken = settings.observe { [weak self] old, new in
            self?.settingsDidChange(old: old, new: new)
        }
        applyHoverDelays(settings.settings)
        Log.notch.debug("Notch view model started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        settingsToken?.cancel()
        settingsToken = nil
        hoverTimer.cancel()
        popupTimer.cancel()
        popupQueue.removeAll()
        syncQueuedPopups()
        dragHold?.release()
        dragHold = nil
        holds.removeAll()
        openedExplicitly = false
        presentation = .closed
        hoverIntent.reset(isOpen: false, pointerInside: false)
        updateVisibility()
        Log.notch.debug("Notch view model stopped")
    }

    // MARK: - Open / close (frozen)

    /// Expands the notch. `focus: true` also makes the panel key (hotkey, menu, click inside).
    func open(tab: NotchTab? = nil, focus: Bool = false) {
        guard geometry != nil else {
            Log.notch.info("open() ignored: no built-in notch display")
            return
        }
        if let tab { selectedTab = tab }
        if focus { openedExplicitly = true }
        let target = NotchPresentation.expanded(selectedTab)
        expand(to: target, pointerInside: isPointerInside(target))
        if focus {
            host?.notchRequestsKeyFocus()
        }
    }

    /// Collapses the notch. A peek on screen is dismissed (the next queued popup, if any, may follow).
    func close() {
        switch presentation {
        case .closed:
            return
        case .peek:
            apply(popupQueue.dismissCurrent(context: popupContext(), now: Date()))
            syncQueuedPopups()
        case .expanded:
            collapseExpanded()
        }
    }

    /// Hotkey / menu: expanded ⇄ closed. Opening this way focuses the panel.
    func toggle() {
        if presentation.isExpanded {
            close()
        } else {
            open(tab: nil, focus: true)
        }
    }

    /// Switches the expanded tab (header buttons). Remembered for the next open.
    func selectTab(_ tab: NotchTab) {
        selectedTab = tab
        if presentation.isExpanded {
            setPresentation(.expanded(tab), pointerInside: true)
        }
    }

    // MARK: - Popups (frozen)

    /// Runs `PopupPolicy`: show now, queue, or suppress. Same `id` replaces (shown or queued).
    func present(_ request: PopupRequest) {
        let effect = popupQueue.present(request, context: popupContext(), now: Date())
        apply(effect)
        syncQueuedPopups()
    }

    /// Removes a shown or queued popup (answered, withdrawn, state changed).
    func withdraw(popupID: String) {
        let effect = popupQueue.withdraw(id: popupID, context: popupContext(), now: Date())
        apply(effect)
        syncQueuedPopups()
    }

    /// Shows a queued popup right away, even over the expanded notch (e.g. the user clicked a 🔴 row whose
    /// permission card is waiting). Returns false if no such popup is pending.
    @discardableResult
    func showQueuedPopup(id: String) -> Bool {
        if currentPopup?.id == id { return true }
        guard let request = queuedPopups.first(where: { $0.id == id }) else { return false }
        var collapsedContext = popupContext()
        collapsedContext.isExpanded = false
        guard PopupPolicy.decide(request, context: collapsedContext) == .show else { return false }
        if presentation.isExpanded {
            setPresentation(.closed, pointerInside: false)
        }
        // Whatever is on screen steps back (a 🔴 re-queues); then this one is presented with the notch collapsed.
        popupQueue.requeueCurrent()
        _ = popupQueue.withdraw(id: id, context: popupContext(), now: Date())
        apply(popupQueue.present(request, context: popupContext(), now: Date()))
        syncQueuedPopups()
        return currentPopup?.id == id
    }

    /// "2 of 3" for a popup among the popups of the same kind (shown + queued), for the permission card.
    func popupPosition(of id: String) -> NotchPopupPosition? {
        popupQueue.position(of: id)
    }

    // MARK: - Hold open (frozen)

    /// The notch stays open while any token is held (drag inside, AirDrop share, text entry, a permission card
    /// being read, QuickLook). `token.release()`; also released on deinit.
    func holdOpen(reason: String) -> NotchHoldToken {
        nextHoldID += 1
        let id = nextHoldID
        holds[id] = reason
        Log.notch.debug("Hold +\(reason, privacy: .public) (\(self.holds.count, privacy: .public) held)")
        return NotchHoldToken(reason: reason) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.releaseHold(id: id) }
            } else {
                Task { @MainActor in self?.releaseHold(id: id) }
            }
        }
    }

    var isHeldOpen: Bool { !holds.isEmpty }

    // MARK: - Settings (frozen)

    func openSettings() {
        guard let handler = openSettingsHandler else {
            Log.notch.error("openSettings() called before AppDelegate installed its handler")
            return
        }
        handler()
        if presentation.isExpanded { close() }
    }

    /// Suspends the global hotkeys while a shortcut recorder listens (Settings › Shortcuts).
    func setHotkeysSuspended(_ suspended: Bool) {
        host?.notchSetHotkeysSuspended(suspended)
    }

    // MARK: - Inputs from NotchContainerView

    func updateClosedWings(_ wings: NotchClosedWings) {
        guard wings != closedWings else { return }
        closedWings = wings
        host?.notchStateDidChange()
        if isPanelVisible { handlePointerMoved(to: NSEvent.mouseLocation) }
    }

    /// A file drag approaches the notch (ShelfModel.isDragActive): open the Shelf tab and hold it open.
    func setFileDragActive(_ active: Bool) {
        guard active != isFileDragActive else { return }
        isFileDragActive = active
        if active {
            guard geometry != nil, settings.settings.shelfEnabled else { return }
            dragHold = holdOpen(reason: "shelf.drag")
            if presentation.isClosed { performHaptic() }
            selectedTab = .shelf
            // Armed: once the drag ends (hold released) and the pointer is away, the notch closes by itself.
            expand(to: .expanded(.shelf), pointerInside: true)
            updateVisibility()
        } else {
            dragHold?.release()
            dragHold = nil
            updateVisibility()
        }
        host?.notchStateDidChange()
    }

    // MARK: - Inputs from NotchWindowController

    func updateGeometry(_ newGeometry: NotchGeometry?) {
        guard newGeometry != geometry else { return }
        geometry = newGeometry
        if newGeometry == nil {
            Log.notch.info("No notch display: hiding")
            hoverTimer.cancel()
            if !presentation.isClosed { setPresentation(.closed, pointerInside: false) }
        } else {
            Log.notch.info("Notch display ready")
        }
        reevaluatePopups()
        updateVisibility()
        host?.notchStateDidChange()
    }

    func updateFullscreen(_ active: Bool) {
        guard active != isFullscreenActive else { return }
        isFullscreenActive = active
        Log.notch.debug("Fullscreen \(active ? "on" : "off", privacy: .public)")
        if isHiddenByFullscreen, presentation.isExpanded, !openedExplicitly, !isFileDragActive {
            collapseExpanded()
        }
        reevaluatePopups()
        updateVisibility()
        host?.notchStateDidChange()
    }

    /// Frontmost app changed: focus-aware 🟢 popups may no longer be wanted.
    func frontmostApplicationDidChange() {
        reevaluatePopups()
    }

    func panelKeyStatusChanged(_ isKey: Bool) {
        guard isKey != isKeyFocused else { return }
        isKeyFocused = isKey
    }

    func updateHotkeyConflicts(_ conflicts: Set<HotkeyAction>) {
        guard conflicts != hotkeyConflicts else { return }
        hotkeyConflicts = conflicts
    }

    /// Screen rect that accepts clicks: the current shape. nil while hidden.
    var hitRegion: CGRect? {
        guard isPanelVisible, let geometry else { return nil }
        return geometry.shapeRectInScreen(for: presentation, wings: closedWings)
    }

    /// Whether the panel should currently receive mouse events at this screen point (the rest of the panel
    /// is click-through, `ignoresMouseEvents`).
    func acceptsMouse(at point: CGPoint) -> Bool {
        if isFileDragActive && isOpen { return true }
        guard let region = hitRegion else { return false }
        return region.contains(point)
    }

    /// Global/local mouse-moved monitor. Only rect checks; no allocation (SPEC §F.1).
    func handlePointerMoved(to point: CGPoint) {
        guard isPanelVisible, let geometry else {
            setHovering(false)
            return
        }
        let shapeRect = geometry.shapeRectInScreen(for: presentation, wings: closedWings)
        let inOpenRegion = !presentation.isClosed && geometry.leaveRect(for: shapeRect).contains(point)
        let triggerRect = geometry.triggerRect(wings: presentation.isClosed ? closedWings : .none)
        let inTriggerArea = triggerRect.contains(point)
        setHovering(presentation.isClosed ? inTriggerArea : inOpenRegion)

        if case .peek = presentation {
            popupQueue.setAutoDismissPaused(inOpenRegion, now: Date())
            schedulePopupDeadline()
        }
        // Only the closed notch opens by dwell; a peek never turns into the expanded notch by hover.
        let canHoverOpen =
            presentation.isClosed && settings.settings.openOnHover && !isHiddenByFullscreen
        let inTrigger = canHoverOpen ? inTriggerArea : (presentation.isClosed ? false : inTriggerArea)
        perform(hoverIntent.mouseMoved(inTrigger: inTrigger, inOpenRegion: inOpenRegion, now: Date()))
    }

    /// Global mouse-down monitor (another app's window) or a click in one of our other windows.
    func handleMouseDownOutsidePanel(at point: CGPoint) {
        guard isOpen, let geometry else { return }
        let shapeRect = geometry.shapeRectInScreen(for: presentation, wings: closedWings)
        guard !shapeRect.contains(point) else { return }
        guard holds.isEmpty else {
            Log.notch.debug("Click outside ignored: notch is held open")
            return
        }
        switch presentation {
        case .closed:
            return
        case .expanded:
            collapseExpanded()
        case .peek(let request):
            // SPEC §A.4/§A.6: 🔴 cards stay until answered; only a 🟢 notice goes away on a click elsewhere.
            if request.priority == .info {
                apply(popupQueue.dismissCurrent(context: popupContext(), now: Date()))
                syncQueuedPopups()
            }
        }
    }

    // MARK: - Private: presentation

    private func setPresentation(_ new: NotchPresentation, pointerInside: Bool) {
        let old = presentation
        guard new != old else { return }
        presentation = new
        hoverTimer.cancel()
        hoverIntent.reset(isOpen: !new.isClosed, pointerInside: pointerInside)
        if new.isClosed {
            openedExplicitly = false
        }
        // Keyboard focus never survives a collapse or a new popup: someone typing elsewhere must never answer
        // a permission card by accident (SPEC §A.4). Expanding keeps focus only if it was explicit.
        let focusMayStay: Bool
        switch (old, new) {
        case (.expanded, .expanded): focusMayStay = true
        case (.peek(let a), .peek(let b)): focusMayStay = a.id == b.id
        case (.peek, .expanded): focusMayStay = true
        default: focusMayStay = false
        }
        if isKeyFocused && !focusMayStay {
            host?.notchRelinquishesKeyFocus()
        }
        updateVisibility()
        host?.notchStateDidChange()
        Log.notch.debug("Presentation → \(Self.describe(new), privacy: .public)")
    }

    /// Expands (or switches tab). A peek on screen steps back: a 🔴 returns to the queue and comes back when
    /// the notch collapses; a 🟢 counts as seen.
    private func expand(to target: NotchPresentation, pointerInside: Bool) {
        if presentation.peekRequest != nil {
            popupQueue.requeueCurrent()
            syncQueuedPopups()
            schedulePopupDeadline()
        }
        setPresentation(target, pointerInside: pointerInside)
    }

    private func collapseExpanded() {
        setPresentation(.closed, pointerInside: isPointerInside(.closed))
        // Popups that queued while the user looked at the expanded notch come up now.
        reevaluatePopups()
    }

    private func isPointerInside(_ presentation: NotchPresentation) -> Bool {
        guard let geometry else { return false }
        let point = NSEvent.mouseLocation
        if presentation.isClosed {
            return geometry.triggerRect(wings: closedWings).contains(point)
        }
        let rect = geometry.shapeRectInScreen(for: presentation, wings: closedWings)
        return geometry.leaveRect(for: rect).contains(point)
    }

    private func updateVisibility() {
        let visible: Bool
        if geometry == nil || !isStarted {
            visible = false
        } else if !isHiddenByFullscreen {
            visible = true
        } else {
            switch presentation {
            case .closed: visible = false
            case .peek(let request): visible = request.priority == .critical
            case .expanded: visible = openedExplicitly || isFileDragActive
            }
        }
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        if !visible {
            hoverTimer.cancel()
            hoverIntent.reset(isOpen: !presentation.isClosed, pointerInside: false)
            setHovering(false)
        }
    }

    private func setHovering(_ hovering: Bool) {
        if hovering != isHovering { isHovering = hovering }
    }

    // MARK: - Private: hover

    private func perform(_ action: HoverIntent.Action) {
        switch action {
        case .none:
            break
        case .schedule(let date):
            hoverTimer.schedule(at: date) { [weak self] in
                self?.hoverDeadlineReached()
            }
        case .open:
            hoverTimer.cancel()
            openFromHover()
        case .close:
            hoverTimer.cancel()
            closeFromHover()
        }
    }

    private func hoverDeadlineReached() {
        perform(hoverIntent.timerFired(now: Date()))
    }

    private func openFromHover() {
        guard presentation.isClosed, geometry != nil, isPanelVisible, !isHiddenByFullscreen else { return }
        performHaptic()
        setPresentation(.expanded(selectedTab), pointerInside: true)
    }

    private func closeFromHover() {
        guard holds.isEmpty else {
            Log.notch.debug("Hover close ignored: notch is held open")
            return
        }
        switch presentation {
        case .closed:
            return
        case .expanded:
            collapseExpanded()
        case .peek(let request):
            // A permission card stays until answered/withdrawn/expired; other peeks go once the user hovered
            // them and left (SPEC §A.6).
            if case .claudePermission = request.payload { return }
            apply(popupQueue.dismissCurrent(context: popupContext(), now: Date()))
            syncQueuedPopups()
        }
    }

    private func applyHoverDelays(_ value: AppSettings) {
        hoverIntent.openDelay = max(value.hoverOpenDelay, 0)
        hoverIntent.closeDelay = max(value.hoverCloseDelay, 0)
    }

    private func performHaptic() {
        guard settings.settings.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: - Private: holds

    private func releaseHold(id: Int) {
        guard let reason = holds.removeValue(forKey: id) else { return }
        Log.notch.debug("Hold -\(reason, privacy: .public) (\(self.holds.count, privacy: .public) held)")
        guard holds.isEmpty else { return }
        // Re-check where the pointer is: if it left while held, the close grace starts now.
        if isPanelVisible {
            handlePointerMoved(to: NSEvent.mouseLocation)
        }
    }

    // MARK: - Private: popups

    private func popupContext() -> PopupContext {
        PopupContext(
            settings: settings.settings, isFullscreen: isFullscreenActive, isExpanded: presentation.isExpanded,
            isNotchAvailable: geometry != nil && isStarted,
            frontmostAppBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func apply(_ effect: NotchPopupQueue.Effect) {
        switch effect {
        case .none:
            break
        case .show(let request):
            guard !presentation.isExpanded else {
                // Defensive: the policy queues while expanded, so this should not happen.
                popupQueue.requeueCurrent()
                break
            }
            let target = NotchPresentation.peek(request)
            let samePopup = presentation.peekRequest?.id == request.id
            // An updated popup keeps its hover state; a new one closes by hover only after being visited.
            let pointerInside = samePopup ? hoverIntent.isArmedForClose : isPointerInside(target)
            setPresentation(target, pointerInside: pointerInside)
            if !samePopup {
                Log.notch.info("Popup shown (\(request.priority == .critical ? "critical" : "info", privacy: .public))")
            }
        case .hide:
            if presentation.peekRequest != nil {
                setPresentation(.closed, pointerInside: isPointerInside(.closed))
            }
        }
        schedulePopupDeadline()
    }

    private func reevaluatePopups() {
        apply(popupQueue.reevaluate(context: popupContext(), now: Date()))
        syncQueuedPopups()
    }

    private func schedulePopupDeadline() {
        guard let deadline = popupQueue.nextDeadline() else {
            popupTimer.cancel()
            return
        }
        popupTimer.schedule(at: deadline) { [weak self] in
            self?.popupDeadlineReached()
        }
    }

    private func popupDeadlineReached() {
        apply(popupQueue.tick(context: popupContext(), now: Date()))
        syncQueuedPopups()
    }

    private func syncQueuedPopups() {
        let queued = popupQueue.queuedInOrder
        if queued != queuedPopups { queuedPopups = queued }
    }

    // MARK: - Private: settings

    private func settingsDidChange(old: AppSettings, new: AppSettings) {
        if old.hoverOpenDelay != new.hoverOpenDelay || old.hoverCloseDelay != new.hoverCloseDelay {
            applyHoverDelays(new)
        }
        let popupRulesChanged =
            old.popupOnNeedsInput != new.popupOnNeedsInput || old.popupOnDone != new.popupOnDone
            || old.skipDoneWhenHostFrontmost != new.skipDoneWhenHostFrontmost
            || old.hideInFullscreen != new.hideInFullscreen || old.claudeEnabled != new.claudeEnabled
        if popupRulesChanged {
            reevaluatePopups()
        }
        if old.hideInFullscreen != new.hideInFullscreen || old.openOnHover != new.openOnHover {
            updateVisibility()
            host?.notchStateDidChange()
        }
        if old.shelfEnabled != new.shelfEnabled, !new.shelfEnabled, case .expanded(.shelf) = presentation,
            !new.clipboardEnabled
        {
            selectTab(.home)
        }
    }

    private static func describe(_ presentation: NotchPresentation) -> String {
        switch presentation {
        case .closed: return "closed"
        case .peek(let request): return request.priority == .critical ? "peek (critical)" : "peek (info)"
        case .expanded(let tab): return "expanded (\(tab.rawValue))"
        }
    }
}

// MARK: - Deadline timer

/// A single pending deadline on the main actor (no repeating timer; nothing runs while idle).
final class NotchDeadlineTimer {
    private var task: Task<Void, Never>?
    private(set) var deadline: Date?

    init() {}

    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) {
        if let deadline, deadline == date, task != nil { return }
        task?.cancel()
        deadline = date
        let delay = max(date.timeIntervalSinceNow, 0)
        task = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.task = nil
            self?.deadline = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        deadline = nil
    }
}
