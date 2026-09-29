// Owner: media. Position extrapolation, re-anchoring and the energy-saving refresh plan (SPEC §A.5, §F.1).
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("PlaybackReconciler")
struct PlaybackReconcilerTests {
    let t0 = Date(timeIntervalSince1970: 10_000)

    func track(_ id: String = "spotify:track:A", duration: Double = 200) -> TrackInfo {
        TrackInfo(id: id, title: "T", artist: "A", album: "B", durationSeconds: duration, artworkURL: nil)
    }

    func snapshot(
        _ state: PlaybackState = .playing, position: Double = 30, at date: Date? = nil, track: TrackInfo? = nil
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            track: track ?? self.track(), state: state, positionSeconds: position, positionTimestamp: date ?? t0)
    }

    // MARK: Extrapolation (PlaybackSnapshot.position(at:))

    @Test func extrapolatesOnlyWhilePlaying() {
        #expect(snapshot(.playing).position(at: t0 + 12) == 42)
        #expect(snapshot(.paused).position(at: t0 + 12) == 30)
        #expect(snapshot(.stopped).position(at: t0 + 12) == 30)
    }

    @Test func extrapolationClampsToDurationAndNeverGoesBackwards() {
        #expect(snapshot(.playing).position(at: t0 + 10_000) == 200)
        #expect(snapshot(.playing).position(at: t0 - 50) == 30)  // clock skew
        #expect(snapshot(.playing).progress(at: t0 + 70) == 0.5)
        let noDuration = snapshot(track: track(duration: 0))
        #expect(noDuration.progress(at: t0 + 5) == 0)
    }

    // MARK: Reconcile

    @Test func matchingPollKeepsThePreviousValue() {
        let previous = snapshot(.playing, position: 30)
        // 3 s later the poll reports 33.2: within tolerance, so the old anchor stays (no UI invalidation).
        let incoming = snapshot(.playing, position: 33.2, at: t0 + 3)
        #expect(PlaybackReconciler.reconcile(previous: previous, incoming: incoming) == previous)
    }

    @Test func driftBeyondToleranceReanchors() {
        let previous = snapshot(.playing, position: 30)
        let incoming = snapshot(.playing, position: 60, at: t0 + 3)  // the user seeked in Spotify
        #expect(PlaybackReconciler.reconcile(previous: previous, incoming: incoming) == incoming)
    }

    @Test func stateTrackOrFlagChangesAlwaysWin() {
        let previous = snapshot(.playing, position: 30)
        let paused = snapshot(.paused, position: 33, at: t0 + 3)
        #expect(PlaybackReconciler.reconcile(previous: previous, incoming: paused) == paused)

        let other = snapshot(.playing, position: 33, at: t0 + 3, track: track("spotify:track:B"))
        #expect(PlaybackReconciler.reconcile(previous: previous, incoming: other) == other)

        var shuffled = snapshot(.playing, position: 33, at: t0 + 3)
        shuffled.shuffling = true
        #expect(PlaybackReconciler.reconcile(previous: previous, incoming: shuffled) == shuffled)

        // Newly known artwork URL must be published.
        var art = track()
        art.artworkURL = "https://i.scdn.co/image/a"
        let withArt = snapshot(.playing, position: 33, at: t0 + 3, track: art)
        #expect(PlaybackReconciler.reconcile(previous: previous, incoming: withArt) == withArt)
    }

    @Test func pausedUsesTheTighterTolerance() {
        let previous = snapshot(.paused, position: 30)
        let nudged = snapshot(.paused, position: 30.5, at: t0 + 3)
        #expect(PlaybackReconciler.reconcile(previous: previous, incoming: nudged) == nudged)
        let same = snapshot(.paused, position: 30.1, at: t0 + 3)
        #expect(PlaybackReconciler.reconcile(previous: previous, incoming: same) == previous)
    }

    @Test func firstSnapshotIsTakenAsIs() {
        let incoming = snapshot()
        #expect(PlaybackReconciler.reconcile(previous: nil, incoming: incoming) == incoming)
    }

    // MARK: Optimistic updates

    @Test func togglingPlaybackAnchorsAtTheCurrentPosition() {
        let playing = snapshot(.playing, position: 30)
        let paused = playing.togglingPlayback(at: t0 + 5)
        #expect(paused.state == .paused)
        #expect(paused.positionSeconds == 35)
        #expect(paused.position(at: t0 + 100) == 35)

        let resumed = paused.togglingPlayback(at: t0 + 100)
        #expect(resumed.state == .playing)
        #expect(resumed.position(at: t0 + 102) == 37)
    }

    @Test func seekingClampsIntoTheTrack() {
        let base = snapshot(.playing, position: 30)
        #expect(base.seeking(to: 90, at: t0 + 1).position(at: t0 + 1) == 90)
        #expect(base.seeking(to: -5, at: t0).positionSeconds == 0)
        #expect(base.seeking(to: 9_999, at: t0).positionSeconds == 200)
        #expect(base.seeking(to: .nan, at: t0).positionSeconds == 0)
        #expect(base.seeking(to: 90, at: t0 + 1).state == .playing)
    }

    // MARK: Timers

    @Test func secondsUntilTrackEnd() {
        #expect(snapshot(.playing, position: 190).secondsUntilTrackEnd(at: t0 + 4) == 6)
        #expect(snapshot(.paused, position: 190).secondsUntilTrackEnd(at: t0) == nil)
        #expect(snapshot(track: track(duration: 0)).secondsUntilTrackEnd(at: t0) == nil)
    }

    @Test func trackEndRefreshDelay() {
        #expect(SpotifyRefreshPlan.trackEndRefreshDelay(for: snapshot(.playing, position: 190), at: t0) == 10.75)
        // Already at the end: wait a moment instead of spinning.
        #expect(SpotifyRefreshPlan.trackEndRefreshDelay(for: snapshot(.playing, position: 200), at: t0) == 1.5)
        #expect(SpotifyRefreshPlan.trackEndRefreshDelay(for: snapshot(.paused), at: t0) == nil)
        #expect(SpotifyRefreshPlan.trackEndRefreshDelay(for: nil, at: t0) == nil)
    }

    @Test func pollsOnlyWhileVisiblePlayingAndPermitted() {
        func interval(
            enabled: Bool = true, running: Bool = true, granted: Bool = true, playing: Bool = true,
            visible: Bool = true
        ) -> TimeInterval? {
            SpotifyRefreshPlan.pollInterval(
                isEnabled: enabled, isSpotifyRunning: running, isAutomationGranted: granted, isPlaying: playing,
                isHomeTabVisible: visible)
        }
        #expect(interval() == SpotifyRefreshPlan.visiblePlayingPollInterval)
        #expect(interval(enabled: false) == nil)
        #expect(interval(running: false) == nil)
        #expect(interval(granted: false) == nil)
        #expect(interval(playing: false) == nil)
        #expect(interval(visible: false) == nil)
    }
}
