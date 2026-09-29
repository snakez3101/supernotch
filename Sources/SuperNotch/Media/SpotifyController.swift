// Owner: media stream. The only object that talks to the Spotify desktop app (SPEC §A.5, §F.1).
//
//  * Events: the distributed notification `com.spotify.client.PlaybackStateChanged` plus NSWorkspace launch /
//    terminate / wake. Nothing polls.
//  * State: ONE batched AppleScript (`SpotifyScriptParser.statusScript`) on a dedicated serial background queue.
//  * Commands: playpause, next, previous, set player position.
//  * Always checks that Spotify is running first; a bare `tell application` would launch it.
//  * Automation permission (TCC) is read silently (`askUser: false`) and only prompts on explicit request.
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
    private var observer: SpotifyEventObserver?

    /// Called on the MainActor for every Spotify / system event.
    var onEvent: ((SpotifyControllerEvent) -> Void)?

    var isRunning: Bool { SpotifyApp.isRunning }

    // MARK: Lifecycle

    func start() {
        guard observer == nil else { return }
        let observer = SpotifyEventObserver { [weak self] event in
            // Delivered on the main thread by the notification centres; hop explicitly for the compiler.
            Task { @MainActor in self?.onEvent?(event) }
        }
        observer.startObserving()
        self.observer = observer
    }

    func stop() {
        observer?.stopObserving()
        observer = nil
    }

    // MARK: State

    /// Reads state, track, artwork URL, duration and position in one Apple Event round trip. The snapshot's
    /// timestamp is the midpoint of the round trip: Spotify sampled its position somewhere inside it.
    func fetchStatus() async -> SpotifyStatusResult {
        guard SpotifyApp.isRunning else { return .notRunning }
        let started = Date()
        let outcome = await runner.run(source: SpotifyScriptParser.statusScript)
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

    /// Reads the Automation state; with `askUser` the system prompt may appear (Spotify must be running).
    func determinePermission(askUser: Bool) async -> MediaAutomationPermission {
        MediaAutomationPermission(osStatus: await runner.determinePermission(askUser: askUser))
    }

    func openAutomationSettings() {
        guard let url = URL(string: MediaSystemSettingsLink.automation) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Opening Spotify

    /// Launches Spotify, or brings it to the front when it is already running.
    func openSpotify() {
        let workspace = NSWorkspace.shared
        guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: SpotifyApp.bundleID) else {
            if let download = URL(string: "https://www.spotify.com/download/mac/") { workspace.open(download) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Task {
            do {
                _ = try await workspace.openApplication(at: applicationURL, configuration: configuration)
            } catch {
                Log.media.error("Opening Spotify failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
