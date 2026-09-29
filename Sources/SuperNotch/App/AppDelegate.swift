// Owner: FOUNDATION (SPEC §A.10–§A.12, §D.10).
//
// Launch sequence, notch window, menu-bar item, Settings and onboarding windows, single instance.
// * The app is an accessory (LSUIElement) app at ALL times: no Dock icon and no ⌘-Tab entry, not even while the
//   Settings or onboarding window is open (the activation policy is never switched to `.regular`). Those windows
//   are brought forward by activating the app, which accessory apps may do; the hidden main menu still routes
//   ⌘C/⌘V/⌘A/⌘Z/⌘W, and `SettingsHostWindow` routes the editing shortcuts itself as a fallback.
// * Settings stays reachable without a Dock icon: menu-bar item (§A.12), the gear in the expanded notch
//   (⌥⌘N or hover), or launching SuperNotch again.
// * A second launch (Finder reopen or a second process) opens Settings (§A.12); a copy started by the
//   launch-at-login LaunchAgent (`--launched-at-login`) quits silently instead.
import AppKit
import SuperNotchCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    /// Posted by a second launch (distributed); the running instance opens Settings.
    static let showSettingsNotification = Notification.Name("io.github.snakez3101.supernotch.show-settings")
    /// SF Symbol of the menu-bar item (§A.12).
    static let statusItemSymbol = "rectangle.topthird.inset.filled"

    private var appModel: AppModel?
    private var notchWindowController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var settingsObservation: SettingsStore.ObserverToken?
    private var isObservingSecondLaunch = false
    /// The app that was frontmost before Settings/onboarding was brought forward; gets focus back when both close.
    private var previousFrontmostApp: NSRunningApplication?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstance() { return }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)  // never changed afterwards: no Dock icon, no ⌘-Tab entry
        application.mainMenu = makeMainMenu()
        NotchLoginItem.reconcileAtLaunch()

        let model = AppModel()
        appModel = model
        model.showSettingsHandler = { [weak self] in self?.showSettings() }
        model.showOnboardingHandler = { [weak self] in self?.showOnboarding() }
        model.notch.openSettingsHandler = { [weak self] in self?.showSettings() }
        settingsObservation = model.settings.observe { [weak self] old, new in
            self?.settingsDidChange(old: old, new: new)
        }

        model.start()

        let controller = NotchWindowController(appModel: model)
        notchWindowController = controller
        controller.start()

        updateStatusItem(visible: model.settings.settings.showMenuBarIcon)
        observeSecondLaunch()

        if !model.settings.settings.onboardingCompleted {
            Log.app.info("First launch: showing onboarding")
            presentOnboardingWindow()
        }
        Log.app.info("Launch complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("Terminating")
        if isObservingSecondLaunch {
            DistributedNotificationCenter.default().removeObserver(self)
            isObservingSecondLaunch = false
        }
        settingsObservation?.cancel()
        settingsObservation = nil
        notchWindowController?.stop()
        appModel?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Finder "open" while already running (the menu-bar icon may be hidden): show Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Single instance

    /// If an older SuperNotch with our bundle id is running, quit this process right away. A user launch also asks
    /// the running copy to open Settings; a copy started by the launch-at-login LaunchAgent quits silently.
    private func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }  // unbundled `swift run`
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
            .map { NotchInstanceGuard.Instance(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        guard !others.isEmpty else { return false }
        let current = NotchInstanceGuard.Instance(pid: ownPID, launchDate: NSRunningApplication.current.launchDate)
        guard NotchInstanceGuard.shouldYield(current: current, others: others) else {
            Log.app.info("Another SuperNotch started at the same time; this older copy keeps running")
            return false
        }
        if NotchLoginItem.wasLaunchedByLaunchAgent {
            Log.app.info("SuperNotch is already running; the copy started at login quits")
        } else {
            Log.app.info("SuperNotch is already running; asking it to open Settings")
            DistributedNotificationCenter.default().postNotificationName(
                Self.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
        NSApplication.shared.terminate(nil)
        return true
    }

    private func observeSecondLaunch() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(secondLaunchRequestedSettings(_:)), name: Self.showSettingsNotification,
            object: nil)
        isObservingSecondLaunch = true
    }

    @objc private func secondLaunchRequestedSettings(_ notification: Notification) {
        Log.app.info("Second launch detected: opening Settings")
        showSettings()
    }

    // MARK: - Settings changes

    private func settingsDidChange(old: AppSettings, new: AppSettings) {
        if old.showMenuBarIcon != new.showMenuBarIcon {
            updateStatusItem(visible: new.showMenuBarIcon)
        }
        if old.onboardingCompleted != new.onboardingCompleted {
            if new.onboardingCompleted {
                closeOnboardingWindow()
            } else {
                presentOnboardingWindow()
            }
        }
    }

    // MARK: - Menu-bar item (§A.12)

    private func updateStatusItem(visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: Self.statusItemSymbol, accessibilityDescription: "SuperNotch")
                if let image {
                    image.isTemplate = true
                    button.image = image
                } else {
                    button.title = "SN"
                }
                button.toolTip = "SuperNotch"
            }
            let menu = NSMenu(title: "SuperNotch")
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            statusItem = item
            populateStatusMenu(menu)
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Rebuilt every time the menu opens, so the hotkey hints follow the settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let statusMenu = statusItem?.menu, menu === statusMenu else { return }
        populateStatusMenu(menu)
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = appModel?.settings.settings ?? AppSettings()

        let openNotch = NSMenuItem(title: "Open Notch", action: #selector(openNotchFromMenu(_:)), keyEquivalent: "")
        openNotch.target = self
        openNotch.isEnabled = appModel?.notch.geometry != nil  // no built-in notch display (clamshell, external)
        Self.applyKeyEquivalent(settings.toggleNotchHotkey, to: openNotch)
        menu.addItem(openNotch)

        let clipboard = NSMenuItem(
            title: "Clipboard History", action: #selector(openClipboardFromMenu(_:)), keyEquivalent: "")
        clipboard.target = self
        clipboard.isEnabled = settings.clipboardEnabled
        Self.applyKeyEquivalent(settings.clipboardHotkey, to: clipboard)
        menu.addItem(clipboard)

        menu.addItem(NSMenuItem.separator())

        let preferences = NSMenuItem(
            title: "Settings…", action: #selector(showSettingsFromMenu(_:)), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit SuperNotch", action: #selector(quitFromMenu(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Shows a global hotkey as the menu item's key equivalent (display hint; the hotkey itself is Carbon).
    private static func applyKeyEquivalent(_ combo: KeyCombo?, to item: NSMenuItem) {
        guard let combo else { return }
        let name = KeyCombo.keyName(for: combo.keyCode)
        guard name.count == 1, let scalar = name.unicodeScalars.first, scalar.isASCII else { return }
        var flags: NSEvent.ModifierFlags = []
        if combo.hasControl { flags.insert(.control) }
        if combo.hasOption { flags.insert(.option) }
        if combo.hasShift { flags.insert(.shift) }
        if combo.hasCommand { flags.insert(.command) }
        item.keyEquivalent = name.lowercased()
        item.keyEquivalentModifierMask = flags
    }

    @objc private func openNotchFromMenu(_ sender: Any?) {
        appModel?.notch.open(tab: nil, focus: true)
    }

    @objc private func openClipboardFromMenu(_ sender: Any?) {
        appModel?.clipboard.showHistoryPanel()
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        showSettings()
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Settings window (§A.10)

    /// Opens or focuses the Settings window. Also the target of `NotchViewModel.openSettingsHandler`.
    func showSettings() {
        guard let model = appModel else { return }
        if let window = settingsWindow {
            bringToFront(window)
            return
        }
        Log.app.info("Opening Settings")
        let hosting = NSHostingController(rootView: AnyView(model.inject(SettingsView())))
        hosting.sizingOptions = [.minSize]
        let window = SettingsHostWindow(contentViewController: hosting)
        window.title = "SuperNotch Settings"
        // Not miniaturizable: a minimized window would sit in the Dock, and SuperNotch has no Dock presence.
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 520))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.center()
        _ = window.setFrameAutosaveName("SuperNotchSettingsWindow")
        settingsWindow = window
        bringToFront(window)
    }

    // MARK: - Onboarding window (§A.11)

    /// "Run setup again": shows the wizard even if it was completed before.
    func showOnboarding() {
        guard let store = appModel?.settings else { return }
        if store.settings.onboardingCompleted {
            store.settings.onboardingCompleted = false  // settingsDidChange presents the window
        } else {
            presentOnboardingWindow()
        }
    }

    private func presentOnboardingWindow() {
        guard let model = appModel else { return }
        if let window = onboardingWindow {
            bringToFront(window)
            return
        }
        let hosting = NSHostingController(rootView: AnyView(model.inject(OnboardingView())))
        hosting.sizingOptions = [.minSize]
        let window = SettingsHostWindow(contentViewController: hosting)
        window.title = "Welcome to SuperNotch"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 460))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.center()
        onboardingWindow = window
        bringToFront(window)
    }

    private func closeOnboardingWindow() {
        onboardingWindow?.close()  // windowWillClose clears the reference
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            // Released on close: no SwiftUI hierarchy keeps observing models while Settings is not visible.
            settingsWindow = nil
        } else if window === onboardingWindow {
            onboardingWindow = nil
            if let store = appModel?.settings, !store.settings.onboardingCompleted {
                Log.app.info("Onboarding closed early; marking setup as done (re-run from Settings › General)")
                store.settings.onboardingCompleted = true
            }
        }
        Task { @MainActor [weak self] in
            self?.returnFocusIfIdle()
        }
    }

    // MARK: - Window helpers

    /// Shows `window` in front and makes it key, WITHOUT a Dock icon: the app stays `.accessory` (accessory apps
    /// can be activated; they only have no Dock tile, menu bar or ⌘-Tab entry). `orderFrontRegardless` keeps the
    /// window visible even if the system declines the (cooperative) activation; a click then focuses it.
    private func bringToFront(_ window: NSWindow) {
        let application = NSApplication.shared
        if application.activationPolicy() != .accessory {
            application.setActivationPolicy(.accessory)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if !application.isActive, let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier != ownPID
        {
            previousFrontmostApp = frontmost
        }
        application.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// When Settings and onboarding are both closed, hand the focus back to the app the user came from, so the
    /// keyboard does not stay with a SuperNotch that shows no window.
    private func returnFocusIfIdle() {
        guard settingsWindow == nil, onboardingWindow == nil else { return }
        let previous = previousFrontmostApp
        previousFrontmostApp = nil
        guard NSApplication.shared.isActive, let previous, !previous.isTerminated else { return }
        _ = previous.activate(options: [])
    }

    // MARK: - Main menu (never shown: accessory app; its key equivalents work while Settings/onboarding is key)

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main")

        // No "Hide" items: ⌘H would also hide the notch panel, and there is no Dock icon to unhide it.
        let appMenu = NSMenu(title: "SuperNotch")
        let preferences = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettingsFromMenu(_:)), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit SuperNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "SuperNotch", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // No "Minimize": a minimized window would appear in the Dock.
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApplication.shared.windowsMenu = windowMenu

        return mainMenu
    }
}
