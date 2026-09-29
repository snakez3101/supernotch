// Owner: shelf-clipboard (SPEC §A.4, §A.5). AirDrop and the generic Share menu for shelf items.
//
// The notch is a non-activating panel, so we never call NSApp.activate. While a share UI is up the notch is
// held open (`NotchViewModel.holdOpen`), otherwise the "click outside closes" rule would tear it down.
// AirDrop's didShare/didFail callbacks are unreliable, so a watchdog releases the hold once no extra window of
// ours is visible any more (or after 2 s if the share UI never appeared in-process), capped at 5 minutes.
import AppKit
import SuperNotchCore

final class ShelfSharingCoordinator: NSObject, NSSharingServiceDelegate, NSSharingServicePickerDelegate {
    private let notch: NotchViewModel
    private var hold: NotchHoldToken?
    private var watchdog: Timer?
    private var startedAt = Date.distantPast
    private var baselineWindows: Set<ObjectIdentifier> = []
    private var sawShareWindow = false
    /// Keeps the service alive while it presents its UI (it only holds its delegate weakly).
    private var activeService: NSSharingService?
    private var activePicker: NSSharingServicePicker?

    init(notch: NotchViewModel) {
        self.notch = notch
        super.init()
    }

    /// Whether this Mac offers AirDrop at all (hardware + service present).
    static var isAirDropAvailable: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    /// The system AirDrop icon, if the service exists.
    static var airDropIcon: NSImage? {
        NSSharingService(named: .sendViaAirDrop)?.image
    }

    var isSharing: Bool { hold != nil }

    /// Opens the AirDrop picker for `items` (file URLs, web URLs). Returns false when AirDrop cannot send them.
    @discardableResult
    func airDrop(_ items: [Any]) -> Bool {
        guard !items.isEmpty else { return false }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            Log.shelf.error("AirDrop is not available on this Mac")
            return false
        }
        guard service.canPerform(withItems: items) else {
            Log.shelf.notice("AirDrop cannot send these \(items.count, privacy: .public) items")
            return false
        }
        begin(reason: "shelf.airdrop")
        service.delegate = self
        activeService = service
        service.perform(withItems: items)
        Log.shelf.info("AirDrop picker opened for \(items.count, privacy: .public) items")
        return true
    }

    /// Shows the standard Share menu anchored to `view`.
    func showSharePicker(items: [Any], relativeTo view: NSView) {
        guard !items.isEmpty, view.window != nil else { return }
        begin(reason: "shelf.share")
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        activePicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func cancel() {
        finish()
    }

    // MARK: Lifecycle

    private func begin(reason: String) {
        finish()
        hold = notch.holdOpen(reason: reason)
        startedAt = Date()
        sawShareWindow = false
        baselineWindows = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWatchdog() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func finish() {
        watchdog?.invalidate()
        watchdog = nil
        hold?.release()
        hold = nil
        activeService?.delegate = nil
        activeService = nil
        activePicker = nil
    }

    private func checkWatchdog() {
        let extraVisible = NSApp.windows.contains { window in
            window.isVisible && !baselineWindows.contains(ObjectIdentifier(window))
        }
        if extraVisible { sawShareWindow = true }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed > 300 || (!extraVisible && (sawShareWindow || elapsed > 2)) {
            finish()
        }
    }

    // MARK: NSSharingServiceDelegate (AppKit calls these on the main thread)

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated {
            Log.shelf.info("Share finished")
            self.finish()
        }
    }

    nonisolated func sharingService(
        _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error
    ) {
        let code = (error as NSError).code
        MainActor.assumeIsolated {
            Log.shelf.notice("Share ended without sending (code \(code, privacy: .public))")
            self.finish()
        }
    }

    // MARK: NSSharingServicePickerDelegate

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
    ) {
        let cancelled = service == nil
        MainActor.assumeIsolated {
            self.activePicker = nil
            // A chosen service keeps the hold until it reports back (or the watchdog decides it is gone).
            if cancelled { self.finish() }
        }
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        self
    }
}
