import Foundation

// FOUNDATION-OWNED contract (SPEC §D.3). Spotify playback state as the UI consumes it.

public enum PlaybackState: String, Sendable, Hashable, Codable {
    case playing
    case paused
    case stopped
}

public struct TrackInfo: Sendable, Hashable, Codable {
    /// Spotify URI, e.g. "spotify:track:4uLU6hMCjMI75M1A2tKUQC", "spotify:episode:…", "spotify:ad:…",
    /// "spotify:local:Artist:Album:Title:123".
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var durationSeconds: Double
    /// `artwork url` from AppleScript (https://i.scdn.co/image/…), nil for local files/ads.
    public var artworkURL: String?

    public init(
        id: String, title: String, artist: String, album: String, durationSeconds: Double, artworkURL: String?
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
    }

    public var isAd: Bool { id.hasPrefix("spotify:ad:") }
    public var isLocal: Bool { id.hasPrefix("spotify:local:") }
    public var isEpisode: Bool { id.hasPrefix("spotify:episode:") }

    /// "https://open.spotify.com/track/<id>" for normal tracks (oEmbed artwork fallback), else nil.
    public var openURL: String? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" || parts[1] == "episode" else {
            return nil
        }
        return "https://open.spotify.com/\(parts[1])/\(parts[2])"
    }
}

public struct PlaybackSnapshot: Sendable, Hashable, Codable {
    public var track: TrackInfo?
    public var state: PlaybackState
    /// Position in seconds at `positionTimestamp`.
    public var positionSeconds: Double
    public var positionTimestamp: Date
    public var shuffling: Bool
    public var repeating: Bool
    /// 0…100
    public var volume: Int

    public init(
        track: TrackInfo?, state: PlaybackState, positionSeconds: Double, positionTimestamp: Date,
        shuffling: Bool = false, repeating: Bool = false, volume: Int = 100
    ) {
        self.track = track
        self.state = state
        self.positionSeconds = positionSeconds
        self.positionTimestamp = positionTimestamp
        self.shuffling = shuffling
        self.repeating = repeating
        self.volume = volume
    }

    public var isPlaying: Bool { state == .playing }

    /// Extrapolated position (seconds), clamped to the track duration.
    public func position(at date: Date) -> Double {
        var position = positionSeconds
        if state == .playing { position += max(0, date.timeIntervalSince(positionTimestamp)) }
        if let duration = track?.durationSeconds, duration > 0 { position = min(position, duration) }
        return max(0, position)
    }

    /// 0…1 progress for the scrubber.
    public func progress(at date: Date) -> Double {
        guard let duration = track?.durationSeconds, duration > 0 else { return 0 }
        return min(max(position(at: date) / duration, 0), 1)
    }

    /// "1:02" / "1:02:03"
    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(secs))" : "\(minutes):\(two(secs))"
    }
}
