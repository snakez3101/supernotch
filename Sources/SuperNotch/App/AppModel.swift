// Owner: FOUNDATION (SPEC §D.4, §D.10).
//
// Owns every app-side model, builds them in the frozen order (settings → notch → claude → media → shelf →
// clipboard), drives their start/stop lifecycle and injects them into SwiftUI hierarchies.
//
// Views read models with `@Environment(X.self)`. Every hierarchy built with `inject(_:)` also carries the
// AppModel itself (`@Environment(AppModel.self)`), e.g. for `showSettings()` / `showOnboarding()`.
import AppKit
import Observation
import SuperNotchCore
import SwiftUI

@Observable
final class AppModel {
    /// The running app's model. For AppKit glue that cannot reach the SwiftUI environment only;
    /// views must use `@Environment`. Set by `init` (the app creates exactly one).
    private(set) static var shared: AppModel?

    let paths: SuperNotchPaths
    let settings: SettingsStore
    let notch: NotchViewModel
    let claude: ClaudeSessionsModel
    let media: MediaModel
    let shelf: ShelfModel
    let clipboard: ClipboardModel

    /// "1.2.3" from Info.plist, or "dev" when running unbundled (`swift run`).
    let version: String
    /// CFBundleVersion, or "0".
    let build: String

    /// True between `start()` and `stop()`.
    private(set) var isRunning = false

    /// Set by `AppDelegate`: open/focus the Settings window.
    @ObservationIgnored var showSettingsHandler: (() -> Void)?
    /// Set by `AppDelegate`: open/focus the onboarding window.
    @ObservationIgnored var showOnboardingHandler: (() -> Void)?

    init(
        settings: SettingsStore = SettingsStore(),
        paths: SuperNotchPaths = SuperNotchPaths(homeDirectory: NSHomeDirectory())
    ) {
        self.paths = paths
        self.settings = settings
        let notch = NotchViewModel(settings: settings)
        self.notch = notch
        claude = ClaudeSessionsModel(settings: settings, notch: notch)
        media = MediaModel(settings: settings, notch: notch)
        shelf = ShelfModel(settings: settings, notch: notch)
        clipboard = ClipboardModel(settings: settings, notch: notch)
        let info = Bundle.main.infoDictionary ?? [:]
        version = (info["CFBundleShortVersionString"] as? String) ?? "dev"
        build = (info["CFBundleVersion"] as? String) ?? "0"
        AppModel.shared = self
    }

    // MARK: Lifecycle

    /// Starts every model in the frozen order. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        Log.app.info("Starting SuperNotch \(self.version, privacy: .public) (\(self.build, privacy: .public))")
        ensureAppSupportDirectory()
        notch.start()
        claude.start()
        media.start()
        shelf.start()
        clipboard.start()
    }

    /// Stops every model in reverse order. Idempotent.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        Log.app.info("Stopping models")
        clipboard.stop()
        shelf.stop()
        media.stop()
        claude.stop()
        notch.stop()
    }

    // MARK: SwiftUI

    /// Injects the AppModel and all six models into a SwiftUI hierarchy.
    func inject<V: View>(_ view: V) -> some View {
        view
            .environment(self)
            .environment(settings)
            .environment(notch)
            .environment(claude)
            .environment(media)
            .environment(shelf)
            .environment(clipboard)
    }

    // MARK: App actions (usable from any view via @Environment(AppModel.self))

    /// Opens (or focuses) the Settings window.
    func showSettings() {
        guard let handler = showSettingsHandler else {
            Log.app.error("showSettings() called before the AppDelegate installed its handler")
            return
        }
        handler()
    }

    /// Opens (or focuses) the onboarding wizard ("Run setup again").
    func showOnboarding() {
        guard let handler = showOnboardingHandler else {
            Log.app.error("showOnboarding() called before the AppDelegate installed its handler")
            return
        }
        handler()
    }

    /// Quits the app (models are stopped in `applicationWillTerminate`).
    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Private

    private func ensureAppSupportDirectory() {
        do {
            try FileManager.default.createDirectory(
                atPath: paths.appSupport, withIntermediateDirectories: true, attributes: nil)
        } catch {
            let reason = error.localizedDescription
            Log.app.error("Could not create the Application Support folder: \(reason, privacy: .public)")
        }
    }
}
