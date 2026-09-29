// Owner: notch-shell (SPEC §A.4, §F.1).
//
// Global + local NSEvent monitors for pointer movement and clicks. Global monitors see events that go to
// other apps; local monitors see events that go to our own windows (the panel once it is key, Settings).
// Handlers run on the main thread and only forward a point: no allocation per event (SPEC §F.1).
// Mouse monitors need no Accessibility permission. Installed only while the notch is on screen.
import AppKit

final class NotchMouseMonitor {
    /// Pointer moved (screen coordinates).
    var onMove: ((CGPoint) -> Void)?
    /// A mouse button went down somewhere. `inPanel` is true for clicks delivered to the notch panel itself.
    var onMouseDown: ((CGPoint, _ inPanel: Bool) -> Void)?
    /// The panel whose clicks count as "inside".
    weak var panel: NSWindow?

    private var globalMove: Any?
    private var localMove: Any?
    private var globalDown: Any?
    private var localDown: Any?

    init() {}

    var isTrackingMovement: Bool { globalMove != nil }
    var isTrackingClicks: Bool { globalDown != nil }

    func setTracking(movement: Bool, clicks: Bool) {
        if movement != isTrackingMovement {
            movement ? startMovement() : stopMovement()
        }
        if clicks != isTrackingClicks {
            clicks ? startClicks() : stopClicks()
        }
    }

    func stop() {
        stopMovement()
        stopClicks()
    }

    // MARK: Movement

    private func startMovement() {
        // Only plain moves: drags (window moves, text selection) must not open the notch. File drags are
        // detected by the shelf (ShelfModel.isDragActive) and handled separately.
        let mask: NSEvent.EventTypeMask = [.mouseMoved]
        globalMove = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onMove?(NSEvent.mouseLocation)
            }
        }
        localMove = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.onMove?(NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func stopMovement() {
        if let globalMove { NSEvent.removeMonitor(globalMove) }
        if let localMove { NSEvent.removeMonitor(localMove) }
        globalMove = nil
        localMove = nil
    }

    // MARK: Clicks

    private func startClicks() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalDown = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onMouseDown?(NSEvent.mouseLocation, false)
            }
        }
        localDown = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let window = event.window
            MainActor.assumeIsolated {
                guard let self else { return }
                let inPanel = window != nil && window === self.panel
                self.onMouseDown?(NSEvent.mouseLocation, inPanel)
            }
            return event
        }
    }

    private func stopClicks() {
        if let globalDown { NSEvent.removeMonitor(globalDown) }
        if let localDown { NSEvent.removeMonitor(localDown) }
        globalDown = nil
        localDown = nil
    }
}
