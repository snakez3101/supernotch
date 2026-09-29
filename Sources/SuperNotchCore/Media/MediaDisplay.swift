import Foundation

// Owner: media. Presentation rules for the now-playing UI, kept pure so they are tested on Linux.

public enum MediaDisplay {
    /// Title line: ads are labelled, empty titles get a placeholder.
    public static func title(for track: TrackInfo) -> String {
        if track.isAd { return "Advertisement" }
        return track.title.isEmpty ? "Unknown title" : track.title
    }

    /// Second line: artist (or podcast show); ads are attributed to Spotify.
    public static func subtitle(for track: TrackInfo) -> String {
        if track.isAd { return "Spotify" }
        if !track.artist.isEmpty { return track.artist }
        return track.isEpisode ? "Podcast" : ""
    }

    /// Ads cannot be skipped or scrubbed.
    public static func canSkip(_ track: TrackInfo) -> Bool { !track.isAd }

    public static func canSeek(_ track: TrackInfo) -> Bool { !track.isAd && track.durationSeconds > 0 }

    /// "-2:33" (never below "-0:00").
    public static func remainingText(position: Double, duration: Double) -> String {
        "-" + PlaybackSnapshot.formatTime(max(0, duration - position))
    }
}

/// Fake, permission-free visualizer bars for the closed island (REQUIREMENTS: no audio capture).
public enum MediaVisualizerModel {
    public static let barCount = 4
    public static let restingLevel = 0.2

    /// Bar heights in 0.22…1 at `time`, a smooth pseudo-random mix of two sines per bar.
    public static func levels(at time: TimeInterval, count: Int = barCount) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let i = Double(index)
            let slow = sin(time * (2.1 + i * 0.83) + i * 1.7)
            let fast = sin(time * (3.7 + i * 0.61) + i * 3.9)
            let mix = 0.5 + 0.25 * slow + 0.25 * fast  // 0…1
            return min(max(0.22 + 0.78 * mix, 0.22), 1)
        }
    }

    /// Paused / stopped: flat little bars.
    public static func restingLevels(count: Int = barCount) -> [Double] {
        [Double](repeating: restingLevel, count: max(0, count))
    }
}
