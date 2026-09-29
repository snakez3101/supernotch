// Owner: media stream. Event sources for Spotify: no polling, no timers (SPEC §F.1).
import AppKit
import Foundation
import SuperNotchCore
import os

/// What the observers report. `Sendable` so it can hop to the MainActor.
nonisolated enum SpotifyControllerEvent: Sendable {
    /// `com.spotify.client.PlaybackStateChanged`; the payload is nil when userInfo was empty or unusable.
    case playbackChanged(SpotifyNotificationInfo?)
    case launched
    case terminated
    case didWake
}

/// Receives Spotify's distributed notification and the NSWorkspace launch / terminate / wake notifications.
/// Selector based on purpose: `addObserver(_:selector:name:object:suspensionBehavior:)` lets us ask for
/// `.deliverImmediately`, which the block-based API cannot. The handlers only build a Sendable value and
/// call `handler`; the model hops to the MainActor itself.
nonisolated final class SpotifyEventObserver: NSObject, @unchecked Sendable {
    static let playbackNotificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private let handler: @Sendable (SpotifyControllerEvent) -> Void
    /// Only touched from the notification callback (main thread). We log the userInfo keys once because the
    /// key set is undocumented.
    private var didLogKeys = false

    init(handler: @escaping @Sendable (SpotifyControllerEvent) -> Void) {
        self.handler = handler
        super.init()
    }

    @MainActor
    func startObserving() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackStateChanged(_:)), name: Self.playbackNotificationName,
            object: nil, suspensionBehavior: .deliverImmediately)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(applicationLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification,
            object: nil)
        workspace.addObserver(
            self, selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @MainActor
    func stopObserving() {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Selectors

    @objc private func playbackStateChanged(_ notification: Notification) {
        if !didLogKeys, let userInfo = notification.userInfo {
            didLogKeys = true
            let keys = userInfo.keys.compactMap { $0.base as? String }.sorted().joined(separator: ", ")
            Log.media.debug("Spotify notification userInfo keys: \(keys, privacy: .public)")
        }
        handler(.playbackChanged(SpotifyNotificationInfo(userInfo: notification.userInfo)))
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        if Self.isSpotify(notification) { handler(.launched) }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        if Self.isSpotify(notification) { handler(.terminated) }
    }

    @objc private func systemDidWake(_ notification: Notification) {
        handler(.didWake)
    }

    private static func isSpotify(_ notification: Notification) -> Bool {
        guard let app = notification.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication else {
            return false
        }
        return app.bundleIdentifier == SpotifyApp.bundleID
    }
}
