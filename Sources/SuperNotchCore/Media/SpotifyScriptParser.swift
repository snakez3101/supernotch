import Foundation

// Owner: media. Signature FROZEN (SPEC §D.3); the implementation below is a working baseline the media
// stream may harden. Parses the output of the single batched AppleScript run by SpotifyController.
//
// Contract with SpotifyController: the AppleScript returns ONE string whose fields are joined by the
// ASCII unit separator (U+001F), in exactly this order:
//   state ("playing"|"paused"|"stopped"), position (seconds, may use "," as decimal separator),
//   shuffling ("true"|"false"), repeating, volume (0-100),
//   track id, name, artist, album, duration (milliseconds), artwork url
// When Spotify has no current track, the track fields are empty strings.

public enum SpotifyScriptParser {
    public static let separator: Character = "\u{1F}"
    public static let fieldCount = 11

    /// AppleScript source that produces the format above. `tell application "Spotify"` must only run when
    /// Spotify is already running (the caller checks), otherwise AppleScript launches it.
    public static let statusScript = """
        tell application "Spotify"
            set sep to (ASCII character 31)
            set out to ((player state as text) & sep & (player position as text) & sep & (shuffling as text) & sep & (repeating as text) & sep & (sound volume as text))
            try
                set t to current track
                set out to out & sep & (id of t) & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((duration of t) as text) & sep & (artwork url of t)
            on error
                set out to out & sep & "" & sep & "" & sep & "" & sep & "" & sep & "0" & sep & ""
            end try
            return out
        end tell
        """

    public static func parse(_ output: String, now: Date) -> PlaybackSnapshot? {
        let fields = output.split(separator: separator, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard fields.count >= 5 else { return nil }
        let state: PlaybackState
        switch fields[0].lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        default: state = .stopped
        }
        let position = number(fields[1]) ?? 0
        let shuffling = fields[2].lowercased() == "true"
        let repeating = fields[3].lowercased() == "true"
        let volume = Int(number(fields[4]) ?? 100)

        var track: TrackInfo?
        if fields.count >= fieldCount, !fields[5].isEmpty {
            let durationMs = number(fields[9]) ?? 0
            let artwork = fields[10].isEmpty || fields[10] == "missing value" ? nil : fields[10]
            track = TrackInfo(
                id: fields[5], title: fields[6], artist: fields[7], album: fields[8],
                durationSeconds: durationMs / 1000, artworkURL: artwork)
        }
        return PlaybackSnapshot(
            track: track, state: track == nil && state != .playing ? .stopped : state, positionSeconds: position,
            positionTimestamp: now, shuffling: shuffling, repeating: repeating, volume: volume)
    }

    /// Parses AppleScript numbers, which are locale formatted ("12,5" in German locales).
    static func number(_ text: String) -> Double? {
        Double(text) ?? Double(text.replacingOccurrences(of: ",", with: "."))
    }
}
