// Owner: media. SPEC §G.1: normal, ad, episode, local file, not running (+ hardening cases).
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("SpotifyScriptParser")
struct SpotifyScriptParserTests {
    let now = Date(timeIntervalSince1970: 100)
    let sep = "\u{1F}"

    // MARK: Fixtures

    @Test func normalTrack() throws {
        let snapshot = try #require(SpotifyScriptParser.parse(try MediaFixtures.status("status-normal"), now: now))
        #expect(snapshot.state == .playing)
        #expect(snapshot.positionSeconds == 12.5)
        #expect(snapshot.positionTimestamp == now)
        #expect(snapshot.shuffling)
        #expect(!snapshot.repeating)
        #expect(snapshot.volume == 65)
        let track = try #require(snapshot.track)
        #expect(track.id == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(track.title == "Bohemian Rhapsody - Remastered 2011")
        #expect(track.artist == "Queen")
        #expect(track.album == "Greatest Hits I, II & III: The Platinum Collection")
        #expect(track.durationSeconds == 354.32)
        #expect(track.artworkURL == "https://i.scdn.co/image/ab67616d0000b273e8b066f70c206551210d902b")
        #expect(!track.isAd && !track.isLocal && !track.isEpisode)
        #expect(track.openURL == "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
    }

    @Test func adHasNoArtworkAndIsFlagged() throws {
        let snapshot = try #require(SpotifyScriptParser.parse(try MediaFixtures.status("status-ad"), now: now))
        let track = try #require(snapshot.track)
        #expect(track.isAd)
        #expect(track.artworkURL == nil)  // "missing value" is not a URL
        #expect(track.openURL == nil)
        #expect(track.durationSeconds == 30)
        #expect(snapshot.positionSeconds == 3.25)  // comma decimal
        #expect(snapshot.state == .playing)
    }

    @Test func episode() throws {
        let snapshot = try #require(SpotifyScriptParser.parse(try MediaFixtures.status("status-episode"), now: now))
        let track = try #require(snapshot.track)
        #expect(track.isEpisode)
        #expect(track.title == "#123 – Sleep, Dreams & Memory")
        #expect(track.durationSeconds == 7200)
        #expect(track.openURL == "https://open.spotify.com/episode/7makk4oTQel546B0PZlDM5")
        #expect(snapshot.state == .paused)
        #expect(snapshot.positionSeconds == 1234.6)
    }

    @Test func localFile() throws {
        let snapshot = try #require(SpotifyScriptParser.parse(try MediaFixtures.status("status-local"), now: now))
        let track = try #require(snapshot.track)
        #expect(track.isLocal)
        #expect(track.artworkURL == nil)
        #expect(track.openURL == nil)  // more than three URI parts
        #expect(track.title == "My Song")
        #expect(snapshot.repeating)
    }

    @Test func notRunningSentinel() throws {
        let output = try MediaFixtures.status("status-not-running")
        #expect(SpotifyScriptParser.parseResult(output, now: now) == .notRunning)
        #expect(SpotifyScriptParser.parse(output, now: now) == nil)
    }

    @Test func noTrackIsStopped() throws {
        let snapshot = try #require(SpotifyScriptParser.parse(try MediaFixtures.status("status-no-track"), now: now))
        #expect(snapshot.track == nil)
        #expect(snapshot.state == .stopped)
        #expect(snapshot.volume == 50)
    }

    @Test func germanLocaleNumbersAndExponent() throws {
        let snapshot = try #require(
            SpotifyScriptParser.parse(try MediaFixtures.status("status-german-locale"), now: now))
        #expect(snapshot.positionSeconds == 98.4)
        #expect(snapshot.track?.durationSeconds == 240)  // "2,4E+5" ms
        #expect(snapshot.track?.title == "Über den Wolken")
        #expect(snapshot.volume == 72)
    }

    @Test func numbersWithGroupingAndDecimalSeparators() throws {
        let snapshot = try #require(
            SpotifyScriptParser.parse(try MediaFixtures.status("status-bad-number"), now: now))
        #expect(snapshot.positionSeconds == 1234.5)  // "1.234,5"
        #expect(snapshot.track?.title == "Lied")
        #expect(SpotifyScriptParser.number("1,234.5") == 1234.5)
        #expect(SpotifyScriptParser.number("12,5") == 12.5)
        #expect(SpotifyScriptParser.number("1,5E+2") == 150)
        #expect(SpotifyScriptParser.number("  7 ") == 7)
        #expect(SpotifyScriptParser.number("1.2.3") == nil)
        #expect(SpotifyScriptParser.number("abc") == nil)
        #expect(SpotifyScriptParser.number("") == nil)
        #expect(SpotifyScriptParser.number("nan") == nil)
        #expect(SpotifyScriptParser.number("-inf") == nil)
    }

    @Test func rawEnumCodes() throws {
        let snapshot = try #require(SpotifyScriptParser.parse(try MediaFixtures.status("status-raw-enum"), now: now))
        #expect(snapshot.state == .playing)
        #expect(SpotifyScriptParser.playbackState("«constant ****kPSp»") == .paused)
        #expect(SpotifyScriptParser.playbackState("«constant ****kPSS»") == .stopped)
        #expect(SpotifyScriptParser.playbackState("banana") == .stopped)
        #expect(SpotifyScriptParser.playbackState("Playing") == .playing)
    }

    @Test func shortOutputHasStateButNoTrack() throws {
        let snapshot = try #require(SpotifyScriptParser.parse(try MediaFixtures.status("status-short"), now: now))
        #expect(snapshot.track == nil)
        #expect(snapshot.state == .stopped)
    }

    @Test func extraFieldsAndEmbeddedNewlineAreTolerated() throws {
        let snapshot = try #require(
            SpotifyScriptParser.parse(try MediaFixtures.status("status-extra-fields"), now: now))
        let track = try #require(snapshot.track)
        #expect(track.title == "Two\nLine Title")
        #expect(track.artworkURL == "https://i.scdn.co/image/m")
        #expect(snapshot.state == .playing)
    }

    // MARK: Inline cases

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

    @Test func pausedWithoutTrackBecomesStopped() throws {
        let output = ["paused", "0", "false", "false", "50", "", "", "", "", "0", ""].joined(separator: sep)
        let snapshot = try #require(SpotifyScriptParser.parse(output, now: now))
        #expect(snapshot.track == nil)
        #expect(snapshot.state == .stopped)
    }

    @Test func garbageNeverCrashes() {
        #expect(SpotifyScriptParser.parse("", now: now) == nil)
        #expect(SpotifyScriptParser.parse("   \n", now: now) == nil)
        #expect(SpotifyScriptParser.parse("hello world", now: now) == nil)
        #expect(SpotifyScriptParser.parseResult("", now: now) == .invalid)
        #expect(SpotifyScriptParser.parse(sep + sep, now: now) == nil)
        // Wrong types in every slot.
        let junk = ["x", "y", "z", "w", "v", "spotify:track:q", "t", "a", "b", "nan", "inf"].joined(separator: sep)
        let snapshot = SpotifyScriptParser.parse(junk, now: now)
        #expect(snapshot?.positionSeconds == 0)
        #expect(snapshot?.volume == 100)
        #expect(snapshot?.track?.durationSeconds == 0)
    }

    @Test func volumeIsClamped() throws {
        let loud = ["playing", "0", "false", "false", "250"].joined(separator: sep)
        #expect(SpotifyScriptParser.parse(loud, now: now)?.volume == 100)
        let negative = ["playing", "-4", "false", "false", "-20"].joined(separator: sep)
        let snapshot = try #require(SpotifyScriptParser.parse(negative, now: now))
        #expect(snapshot.volume == 0)
        #expect(snapshot.positionSeconds == 0)
    }

    @Test func statusScriptNeverLaunchesSpotifyAndUsesSeparator() {
        for script in [SpotifyScriptParser.statusScript, SpotifyScriptParser.coreStatusScript] {
            #expect(script.contains("is not running then return \"NOT_RUNNING\""))
            #expect(script.contains("with timeout"))
            #expect(!script.contains("tell application \"Spotify\""))
            // The separator is built before the `tell`, so no scripting-addition event goes to Spotify.
            let separatorLine = script.range(of: "set sep to character id 31")
            let tellLine = script.range(of: "tell application id \"com.spotify.client\"")
            #expect(separatorLine != nil && tellLine != nil)
            if let separatorLine, let tellLine { #expect(separatorLine.lowerBound < tellLine.lowerBound) }
            #expect(!script.contains("ASCII character"))
            // One `try` per read, each with its own `on error` default.
            #expect(script.components(separatedBy: "        try\n").count == script.components(separatedBy: "on error").count)
            #expect(script.components(separatedBy: " & sep & ").count == SpotifyScriptParser.fieldCount)
        }
        #expect(SpotifyScriptParser.fieldCount == 11)
        #expect(SpotifyScriptParser.separator == "\u{1F}")
    }

    @Test func coreScriptAvoidsOptionalTerms() {
        let core = SpotifyScriptParser.coreStatusScript
        for term in ["artwork url", "shuffling", "repeating", "sound volume"] {
            #expect(!core.contains(term))
            #expect(SpotifyScriptParser.statusScript.contains(term))
        }
        for term in ["player state", "player position", "current track", "id of trk", "name of trk", "artist of trk",
            "album of trk", "duration of trk"]
        {
            #expect(core.contains(term))
        }
    }

    @Test func coreScriptOutputParses() throws {
        let output = ["playing", "3", "false", "false", "100", "spotify:track:abc", "Song", "Artist", "Album",
            "200000", ""].joined(separator: sep)
        let track = try #require(SpotifyScriptParser.parse(output, now: now)?.track)
        #expect(track.artworkURL == nil)
        #expect(track.durationSeconds == 200)
    }

    @Test func canonicalTrackIDs() {
        #expect(SpotifyScriptParser.canonicalTrackID("spotify:track:4uLU6hMCjMI75M1A2tKUQC") == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(SpotifyScriptParser.canonicalTrackID(" 4uLU6hMCjMI75M1A2tKUQC ") == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(
            SpotifyScriptParser.canonicalTrackID("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=x")
                == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(
            SpotifyScriptParser.canonicalTrackID("https://open.spotify.com/episode/7makk4oTQel546B0PZlDM5")
                == "spotify:episode:7makk4oTQel546B0PZlDM5")
        #expect(SpotifyScriptParser.canonicalTrackID("spotify:ad:0000000000000000") == "spotify:ad:0000000000000000")
        #expect(SpotifyScriptParser.canonicalTrackID("https://open.spotify.com/album/x/y") == "https://open.spotify.com/album/x/y")
        #expect(SpotifyScriptParser.canonicalTrackID("") == "")
    }

    @Test func bareIdAndMissingValues() throws {
        let bare = ["playing", "1", "false", "false", "50", "4uLU6hMCjMI75M1A2tKUQC", "Song", "missing value", "Album",
            "1000", "missing value"].joined(separator: sep)
        let track = try #require(SpotifyScriptParser.parse(bare, now: now)?.track)
        #expect(track.id == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(track.artist == "")
        #expect(track.artworkURL == nil)
        #expect(track.openURL == "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")

        let missingID = ["paused", "1", "false", "false", "50", "missing value", "missing value", "", "", "0", ""]
            .joined(separator: sep)
        let snapshot = try #require(SpotifyScriptParser.parse(missingID, now: now))
        #expect(snapshot.track == nil)
        #expect(snapshot.state == .stopped)
    }

    @Test func unreadableIdStillShowsTheTrack() throws {
        let output = ["playing", "1", "false", "false", "50", "", "Song", "Artist", "Album", "1000", ""]
            .joined(separator: sep)
        let track = try #require(SpotifyScriptParser.parse(output, now: now)?.track)
        #expect(track.id == "spotify:unknown:Song|Artist|Album")
        #expect(track.title == "Song")
        #expect(!track.isAd && !track.isLocal && !track.isEpisode)
        #expect(track.openURL == nil)
    }

    @Test func timeFormatting() {
        #expect(PlaybackSnapshot.formatTime(62) == "1:02")
        #expect(PlaybackSnapshot.formatTime(3723) == "1:02:03")
        #expect(PlaybackSnapshot.formatTime(-1) == "0:00")
    }
}
