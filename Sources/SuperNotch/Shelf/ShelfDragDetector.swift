// Owner: shelf-clipboard (SPEC §A.5, spec-critique K4/E6). Detects a FILE drag approaching the notch while
// another app is the drag source, so the shelf can open its drop zones before the cursor arrives. Text, links and
// image data count only when dragged onto the notch itself or over the Shelf tab that is already open
// (`ShelfDragGeometry.isNearForContent`), so browser-tab and text drags passing by never open it.
//
// Energy (SPEC §F.1, critique E6):
// * Only two global monitors: `.leftMouseDragged` and `.leftMouseUp`. Nothing runs while the mouse is idle.
// * Every dragged event does a rect check only (no allocation, no IPC) until the pointer is within
//   `probeMargin` of the notch. Only then is `NSPasteboard(name: .drag)` consulted (an IPC call): at most every
//   `probeInterval` and at most `maxProbesPerGesture` times per gesture.
// * A drag counts only if the drag pasteboard changed since the previous drag gesture ended (so window drags
//   and text selections never count, and the stale contents of an earlier drag are never mistaken for a new
//   one) and its types are file URLs or file promises, or droppable content (`ShelfDragTypes`). The baseline
//   change count is read once at the end of every gesture that actually dragged (never on plain clicks).
// * The watchdog timer exists only while drop mode is on.
// Global mouse monitors need no Accessibility permission (they cannot see key events).
import AppKit
import SuperNotchCore

final class ShelfDragDetector {
    /// Called with `true` when a file drag comes near the notch and `false` when it leaves or ends.
    var onNearChange: ((Bool) -> Void)?
    /// Physical notch rect and the expanded shape rect (screen coordinates); nil ⇒ no notch display.
    var geometryProvider: (() -> (notch: CGRect, open: CGRect?)?)?
    /// Whether the Shelf tab is already expanded on screen (then text/link drags over it count too).
    var isShelfOpenProvider: (() -> Bool)?
    /// Whether text/link drags may open the shelf at all (not while a fullscreen app hides the notch).
    var allowsContentDrags: (() -> Bool)?

    private enum Gesture {
        case idle
        /// Pointer is near the notch but the drag pasteboard has not (yet) shown a new file drag.
        case probing(count: Int, lastProbe: TimeInterval)
        case fileDrag
        /// Text, a link or image data (no files): see `ShelfDragGeometry.isNearForContent`.
        case contentDrag
        case ignored
    }

    /// Only look at the drag pasteboard once the pointer is this close to the notch.
    private static let probeMargin: CGFloat = 150
    private static let probeInterval: TimeInterval = 0.08
    private static let maxProbesPerGesture = 6
    /// Debounce: the pointer must stay near this long before drop mode turns on …
    private static let enterDelay: TimeInterval = 0.06
    /// Longer dwell for text/link drags: a tab dragged across the menu bar must not flash the shelf open.
    private static let contentEnterDelay: TimeInterval = 0.25
    /// … and away this long before it turns off.
    private static let exitDelay: TimeInterval = 0.15

    private let dragPasteboard = NSPasteboard(name: .drag)
    private let promiseTypes: [String] = NSFilePromiseReceiver.readableDraggedTypes
    private var monitors: [Any] = []
    private var gesture: Gesture = .idle
    /// Drag pasteboard change count when the previous drag gesture ended (a new drag session bumps it).
    private var evaluatedChangeCount = 0
    /// The current gesture produced `leftMouseDragged` events (plain clicks never refresh the baseline).
    private var sawDragEvents = false
    private(set) var isNear = false
    private var nearCandidateSince: TimeInterval?
    private var farCandidateSince: TimeInterval?
    private var watchdog: Timer?
    /// One-shot re-check when the pointer stops inside the zone before the enter delay passed (a parked
    /// pointer produces no more dragged events).
    private var enterCheck: Timer?

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        evaluatedChangeCount = dragPasteboard.changeCount
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseDragged,
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDragged() }
            })
        {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseUp,
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.gestureEnded() }
            })
        {
            monitors.append(monitor)
        }
        Log.shelf.debug("Drag detector started")
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        gestureEnded()
        Log.shelf.debug("Drag detector stopped")
    }

    /// The drop landed on (or was cancelled over) our own window: the gesture is over.
    func dropFinished() {
        gestureEnded()
    }

    // MARK: Event handling

    private func mouseDragged() {
        sawDragEvents = true
        switch gesture {
        case .ignored:
            return
        case .fileDrag, .contentDrag:
            updateNearState()
        case .idle, .probing:
            probeIfClose()
        }
    }

    private func probeIfClose() {
        guard let geometry = geometryProvider?() else { return }
        let point = NSEvent.mouseLocation
        var probeRect = geometry.notch.insetBy(dx: -Self.probeMargin, dy: -Self.probeMargin)
        if let open = geometry.open { probeRect = probeRect.union(open) }
        guard probeRect.contains(point) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        var probes = 0
        if case .probing(let count, let lastProbe) = gesture {
            guard now - lastProbe >= Self.probeInterval else { return }
            probes = count
        }
        guard probes < Self.maxProbesPerGesture else {
            gesture = .ignored
            return
        }
        let changeCount = dragPasteboard.changeCount
        guard changeCount != evaluatedChangeCount else {
            // No new drag session (yet): a window drag, a selection, or the session starts in a moment.
            gesture = .probing(count: probes + 1, lastProbe: now)
            return
        }
        let types = (dragPasteboard.types ?? []).map(\.rawValue)
        if ShelfDragTypes.isFileDrag(types: types, extraPromiseTypes: promiseTypes) {
            gesture = .fileDrag
            Log.shelf.debug("File drag detected near the notch")
            updateNearState()
        } else if ShelfDragTypes.isContentDrag(types: types), allowsContentDrags?() ?? true {
            gesture = .contentDrag
            updateNearState()
        } else {
            gesture = .ignored
        }
    }

    private func updateNearState() {
        guard let geometry = geometryProvider?() else {
            setNear(false)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let point = NSEvent.mouseLocation
        let near: Bool
        let enterDelay: TimeInterval
        if case .contentDrag = gesture {
            near = ShelfDragGeometry.isNearForContent(
                point: point, notchRect: geometry.notch, openRect: geometry.open, isActive: isNear,
                isShelfOpen: isShelfOpenProvider?() ?? false)
            enterDelay = Self.contentEnterDelay
        } else {
            near = ShelfDragGeometry.isNear(
                point: point, notchRect: geometry.notch, openRect: geometry.open, isActive: isNear)
            enterDelay = Self.enterDelay
        }
        if near {
            farCandidateSince = nil
            guard !isNear else { return }
            let since = nearCandidateSince ?? now
            nearCandidateSince = since
            if now - since >= enterDelay {
                setNear(true)
            } else {
                scheduleEnterCheck(after: enterDelay - (now - since))
            }
        } else {
            nearCandidateSince = nil
            guard isNear else { return }
            let since = farCandidateSince ?? now
            farCandidateSince = since
            if now - since >= Self.exitDelay { setNear(false) }
        }
    }

    private func gestureEnded() {
        if sawDragEvents {
            // Baseline for the next gesture: whatever this gesture put on the drag pasteboard is now old.
            evaluatedChangeCount = dragPasteboard.changeCount
            sawDragEvents = false
        }
        gesture = .idle
        nearCandidateSince = nil
        farCandidateSince = nil
        enterCheck?.invalidate()
        enterCheck = nil
        setNear(false)
    }

    private func scheduleEnterCheck(after delay: TimeInterval) {
        guard enterCheck == nil else { return }
        let timer = Timer(timeInterval: max(delay, 0) + 0.02, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterCheckFired() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        enterCheck = timer
    }

    private func enterCheckFired() {
        enterCheck = nil
        switch gesture {
        case .fileDrag, .contentDrag:
            if NSEvent.pressedMouseButtons & 1 == 0 {
                gestureEnded()
            } else {
                updateNearState()
            }
        case .idle, .probing, .ignored:
            break
        }
    }

    private func setNear(_ near: Bool) {
        guard near != isNear else { return }
        isNear = near
        if near { startWatchdog() } else { stopWatchdog() }
        onNearChange?(near)
    }

    // MARK: Watchdog (only while drop mode is on)

    /// A missed mouse-up (e.g. swallowed by a drop on our own window) must never leave drop mode stuck.
    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogFired() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func watchdogFired() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            gestureEnded()
        } else {
            switch gesture {
            case .fileDrag, .contentDrag:
                // The pointer may be parked without dragged events; re-check (also applies the exit debounce).
                updateNearState()
            case .idle, .probing, .ignored:
                break
            }
        }
    }
}
