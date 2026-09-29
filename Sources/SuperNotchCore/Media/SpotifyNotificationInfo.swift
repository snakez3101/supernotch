import Foundation

// Owner: media. The `userInfo` of the distributed notification `com.spotify.client.PlaybackStateChanged`
// (SPEC §A.5): an instant, permission-free update while the authoritative AppleScript refresh is running.
//
// The exact key set is not documented by Spotify. From the wild (Sleeve, Now Playing scripts):
//   "Player State" ("Playing"/"Paused"/"Stopped"), "Track ID" ("spotify:track:..."), "Name", "Artist",
//   "Album", "Album Artist", "Duration" (milliseconds), "Playback Position" (seconds), "Track Number", ...
// Keys are therefore matched loosely (case, spaces and punctuation ignored) and every field is optional;
// the AppleScript refresh that always follows is the source of truth.

public struct SpotifyNotificationInfo: Sendable, Equatable {
    public var state: PlaybackState?
    public var trackID: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var durationSeconds: Double?
    public var positionSeconds: Double?

    public init(
        state: PlaybackState? = nil, trackID: String? = nil, title: String? = nil, artist: String? = nil,
        album: String? = nil, durationSeconds: Double? = nil, positionSeconds: Double? = nil
    ) {
        self.state = state
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.positionSeconds = positionSeconds
    }

    /// nil when the notification carries neither a player state nor a track id.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo, !userInfo.isEmpty else { return nil }
        var values: [String: Any] = [:]
        for (key, value) in userInfo {
            if let name = key.base as? String { values[Self.normalizedKey(name)] = value }
        }
        self.init()
        state = Self.string(values["playerstate"]).flatMap(Self.playbackState)
        trackID = Self.string(values["trackid"]).map(SpotifyScriptParser.canonicalTrackID).flatMap {
            $0.isEmpty ? nil : $0
        }
        title = Self.string(values["name"])
        artist = Self.string(values["artist"])
        album = Self.string(values["album"])
        if let milliseconds = Self.number(values["duration"]), milliseconds >= 0 {
            durationSeconds = milliseconds / 1000
        }
        if let seconds = Self.number(values["playbackposition"]), seconds >= 0 { positionSeconds = seconds }
        guard state != nil || trackID != nil else { return nil }
    }

    /// Lowercased, letters and digits only ("Player State" -> "playerstate").
    static func normalizedKey(_ key: String) -> String {
        String(key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func playbackState(_ raw: String) -> PlaybackState? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing": return .playing
        case "paused": return .paused
        case "stopped": return .stopped
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? Double, number.isFinite { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
        if let text = value as? String { return SpotifyScriptParser.number(text) }
        return nil
    }
}

public enum SpotifySnapshotMerger {
    /// Applies a notification to the previous snapshot. Returns nil when the notification carries nothing
    /// usable. Never touches artwork of a *different* track; artwork is filled by the next AppleScript refresh.
    public static func merge(
        previous: PlaybackSnapshot?, info: SpotifyNotificationInfo, now: Date
    ) -> PlaybackSnapshot? {
        guard info.state != nil || info.trackID != nil else { return nil }

        let previousTrack = previous?.track
        var track = previousTrack
        var sameTrack = true
        if let id = info.trackID, !id.isEmpty {
            sameTrack = previousTrack?.id == id
            track = TrackInfo(
                id: id,
                title: info.title ?? (sameTrack ? previousTrack?.title : nil) ?? "",
                artist: info.artist ?? (sameTrack ? previousTrack?.artist : nil) ?? "",
                album: info.album ?? (sameTrack ? previousTrack?.album : nil) ?? "",
                durationSeconds: info.durationSeconds ?? (sameTrack ? previousTrack?.durationSeconds : nil) ?? 0,
                artworkURL: sameTrack ? previousTrack?.artworkURL : nil)
        }

        let state = info.state ?? previous?.state ?? .paused
        let position: Double
        if let reported = info.positionSeconds {
            position = reported
        } else if sameTrack, let previous {
            position = previous.position(at: now)
        } else {
            position = 0
        }
        return PlaybackSnapshot(
            track: track, state: state, positionSeconds: max(0, position), positionTimestamp: now,
            shuffling: previous?.shuffling ?? false, repeating: previous?.repeating ?? false,
            volume: previous?.volume ?? 100)
    }
}
