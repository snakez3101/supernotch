// Owner: media stream. The only object that talks to the Spotify desktop app (SPEC §A.5, §F.1).
//
//  * Events: the distributed notification `com.spotify.client.PlaybackStateChanged` plus NSWorkspace launch /
//    terminate / wake. Nothing polls.
//  * State: ONE batched AppleScript (`SpotifyScriptParser.statusScript`, or `coreStatusScript` when this Spotify
//    build cannot run the full one) on a dedicated serial background queue.
//  * Commands: playpause, next, previous, set player position.
//  * Always checks that Spotify is running first; a bare `tell application` would launch it.
//  * Automation permission (TCC) lives in `SpotifyPermissionBroker` on queues of its own: read silently, and the
//    system dialog only appears on explicit request (one real Apple Event), every call bounded by a timeout.
import AppKit
import Foundation
import SuperNotchCore
import os

/// One status read.
enum SpotifyStatusResult {
    case snapshot(PlaybackSnapshot)
    case notRunning
    case failure(SpotifyScriptFailure)
}

final class SpotifyController {
    private let runner = SpotifyScriptRunner()
    private let permissions = SpotifyPermissionBroker()
    private var observer: SpotifyEventObserver?
    /// True after the full status script failed and the core-terms script worked (reset when Spotify quits).
    private var usesCoreStatusScript = false

    /// Called on the MainActor for every Spotify / system event.
    var onEvent: ((SpotifyControllerEvent) -> Void)?

    var isRunning: Bool { SpotifyApp.isRunning }

    // MARK: Lifecycle

    func start() {
        guard observer == nil else { return }
        let observer = SpotifyEventObserver { [weak self] event in
            // Delivered on the main thread by the notification centres; hop explicitly for the compiler.
            Task { @MainActor in self?.deliver(event) }
        }
        observer.startObserving()
        self.observer = observer
    }

    func stop() {
        observer?.stopObserving()
        observer = nil
    }

    private func deliver(_ event: SpotifyControllerEvent) {
        switch event {
        case .launched, .terminated:
            usesCoreStatusScript = false  // a relaunched (maybe updated) Spotify gets the full script again
        case .playbackChanged, .didWake:
            break
        }
        onEvent?(event)
    }

    // MARK: State

    /// Reads state, track, artwork URL, duration and position in one script run. The snapshot's timestamp is
    /// the midpoint of the round trip: Spotify sampled its position somewhere inside it.
    ///
    /// If the full script fails for a reason other than permission / not running / timeout (typically a term
    /// missing from this Spotify build's dictionary, which is a compile error no `try` inside the script can
    /// catch), the core-terms script is tried and, when it works, used until Spotify quits.
    func fetchStatus() async -> SpotifyStatusResult {
        guard SpotifyApp.isRunning else {
            usesCoreStatusScript = false  // a relaunched (maybe updated) Spotify gets the full script again
            return .notRunning
        }
        if !usesCoreStatusScript {
            let result = await fetchStatus(source: SpotifyScriptParser.statusScript)
            guard case .failure(.other) = result else { return result }
            let fallback = await fetchStatus(source: SpotifyScriptParser.coreStatusScript)
            if case .snapshot = fallback {
                usesCoreStatusScript = true
                Log.media.error("Full Spotify status script failed; using the core-terms script until Spotify quits")
            }
            return fallback
        }
        return await fetchStatus(source: SpotifyScriptParser.coreStatusScript)
    }

    private func fetchStatus(source: String) async -> SpotifyStatusResult {
        let started = Date()
        let outcome = await runner.run(source: source)
        let finished = Date()
        switch outcome {
        case .output(let text):
            let midpoint = started.addingTimeInterval(finished.timeIntervalSince(started) / 2)
            switch SpotifyScriptParser.parseResult(text, now: midpoint) {
            case .snapshot(let snapshot): return .snapshot(snapshot)
            case .notRunning: return .notRunning
            case .invalid:
                Log.media.error("Spotify status script returned unparsable output")
                return .failure(.other(0))
            }
        case .failure(let failure, let message):
            Log.media.error(
                "Spotify status script failed: \(String(describing: failure), privacy: .public) \(message, privacy: .public)"
            )
            return .failure(failure)
        }
    }

    // MARK: Commands

    /// nil on success.
    func perform(_ command: SpotifyCommand) async -> SpotifyScriptFailure? {
        switch await runner.run(source: command.script) {
        case .output:
            return nil
        case .failure(let failure, let message):
            Log.media.error(
                "Spotify command failed: \(String(describing: failure), privacy: .public) \(message, privacy: .public)"
            )
            return failure
        }
    }

    // MARK: Permission

    /// Silent Automation check (never prompts); `.timedOut` after a few seconds.
    func checkPermission() async -> MediaPermissionCallResult {
        await permissions.check()
    }

    /// Sends one harmless real Apple Event, which makes macOS show its dialog when no decision is stored.
    /// `.timedOut` after `MediaPermissionTimeouts.ask`; an answer that arrives later goes to `late`.
    func askPermission(late: @escaping @Sendable (Int32) -> Void) async -> MediaPermissionCallResult {
        await permissions.ask(late: late)
    }

    /// `tccutil reset AppleEvents <bundleID>`; true on success.
    func resetPermission(bundleID: String) async -> Bool {
        await permissions.resetAppleEvents(bundleID: bundleID)
    }

    /// Privacy & Security > Automation: the macOS 13+ link, then the old one, then System Settings itself.
    func openAutomationSettings() {
        let workspace = NSWorkspace.shared
        for link in MediaSystemSettingsLink.automationCandidates {
            guard let url = URL(string: link) else { continue }
            if workspace.open(url) {
                Log.media.info("Opened System Settings via \(link, privacy: .public)")
                return
            }
            Log.media.error("Opening \(link, privacy: .public) failed")
        }
        guard
            let settingsURL = workspace.urlForApplication(
                withBundleIdentifier: MediaSystemSettingsLink.systemSettingsBundleID)
        else {
            Log.media.error("System Settings not found")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: settingsURL, configuration: configuration) { _, error in
            if let error {
                Log.media.error("Opening System Settings failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Opening Spotify

    /// Launches Spotify, or brings it to the front when it is already running. Returns false when Spotify is not
    /// installed (the download page opens instead).
    @discardableResult
    func openSpotify() -> Bool {
        let workspace = NSWorkspace.shared
        guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: SpotifyApp.bundleID) else {
            Log.media.error("Spotify is not installed; opening the download page")
            if let download = URL(string: "https://www.spotify.com/download/mac/") { workspace.open(download) }
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: applicationURL, configuration: configuration) { _, error in
            if let error {
                Log.media.error("Opening Spotify failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }
}
