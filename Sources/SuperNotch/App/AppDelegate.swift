// Owner: FOUNDATION (SPEC §A.10–§A.12, §D.10).
//
// Launch sequence, notch window, menu-bar item, Settings and onboarding windows, single instance.
// * The app is an accessory (LSUIElement) app. While the Settings or onboarding window is open the activation
//   policy is `.regular` (Dock icon, main menu, ⌘C/⌘V in text fields); it returns to `.accessory` when both
//   are closed.
// * A second launch (Finder reopen or a second process) opens Settings (§A.12).
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

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstance() { return }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.mainMenu = makeMainMenu()

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

    /// If another SuperNotch with our bundle id is running, ask it to open Settings and quit this process.
    private func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }  // unbundled `swift run`
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
        guard !others.isEmpty else { return false }
        Log.app.info("SuperNotch is already running; asking it to open Settings")
        DistributedNotificationCenter.default().postNotificationName(
            Self.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
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
        let window = NSWindow(contentViewController: hosting)
        window.title = "SuperNotch Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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
        let window = NSWindow(contentViewController: hosting)
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
            self?.restoreAccessoryPolicyIfIdle()
        }
    }

    // MARK: - Window helpers

    private func bringToFront(_ window: NSWindow) {
        let application = NSApplication.shared
        if application.activationPolicy() != .regular {
            application.setActivationPolicy(.regular)
        }
        window.makeKeyAndOrderFront(nil)
        application.activate()
    }

    private func restoreAccessoryPolicyIfIdle() {
        guard settingsWindow == nil, onboardingWindow == nil else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    // MARK: - Main menu (only visible while a window is open)

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main")

        let appMenu = NSMenu(title: "SuperNotch")
        appMenu.addItem(
            withTitle: "About SuperNotch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let preferences = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettingsFromMenu(_:)), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide SuperNotch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
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

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApplication.shared.windowsMenu = windowMenu

        return mainMenu
    }
}
