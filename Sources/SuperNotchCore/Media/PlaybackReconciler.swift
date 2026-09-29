import Foundation

// Owner: media. Pure playback-position logic (SPEC §A.5, §F.1): the UI never polls, it extrapolates from
// `PlaybackSnapshot.position(at:)`; this file decides when a fresh reading really replaces the anchor,
// applies optimistic updates for user commands, and computes the two timers that keep the anchor honest.

public enum PlaybackReconciler {
    /// Position drift (seconds) that is tolerated while playing before a polled reading re-anchors the UI.
    public static let playingDriftTolerance: Double = 0.75
    /// Tolerance while paused/stopped (position only moves on a seek).
    public static let pausedDriftTolerance: Double = 0.25

    /// Returns `previous` unchanged when `incoming` says the same thing (same track, state, flags and a
    /// position that matches the extrapolation), so the published value does not change and SwiftUI does
    /// not re-render on every poll. Otherwise returns `incoming`.
    public static func reconcile(previous: PlaybackSnapshot?, incoming: PlaybackSnapshot) -> PlaybackSnapshot {
        guard let previous else { return incoming }
        guard previous.track == incoming.track, previous.state == incoming.state,
            previous.shuffling == incoming.shuffling, previous.repeating == incoming.repeating,
            previous.volume == incoming.volume
        else { return incoming }
        let expected = previous.position(at: incoming.positionTimestamp)
        let tolerance = incoming.state == .playing ? playingDriftTolerance : pausedDriftTolerance
        return abs(expected - incoming.positionSeconds) <= tolerance ? previous : incoming
    }
}

extension PlaybackSnapshot {
    /// Optimistic result of a play/pause command: flips the state and re-anchors at the current position.
    public func togglingPlayback(at now: Date) -> PlaybackSnapshot {
        var copy = self
        copy.positionSeconds = position(at: now)
        copy.positionTimestamp = now
        copy.state = state == .playing ? .paused : .playing
        return copy
    }

    /// Optimistic result of a seek: clamps into the track and re-anchors at `now`.
    public func seeking(to seconds: Double, at now: Date) -> PlaybackSnapshot {
        var copy = self
        var target = seconds.isFinite ? max(0, seconds) : 0
        if let duration = track?.durationSeconds, duration > 0 { target = min(target, duration) }
        copy.positionSeconds = target
        copy.positionTimestamp = now
        return copy
    }

    /// Seconds until the track ends while playing (nil when paused, stopped or the duration is unknown).
    public func secondsUntilTrackEnd(at now: Date) -> Double? {
        guard state == .playing, let duration = track?.durationSeconds, duration > 0 else { return nil }
        return max(0, duration - position(at: now))
    }
}

public enum SpotifyRefreshPlan {
    /// Resync interval while the Home tab is visible and Spotify is playing. Seeks made inside Spotify do not
    /// always fire a notification; this keeps the scrubber honest without a per-second poll.
    public static let visiblePlayingPollInterval: TimeInterval = 3

    /// nil = do not poll at all (the notification stream and extrapolation are enough). Polling exists only
    /// while somebody can see the scrubber: Home tab expanded, Spotify running and playing, permission granted.
    public static func pollInterval(
        isEnabled: Bool, isSpotifyRunning: Bool, isAutomationGranted: Bool, isPlaying: Bool,
        isHomeTabVisible: Bool
    ) -> TimeInterval? {
        guard isEnabled, isSpotifyRunning, isAutomationGranted, isPlaying, isHomeTabVisible else { return nil }
        return visiblePlayingPollInterval
    }

    /// One-shot refresh shortly after the current track should have ended, in case the change notification
    /// is missed (sleep, Spotify busy). nil when nothing is playing or the track length is unknown.
    public static func trackEndRefreshDelay(for snapshot: PlaybackSnapshot?, at now: Date) -> TimeInterval? {
        guard let remaining = snapshot?.secondsUntilTrackEnd(at: now) else { return nil }
        return max(remaining + 0.75, 1.5)
    }
}
