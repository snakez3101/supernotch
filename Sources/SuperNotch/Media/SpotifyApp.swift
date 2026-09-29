// Owner: media stream. Facts about the Spotify desktop app.
import AppKit

/// Spotify desktop app helpers. Everything here is safe to call from any thread.
nonisolated enum SpotifyApp {
    static let bundleID = "com.spotify.client"

    /// The running Spotify instance, if any. Sending Apple Events to a target that is not running would
    /// LAUNCH it, so every AppleScript run is preceded by this check (SPEC §F.1).
    static var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    static var isRunning: Bool { runningApplication != nil }
}
