// Owner: notch-shell (SPEC §A.2, §A.4, §A.8, §A.9, §D.10).
//
// The AppKit side of the notch. Created and started by AppDelegate after `AppModel.start()`:
// * builds the NotchPanel hosting `appModel.inject(NotchContainerView())`;
// * keeps the panel on the built-in notch display (screen changes, wake, clamshell);
// * detects fullscreen apps on space/app changes (event-driven, no polling);
// * makes the panel click-through outside the current notch shape (`ignoresMouseEvents`, driven by the
//   pointer monitor) so browser tabs and toolbars under the transparent panel keep working;
// * registers the global hotkeys from settings and re-registers them when they change.
import AppKit
import SuperNotchCore
import SwiftUI
import os

final class NotchWindowController: NotchPanelHost {
    private let appModel: AppModel
    private var notch: NotchViewModel { appModel.notch }

    private var panel: NotchPanel?
    private let mouseMonitor = NotchMouseMonitor()
    private let hotkeys = HotkeyCenter()
    private var registeredHotkeys: [HotkeyAction: KeyCombo] = [:]
    private var hotkeysSuspended = false
    private var screen: NotchScreenInfo?
    private var notificationTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var settingsToken: SettingsStore.ObserverToken?
    private var screenFollowUp: Task<Void, Never>?
    private var fullscreenFollowUp: Task<Void, Never>?
    private var isRunning = false

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    // MARK: - Lifecycle (called by AppDelegate / SmokeTest)

    func start() {
        guard !isRunning else { return }
        isRunning = true
        notch.host = self
        makePanel()
        mouseMonitor.onMove = { [weak self] point in
            self?.pointerMoved(to: point)
        }
        mouseMonitor.onMouseDown = { [weak self] point, inPanel in
            self?.mouseDown(at: point, inPanel: inPanel)
        }
        observeSystem()
        settingsToken = appModel.settings.observe { [weak self] old, new in
            self?.settingsDidChange(old: old, new: new)
        }
        refreshScreen(reason: "start")
        registerHotkeys()
        Log.notch.info("Notch window controller started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        screenFollowUp?.cancel()
        screenFollowUp = nil
        fullscreenFollowUp?.cancel()
        fullscreenFollowUp = nil
        settingsToken?.cancel()
        settingsToken = nil
        removeObservers()
        mouseMonitor.stop()
        mouseMonitor.onMove = nil
        mouseMonitor.onMouseDown = nil
        hotkeys.unregisterAll()
        registeredHotkeys.removeAll()
        if notch.host === self { notch.host = nil }
        if let panel {
            panel.allowsKeyFocus = { false }
            panel.onKeyStatusChange = nil
            panel.onCancel = nil
            panel.orderOut(nil)
        }
        panel = nil
        Log.notch.info("Notch window controller stopped")
    }

    // MARK: - NotchPanelHost

    func notchStateDidChange() {
        guard isRunning, let panel else { return }
        if let geometry = notch.geometry, panel.frame != geometry.panelFrame {
            panel.setFrame(geometry.panelFrame, display: true)
        }
        let visible = notch.isPanelVisible
        if visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
        // Pointer tracking runs while the notch is on screen (hover-open, click-through); click tracking only
        // while it is open (click outside closes).
        mouseMonitor.setTracking(movement: visible, clicks: visible && notch.isOpen)
        updateMouseAcceptance(at: NSEvent.mouseLocation)
    }

    func notchRequestsKeyFocus() {
        guard isRunning, let panel, notch.allowsKeyFocus else { return }
        if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
        panel.makeKeyAndOrderFront(nil)
    }

    func notchRelinquishesKeyFocus() {
        guard let panel, panel.isKeyWindow else { return }
        // A non-activating panel cannot hand key status back directly; re-ordering it lets the window server
        // return focus to the active app's window without activating anything.
        panel.orderOut(nil)
        if notch.isPanelVisible {
            panel.orderFrontRegardless()
        }
        notch.panelKeyStatusChanged(false)
    }

    func notchSetHotkeysSuspended(_ suspended: Bool) {
        guard suspended != hotkeysSuspended else { return }
        hotkeysSuspended = suspended
        Log.system.debug("Global hotkeys \(suspended ? "suspended" : "resumed", privacy: .public)")
        registerHotkeys()
    }

    // MARK: - Panel

    private func makePanel() {
        let frame = notch.geometry?.panelFrame ?? CGRect(origin: .zero, size: NotchMetrics.panelSize)
        let panel = NotchPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let hostingView = NotchHostingView(rootView: appModel.inject(NotchContainerView()))
        // The window never follows SwiftUI's ideal size: the shape morphs inside a fixed panel.
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.hitRegion = { [weak self] in
            self?.notch.hitRegion
        }
        panel.contentView = hostingView
        panel.allowsKeyFocus = { [weak self] in
            self?.notch.allowsKeyFocus ?? false
        }
        panel.onKeyStatusChange = { [weak self] isKey in
            self?.notch.panelKeyStatusChanged(isKey)
        }
        panel.onCancel = { [weak self] in
            self?.notch.close()
        }
        panel.ignoresMouseEvents = true
        mouseMonitor.panel = panel
        self.panel = panel
    }

    private func pointerMoved(to point: CGPoint) {
        notch.handlePointerMoved(to: point)
        updateMouseAcceptance(at: point)
    }

    /// Click-through everywhere except the current notch shape (and the open shape during a file drag).
    private func updateMouseAcceptance(at point: CGPoint) {
        guard let panel else { return }
        let ignore = !notch.acceptsMouse(at: point)
        if panel.ignoresMouseEvents != ignore {
            panel.ignoresMouseEvents = ignore
        }
    }

    private func mouseDown(at point: CGPoint, inPanel: Bool) {
        guard !inPanel else { return }
        notch.handleMouseDownOutsidePanel(at: point)
    }

    // MARK: - Screens, wake, spaces, fullscreen

    private func observeSystem() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenParametersChanged() }
            })

        let workspace = NSWorkspace.shared.notificationCenter
        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in wakeNames {
            workspaceTokens.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.systemDidWake() }
                })
        }
        workspaceTokens.append(
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.activeSpaceDidChange() }
            })
        workspaceTokens.append(
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidActivate() }
            })
    }

    private func removeObservers() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        let workspace = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens {
            workspace.removeObserver(token)
        }
        workspaceTokens.removeAll()
    }

    private func screenParametersChanged() {
        refreshScreen(reason: "screen parameters")
        // Display reconfiguration (lid, arrangement, resolution) can report intermediate states: check again.
        scheduleScreenFollowUp(after: 0.6)
    }

    private func systemDidWake() {
        refreshScreen(reason: "wake")
        scheduleScreenFollowUp(after: 1.5)
    }

    private func activeSpaceDidChange() {
        refreshFullscreen()
        // The window list settles after the space-switch animation.
        scheduleFullscreenFollowUp(after: 0.7)
    }

    private func applicationDidActivate() {
        refreshFullscreen()
        notch.frontmostApplicationDidChange()
        scheduleFullscreenFollowUp(after: 0.4)
    }

    private func refreshScreen(reason: String) {
        guard isRunning else { return }
        let info = NotchScreenLocator.builtInNotchScreen()
        if info != screen {
            screen = info
            if let info {
                let size = "\(Int(info.geometry.notchSize.width))×\(Int(info.geometry.notchSize.height)) pt"
                Log.notch.info("Notch display (\(reason, privacy: .public)): \(size, privacy: .public)")
            } else {
                Log.notch.info("No built-in notch display (\(reason, privacy: .public)): notch hidden")
            }
        }
        notch.updateGeometry(info?.geometry)
        refreshFullscreen()
        notchStateDidChange()
    }

    private func refreshFullscreen() {
        guard isRunning else { return }
        guard let screen else {
            notch.updateFullscreen(false)
            return
        }
        let active = NotchFullscreenDetector.isFullscreen(
            on: screen.displayID, notchHeight: screen.geometry.notchSize.height)
        notch.updateFullscreen(active)
    }

    private func scheduleScreenFollowUp(after seconds: Double) {
        screenFollowUp?.cancel()
        screenFollowUp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshScreen(reason: "follow-up")
        }
    }

    private func scheduleFullscreenFollowUp(after seconds: Double) {
        fullscreenFollowUp?.cancel()
        fullscreenFollowUp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshFullscreen()
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        guard isRunning else { return }
        let settings = appModel.settings.settings
        var desired: [HotkeyAction: KeyCombo] = [:]
        if !hotkeysSuspended {
            if let combo = settings.toggleNotchHotkey {
                desired[.toggleNotch] = combo
            }
            if settings.clipboardEnabled, let combo = settings.clipboardHotkey {
                desired[.clipboardHistory] = combo
            }
        }
        var conflicts: Set<HotkeyAction> = []
        for action in HotkeyAction.allCases {
            guard let combo = desired[action] else {
                hotkeys.unregister(action)
                registeredHotkeys[action] = nil
                continue
            }
            if registeredHotkeys[action] == combo { continue }
            if hotkeys.register(combo, for: action, handler: hotkeyHandler(for: action)) {
                registeredHotkeys[action] = combo
            } else {
                registeredHotkeys[action] = nil
                conflicts.insert(action)
            }
        }
        notch.updateHotkeyConflicts(conflicts)
    }

    private func hotkeyHandler(for action: HotkeyAction) -> () -> Void {
        switch action {
        case .toggleNotch:
            return { [weak self] in
                self?.appModel.notch.toggle()
            }
        case .clipboardHistory:
            return { [weak self] in
                self?.appModel.clipboard.toggleHistoryPanel()
            }
        }
    }

    private func settingsDidChange(old: AppSettings, new: AppSettings) {
        if old.toggleNotchHotkey != new.toggleNotchHotkey || old.clipboardHotkey != new.clipboardHotkey
            || old.clipboardEnabled != new.clipboardEnabled
        {
            registerHotkeys()
        }
        if old.hideInFullscreen != new.hideInFullscreen {
            refreshFullscreen()
            notchStateDidChange()
        }
    }
}
