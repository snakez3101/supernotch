// Owner: media. Seed tests by the foundation.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("SpotifyScriptParser")
struct SpotifyScriptParserTests {
    let now = Date(timeIntervalSince1970: 100)
    let sep = "\u{1F}"

    @Test func playingTrackWithLocaleDecimal() throws {
        let output = ["playing", "12,5", "false", "true", "80", "spotify:track:abc", "Song", "Artist", "Album",
            "200000", "https://i.scdn.co/image/x"].joined(separator: sep)
        let snapshot = try #require(SpotifyScriptParser.parse(output, now: now))
        #expect(snapshot.state == .playing)
        #expect(snapshot.positionSeconds == 12.5)
        #expect(snapshot.track?.durationSeconds == 200)
        #expect(snapshot.track?.openURL == "https://open.spotify.com/track/abc")
        #expect(snapshot.position(at: now + 10) == 22.5)
        #expect(snapshot.position(at: now + 1_000) == 200)
    }

    @Test func noTrack() throws {
        let output = ["paused", "0", "false", "false", "50", "", "", "", "", "0", ""].joined(separator: sep)
        let snapshot = try #require(SpotifyScriptParser.parse(output, now: now))
        #expect(snapshot.track == nil)
        #expect(snapshot.state == .stopped)
    }

    @Test func garbage() {
        #expect(SpotifyScriptParser.parse("", now: now) == nil)
    }

    @Test func timeFormatting() {
        #expect(PlaybackSnapshot.formatTime(62) == "1:02")
        #expect(PlaybackSnapshot.formatTime(3723) == "1:02:03")
    }
}
