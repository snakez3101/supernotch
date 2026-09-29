// Owner: media. Presentation rules and the fake visualizer.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("MediaDisplay")
struct MediaDisplayTests {
    func track(
        id: String = "spotify:track:abc", title: String = "Song", artist: String = "Band", duration: Double = 100
    ) -> TrackInfo {
        TrackInfo(id: id, title: title, artist: artist, album: "", durationSeconds: duration, artworkURL: nil)
    }

    @Test func titlesAndSubtitles() {
        #expect(MediaDisplay.title(for: track()) == "Song")
        #expect(MediaDisplay.title(for: track(title: "")) == "Unknown title")
        #expect(MediaDisplay.subtitle(for: track()) == "Band")
        #expect(MediaDisplay.subtitle(for: track(artist: "")) == "")
        #expect(MediaDisplay.subtitle(for: track(id: "spotify:episode:x", artist: "")) == "Podcast")

        let ad = track(id: "spotify:ad:1", title: "Something", artist: "")
        #expect(MediaDisplay.title(for: ad) == "Advertisement")
        #expect(MediaDisplay.subtitle(for: ad) == "Spotify")
    }

    @Test func adsCannotBeSkippedOrScrubbed() {
        let ad = track(id: "spotify:ad:1")
        #expect(!MediaDisplay.canSkip(ad))
        #expect(!MediaDisplay.canSeek(ad))
        #expect(MediaDisplay.canSkip(track()))
        #expect(MediaDisplay.canSeek(track()))
        #expect(!MediaDisplay.canSeek(track(duration: 0)))
    }

    @Test func remainingText() {
        #expect(MediaDisplay.remainingText(position: 62, duration: 200) == "-2:18")
        #expect(MediaDisplay.remainingText(position: 250, duration: 200) == "-0:00")
        #expect(MediaDisplay.remainingText(position: 0, duration: 3723) == "-1:02:03")
    }

    @Test func visualizerLevelsAreBoundedAndMove() {
        for time in stride(from: 0.0, through: 60.0, by: 0.37) {
            let levels = MediaVisualizerModel.levels(at: time)
            #expect(levels.count == MediaVisualizerModel.barCount)
            for level in levels { #expect(level >= 0.22 && level <= 1) }
        }
        #expect(MediaVisualizerModel.levels(at: 0) != MediaVisualizerModel.levels(at: 0.5))
        #expect(MediaVisualizerModel.levels(at: 3) == MediaVisualizerModel.levels(at: 3))  // deterministic
        // Bars are out of phase with each other.
        let levels = MediaVisualizerModel.levels(at: 1.23)
        #expect(Set(levels).count > 1)
        #expect(MediaVisualizerModel.levels(at: 1, count: 0).isEmpty)
    }

    @Test func restingLevels() {
        #expect(MediaVisualizerModel.restingLevels() == [0.2, 0.2, 0.2, 0.2])
        #expect(MediaVisualizerModel.restingLevels(count: -1).isEmpty)
    }
}
