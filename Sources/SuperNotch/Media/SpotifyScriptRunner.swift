// Owner: media stream. Runs AppleScript for Spotify on ONE dedicated serial background queue (SPEC §F.1).
// Automation permission calls live in `SpotifyPermissionBroker`, on queues of their own: a hung TCC call must
// never block the status scripts and commands.
import AppKit
import Foundation
import SuperNotchCore
import os

/// Result of one AppleScript run.
nonisolated enum SpotifyScriptOutcome: Sendable {
    /// The script's string result.
    case output(String)
    case failure(SpotifyScriptFailure, message: String)
}

/// `NSAppleScript` is not thread-safe and not `Sendable`: every script is created, compiled (cached by
/// source) and executed on `queue` only, never on the main thread. All public entry points are `async` and
/// hop to the queue with a continuation, so callers on the MainActor never block.
nonisolated final class SpotifyScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "io.github.snakez3101.supernotch.media.applescript", qos: .userInitiated)
    /// Compiled scripts by source. Touched only on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    /// Runs `source`. Never launches Spotify: if it is not running the call fails with `.notRunning`.
    func run(source: String) async -> SpotifyScriptOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<SpotifyScriptOutcome, Never>) in
            queue.async {
                continuation.resume(returning: self.runSynchronously(source))
            }
        }
    }

    // MARK: Queue-confined work

    private func runSynchronously(_ source: String) -> SpotifyScriptOutcome {
        guard SpotifyApp.isRunning else {
            return .failure(.notRunning, message: "Spotify is not running")
        }
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else {
                return .failure(.other(-1), message: "AppleScript source could not be created")
            }
            // Seek scripts embed the target position, so keep the cache from growing without bound.
            if compiled.count >= 16 { compiled.removeAll() }
            compiled[source] = created
            script = created
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
            let message = (errorInfo["NSAppleScriptErrorMessage"] as? String) ?? ""
            Log.media.error("AppleScript error number \(number, privacy: .public)")
            return .failure(SpotifyScriptFailure(appleScriptErrorNumber: number), message: message)
        }
        return .output(descriptor.stringValue ?? "")
    }
}
