// Owner: FOUNDATION (SPEC §G.2).
//
// `SuperNotch --smoke-test`, run by CI on the packaged app (`Scripts/package_app.sh --smoke-test`, 30 s limit).
// It proves that:
//   1. the Core contracts work inside the real binary,
//   2. the bundle is assembled correctly (hook helper, bundle id, LSUIElement), when run from a bundle,
//   3. settings persist (isolated UserDefaults suite: the user's real settings are never touched),
//   4. every frozen SwiftUI slot/view builds and lays out with all models injected,
//   5. the models and the notch window start and stop without crashing.
// Rules: headless (no window is shown on a Mac without a notch; views render off-screen), no dialogs
// (Spotify and clipboard capture are switched off in the isolated settings, so no Automation or pasteboard
// prompt), never touches ~/.claude (the Claude config folder and the hook socket point to a temp folder, and
// `SUPERNOTCH_SMOKE_TEST=1` tells claude-app to skip hook-binary sync and repair), finishes in a few seconds
// (watchdog: exit 3 after 25 s).
// Output: one `SMOKE_PASS|SMOKE_FAIL|SMOKE_SKIP|SMOKE_VIEW <what>` line per step, then `SMOKE_OK` and exit 0,
// or `SMOKE_FAILED <n>` and exit 1.
import AppKit
import SuperNotchCore
import SwiftUI

enum SmokeTest {
    static let argument = "--smoke-test"
    /// Set (=1) for the smoke-test process. Models must then skip anything that could show a dialog or touch
    /// files outside Application Support / the temp folder (claude-app: `ClaudeSessionsModel.isSmokeTest`).
    static let environmentFlag = "SUPERNOTCH_SMOKE_TEST"

    private static let defaultsSuite = "io.github.snakez3101.supernotch.smoke-test"
    private static let timeoutSeconds: Double = 25

    static func run() -> Never {
        armWatchdog(seconds: timeoutSeconds)
        var failures: [String] = []
        func check(_ passed: Bool, _ what: String) {
            emit(passed ? "SMOKE_PASS \(what)" : "SMOKE_FAIL \(what)")
            if !passed { failures.append(what) }
        }

        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "dev"
        emit("SMOKE_START SuperNotch \(version)")

        // Sandbox everything external: IPC socket, Claude config folder (never ~/.claude), smoke flag.
        let pid = ProcessInfo.processInfo.processIdentifier
        let scratch = NSTemporaryDirectory() + "supernotch-smoke-\(pid)"
        let claudeConfig = scratch + "/claude-config"
        let socketPath = NSTemporaryDirectory() + "supernotch-smoke-\(pid).sock"  // short: sun_path ≤ 103 bytes
        do {
            try FileManager.default.createDirectory(
                atPath: claudeConfig, withIntermediateDirectories: true, attributes: nil)
        } catch {
            emit("SMOKE_FAIL temp folder: \(error.localizedDescription)")
            exit(1)
        }
        setenv(environmentFlag, "1", 1)
        setenv("SUPERNOTCH_SOCKET", socketPath, 1)
        setenv("CLAUDE_CONFIG_DIR", claudeConfig, 1)

        // 1. Core contracts.
        var sample = AppSettings()
        sample.closedMode = .invisible
        sample.clipboardHotkey = nil
        check(AppSettings.decode(from: sample.encoded()) == sample, "AppSettings JSON round trip")
        check(KeyCombo.toggleNotchDefault.description == "⌥⌘N", "KeyCombo description")
        let paths = SuperNotchPaths(homeDirectory: NSHomeDirectory())
        check(paths.hookBinary.hasSuffix("/SuperNotch/bin/supernotch-hook"), "SuperNotchPaths hook binary")
        let wings = NotchMetrics.closedWings(mode: .invisible, hasIslandContent: false, showsUsageWarning: true)
        check(wings.leading == 0 && wings.trailing == NotchMetrics.warningWingWidth, "NotchMetrics closed wings")

        // 2. Bundle layout (only when running from SuperNotch.app).
        checkBundle(check)

        // 3. Settings persistence in an isolated suite.
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            emit("SMOKE_FAIL isolated UserDefaults suite")
            exit(1)
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        let store = SettingsStore(defaults: defaults)
        var observedChanges = 0
        let observation = store.observe { old, new in
            if old.hoverOpenDelay != new.hoverOpenDelay { observedChanges += 1 }
        }
        store.settings.hoverOpenDelay = 0.3
        store.settings.hoverOpenDelay = 0.3  // no change ⇒ no notification
        check(observedChanges == 1, "SettingsStore notifies observers once per real change")
        check(SettingsStore(defaults: defaults).settings.hoverOpenDelay == 0.3, "SettingsStore persists")
        store.update { $0.clipboardLimit = 5 }
        check(store.settings.clipboardLimit == AppSettings.clipboardLimitRange.lowerBound, "SettingsStore normalizes")
        store.settings.onboardingCompleted = true
        store.reset()
        check(
            store.settings.hoverOpenDelay == AppSettings.defaults.hoverOpenDelay && store.settings.onboardingCompleted,
            "SettingsStore reset keeps onboarding state")
        observation.cancel()
        store.settings.claudeConfigDirOverride = claudeConfig

        // 4. Every frozen slot and window root builds with all models injected (all features enabled).
        let model = AppModel(settings: store, paths: paths)
        check(AppModel.shared === model, "AppModel.shared")
        renderAllViews(model)

        // 5. Lifecycle (skipped if a real instance is running: hotkeys and shelf files are shared).
        let bundleID = Bundle.main.bundleIdentifier ?? SuperNotchPaths.bundleIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != pid }
        if otherInstances.isEmpty {
            // No Automation prompt (Spotify) and no pasteboard reads (clipboard history) in a smoke test.
            store.update {
                $0.spotifyEnabled = false
                $0.clipboardEnabled = false
            }
            model.start()
            check(model.isRunning, "models start")
            let controller = NotchWindowController(appModel: model)
            controller.start()
            spin(0.8)
            model.notch.open(tab: .home, focus: false)
            spin(0.5)
            model.notch.open(tab: .shelf, focus: false)
            spin(0.5)
            model.notch.close()
            spin(0.5)
            controller.stop()
            model.stop()
            spin(0.2)
            check(!model.isRunning, "models stop")
        } else {
            emit("SMOKE_SKIP lifecycle (another SuperNotch instance is running)")
        }

        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: scratch)

        if failures.isEmpty {
            emit("SMOKE_OK")
            exit(0)
        }
        emit("SMOKE_FAILED \(failures.count): \(failures.joined(separator: ", "))")
        exit(1)
    }

    // MARK: Steps

    private static func checkBundle(_ check: (Bool, String) -> Void) {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            emit("SMOKE_SKIP bundle layout (not running from an .app)")
            return
        }
        let info = Bundle.main.infoDictionary ?? [:]
        check(Bundle.main.bundleIdentifier == SuperNotchPaths.bundleIdentifier, "bundle identifier")
        let isAgent = (info["LSUIElement"] as? Bool) ?? ((info["LSUIElement"] as? String) == "1")
        check(isAgent, "LSUIElement")
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/" + SuperNotchPaths.hookBinaryName).path
        check(FileManager.default.isExecutableFile(atPath: helper), "hook helper in Contents/Helpers")
    }

    private static func renderAllViews(_ model: AppModel) {
        let now = Date()
        let notchHeight = NotchMetrics.fallbackNotchSize.height
        let wing = CGSize(width: NotchMetrics.islandWingWidth, height: notchHeight)
        let tabSize = CGSize(
            width: NotchMetrics.expandedWidth - 2 * NotchMetrics.contentPadding,
            height: NotchMetrics.expandedExtraHeight - NotchMetrics.contentPadding)
        let donePeek = PopupRequest.claudeDone(
            sessionID: "smoke-test", hostAppBundleID: nil, autoDismissAfter: 4, now: now)
        let permissionPeek = PopupRequest.claudePermission(requestID: "smoke-test", hostAppBundleID: nil, now: now)

        render("NotchContainerView", model.inject(NotchContainerView()), size: NotchMetrics.panelSize)
        render("islandLeading", model.inject(NotchSlots.islandLeading()), size: wing)
        render("islandTrailing", model.inject(NotchSlots.islandTrailing()), size: wing)
        render("HomeTabView", model.inject(NotchSlots.tab(.home)), size: tabSize)
        render("ShelfTabView", model.inject(NotchSlots.tab(.shelf)), size: tabSize)
        render(
            "ClaudePeekView", model.inject(NotchSlots.peek(donePeek)),
            size: CGSize(width: NotchMetrics.peekWidth, height: NotchMetrics.peekExtraHeight))
        render(
            "PermissionCardView", model.inject(NotchSlots.peek(permissionPeek)),
            size: CGSize(width: NotchMetrics.permissionPeekWidth, height: NotchMetrics.permissionPeekExtraHeight))

        let settingsSize = CGSize(width: 720, height: 520)
        render("SettingsView", model.inject(SettingsView()), size: settingsSize)
        render("ClaudeSettingsSection", model.inject(ClaudeSettingsSection()), size: settingsSize)
        render("MediaSettingsSection", model.inject(MediaSettingsSection()), size: settingsSize)
        render("ShelfSettingsSection", model.inject(ShelfSettingsSection()), size: settingsSize)
        render("ClipboardSettingsSection", model.inject(ClipboardSettingsSection()), size: settingsSize)

        let onboardingSize = CGSize(width: 560, height: 460)
        render("OnboardingView", model.inject(OnboardingView()), size: onboardingSize)
        render("OnboardingHooksStep", model.inject(OnboardingHooksStep()), size: onboardingSize)
        render("OnboardingSpotifyStep", model.inject(OnboardingSpotifyStep()), size: onboardingSize)
        render("OnboardingPasteStep", model.inject(OnboardingPasteStep()), size: onboardingSize)
    }

    /// Builds the view in an NSHostingView and forces a layout pass (evaluates every `body`).
    private static func render<V: View>(_ name: String, _ view: V, size: CGSize) {
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        emit("SMOKE_VIEW \(name)")
    }

    // MARK: Helpers

    /// Runs the main run loop (timers, main-queue and MainActor work) for `seconds`.
    private static func spin(_ seconds: Double) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            let slice = min(end, Date(timeIntervalSinceNow: 0.05))
            if !RunLoop.main.run(mode: .default, before: slice) {
                Thread.sleep(forTimeInterval: 0.01)  // no input sources yet: don't busy-wait
            }
        }
    }

    private nonisolated static func emit(_ line: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }

    private nonisolated static func armWatchdog(seconds: Double) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            try? FileHandle.standardError.write(contentsOf: Data("SMOKE_TIMEOUT after \(Int(seconds)) s\n".utf8))
            exit(3)
        }
    }
}
