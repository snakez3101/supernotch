// Owner: shelf-clipboard (SPEC §A.4, spec-critique U5). The ⌥⌘V clipboard history panel.
//
// A separate borderless, NON-ACTIVATING `NSPanel` that becomes key (so the search field gets typing) without
// activating SuperNotch: the app the user was typing in stays frontmost, so after Return we just order the
// panel out and post ⌘V. Never calls `NSApp.activate`. Placed centred under the notch (or at the top of the
// screen with the pointer when there is no notch display).
// Keys (local monitor, only while the panel is key): ↑/↓ move, Return pastes, ⌘Return copies, Esc clears the
// search or closes, ⌘⌫ deletes, ⌘P pins, ⌘1…⌘9 paste the n-th row, ⌘W closes.
import AppKit
import SuperNotchCore
import SwiftUI

final class ClipboardHistoryNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ClipboardHistoryPanelController {
    static let panelSize = CGSize(width: 380, height: 420)

    private weak var model: ClipboardModel?
    private let notch: NotchViewModel
    private var panel: ClipboardHistoryNSPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(model: ClipboardModel, notch: NotchViewModel) {
        self.model = model
        self.notch = notch
    }

    func show() {
        guard let model else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fresh SwiftUI tree per presentation: the search field is focused again and the list starts at the top.
        let hosting = NSHostingView(rootView: ClipboardHistoryView().environment(model))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hosting
        panel.setFrame(frameForPanel(), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
        observeResignKey(of: panel)
        Log.clipboard.debug("History panel shown")
    }

    func hide() {
        removeKeyMonitor()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let panel else { return }
        panel.orderOut(nil)
        // Drop the SwiftUI tree while hidden (no work, no memory for thumbnails).
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
    }

    // MARK: Window

    private func makePanel() -> ClipboardHistoryNSPanel {
        let panel = ClipboardHistoryNSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "Clipboard History"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        return panel
    }

    /// Centred under the physical notch; otherwise at the top of the screen that has the pointer.
    private func frameForPanel() -> NSRect {
        let size = Self.panelSize
        if let geometry = notch.geometry {
            let screen = geometry.screenFrame
            let x = min(max(geometry.notchRect.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
            let y = geometry.notchRect.minY - 8 - size.height
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        return NSRect(
            x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8, width: size.width,
            height: size.height)
    }

    private func observeResignKey(of panel: NSPanel) {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResignedKey() }
        }
    }

    private func panelResignedKey() {
        // Clicked elsewhere (or another window took focus): close like a menu.
        guard let model, model.isHistoryPanelVisible else { return }
        model.hideHistoryPanel()
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKey(event) }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, let model else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 125:  // ↓
            model.movePanelSelection(by: 1)
            return true
        case 126:  // ↑
            model.movePanelSelection(by: -1)
            return true
        case 36, 76:  // Return, Enter
            if flags.contains(.command) { model.copySelection() } else { model.pasteSelection() }
            return true
        case 53:  // Esc
            if !model.searchQuery.isEmpty { model.searchQuery = "" } else { model.hideHistoryPanel() }
            return true
        case 51 where flags == .command:  // ⌘⌫
            model.deleteSelection()
            return true
        default:
            break
        }
        guard flags == .command, let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        switch characters {
        case "p":
            model.togglePinSelection()
            return true
        case "w":
            model.hideHistoryPanel()
            return true
        default:
            if let digit = Int(characters), (1...9).contains(digit) {
                model.pasteVisibleEntry(at: digit - 1)
                return true
            }
            return false
        }
    }
}
