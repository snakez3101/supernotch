// Owner: media. Distributed notification `com.spotify.client.PlaybackStateChanged` -> instant snapshot.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("SpotifyNotification")
struct SpotifyNotificationTests {
    let now = Date(timeIntervalSince1970: 1_000)

    @Test func parsesFullUserInfo() throws {
        let info = try #require(SpotifyNotificationInfo(userInfo: try MediaFixtures.userInfo("notification-playing")))
        #expect(info.state == .playing)
        #expect(info.trackID == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(info.title == "Bohemian Rhapsody - Remastered 2011")
        #expect(info.artist == "Queen")
        #expect(info.album == "Greatest Hits I, II & III: The Platinum Collection")
        #expect(info.durationSeconds == 354.32)
        #expect(info.positionSeconds == 12.5)
    }

    @Test func keysAreMatchedLoosely() throws {
        let info = try #require(
            SpotifyNotificationInfo(userInfo: ["player_state": "paused", "TRACK ID": "spotify:track:x", "Duration": "1000"]))
        #expect(info.state == .paused)
        #expect(info.trackID == "spotify:track:x")
        #expect(info.durationSeconds == 1)
    }

    @Test func stoppedOnlyNotification() throws {
        let info = try #require(SpotifyNotificationInfo(userInfo: try MediaFixtures.userInfo("notification-stopped")))
        #expect(info.state == .stopped)
        #expect(info.trackID == nil)
    }

    @Test func unusableUserInfoIsRejected() throws {
        #expect(SpotifyNotificationInfo(userInfo: nil) == nil)
        #expect(SpotifyNotificationInfo(userInfo: [:]) == nil)
        #expect(SpotifyNotificationInfo(userInfo: try MediaFixtures.userInfo("notification-garbage")) == nil)
        #expect(SpotifyNotificationInfo(userInfo: ["Player State": "Exploding"]) == nil)
        #expect(SpotifyNotificationInfo(userInfo: ["Player State": 3, "Track ID": ""]) == nil)
    }

    @Test func mergeStartsFromNothing() throws {
        let info = try #require(SpotifyNotificationInfo(userInfo: try MediaFixtures.userInfo("notification-playing")))
        let snapshot = try #require(SpotifySnapshotMerger.merge(previous: nil, info: info, now: now))
        #expect(snapshot.state == .playing)
        #expect(snapshot.positionSeconds == 12.5)
        #expect(snapshot.positionTimestamp == now)
        #expect(snapshot.track?.title == "Bohemian Rhapsody - Remastered 2011")
        #expect(snapshot.track?.durationSeconds == 354.32)
        #expect(snapshot.track?.artworkURL == nil)  // not part of the notification
    }

    @Test func mergeKeepsArtworkOfTheSameTrackOnly() throws {
        let previous = PlaybackSnapshot(
            track: TrackInfo(
                id: "spotify:track:A", title: "A", artist: "Art", album: "Alb", durationSeconds: 100,
                artworkURL: "https://i.scdn.co/image/a"),
            state: .playing, positionSeconds: 10, positionTimestamp: now - 5, shuffling: true, repeating: false,
            volume: 42)
        // Pause of the same track: position is extrapolated to the pause moment, artwork stays.
        let paused = try #require(
            SpotifySnapshotMerger.merge(
                previous: previous, info: SpotifyNotificationInfo(state: .paused, trackID: "spotify:track:A"), now: now))
        #expect(paused.state == .paused)
        #expect(paused.positionSeconds == 15)
        #expect(paused.track?.artworkURL == "https://i.scdn.co/image/a")
        #expect(paused.track?.title == "A")
        #expect(paused.shuffling)
        #expect(paused.volume == 42)

        // A different track never inherits the old cover, and restarts at 0 without a position.
        let next = try #require(
            SpotifySnapshotMerger.merge(
                previous: previous,
                info: SpotifyNotificationInfo(state: .playing, trackID: "spotify:track:B", title: "B", artist: "Bee"),
                now: now))
        #expect(next.track?.id == "spotify:track:B")
        #expect(next.track?.artworkURL == nil)
        #expect(next.track?.title == "B")
        #expect(next.positionSeconds == 0)
    }

    @Test func mergeWithoutTrackIDKeepsPreviousTrack() throws {
        let previous = PlaybackSnapshot(
            track: TrackInfo(id: "spotify:track:A", title: "A", artist: "", album: "", durationSeconds: 100, artworkURL: nil),
            state: .playing, positionSeconds: 10, positionTimestamp: now, volume: 80)
        let stopped = try #require(
            SpotifySnapshotMerger.merge(previous: previous, info: SpotifyNotificationInfo(state: .stopped), now: now))
        #expect(stopped.state == .stopped)
        #expect(stopped.track?.id == "spotify:track:A")
        #expect(SpotifySnapshotMerger.merge(previous: previous, info: SpotifyNotificationInfo(), now: now) == nil)
    }
}
