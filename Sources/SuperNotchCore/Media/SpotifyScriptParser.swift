import Foundation

// Owner: media. Signature FROZEN (SPEC §D.3): `separator`, `fieldCount`, `statusScript`, `parse(_:now:)`.
// Parses the output of the single batched AppleScript run by SpotifyController (SPEC §A.5, §F.1).
//
// Contract with SpotifyController: the AppleScript returns ONE string whose fields are joined by the
// ASCII unit separator (U+001F), in exactly this order:
//   state ("playing"|"paused"|"stopped"), position (seconds, may use "," as decimal separator),
//   shuffling ("true"|"false"), repeating, volume (0-100),
//   track id, name, artist, album, duration (milliseconds), artwork url
// When Spotify has no current track, the track fields are empty strings. When Spotify is not running the
// script returns the sentinel `notRunningSentinel` (it never launches Spotify, see below).
//
// Hardening notes (all covered by tests):
//  * every property is read inside its own `try`, so one missing value (`missing value` artwork on ads and
//    local files, an unset position) cannot throw away the whole snapshot;
//  * AppleScript prints numbers in the user's locale ("12,5"), so the number parser accepts both separators;
//  * enum values that lost their terminology come back as raw four-char codes («constant ****kPSP»);
//  * unknown / extra / missing fields are tolerated, garbage returns nil, nothing here can trap.

public enum SpotifyScriptResult: Sendable, Equatable {
    /// The script ran but Spotify is not running (never launches it).
    case notRunning
    case snapshot(PlaybackSnapshot)
    /// Empty or unrecognisable output.
    case invalid
}

public enum SpotifyScriptParser {
    public static let separator: Character = "\u{1F}"
    public static let fieldCount = 11
    /// Returned by `statusScript` when Spotify is not running.
    public static let notRunningSentinel = "NOT_RUNNING"
    public static let bundleIdentifier = "com.spotify.client"

    /// AppleScript source that produces the format above. The script itself checks `is running` (checking
    /// inside the script is not atomic, so the caller ALSO checks `NSRunningApplication` first): a bare
    /// `tell application "Spotify"` would launch Spotify.
    ///
    /// Robustness rules:
    ///  * The separator is built OUTSIDE the `tell` block with the built-in `character id` (no scripting
    ///    addition, no extra Apple Event to Spotify).
    ///  * Every property is read in its own `try … on error` with a default, so one failing term (ads, local
    ///    files, a term Spotify stops implementing) never loses the others.
    ///  * Variable names are prefixed with `r` so none of them can collide with a term of Spotify's scripting
    ///    dictionary (`name`, `id`, `artist`, ...) inside the `tell` block.
    ///  * A term that is missing from Spotify's dictionary altogether makes the script fail to COMPILE, which no
    ///    `try` can catch; the caller then falls back to `coreStatusScript`.
    public static let statusScript = """
        with timeout of 5 seconds
            if application id "com.spotify.client" is not running then return "NOT_RUNNING"
            set sep to character id 31
            set rState to "stopped"
            set rPos to "0"
            set rShuf to "false"
            set rRep to "false"
            set rVol to "100"
            set rId to ""
            set rName to ""
            set rArtist to ""
            set rAlbum to ""
            set rDur to "0"
            set rArt to ""
            set trk to missing value
            tell application id "com.spotify.client"
                try
                    set rState to (player state as text)
                on error
                    set rState to "stopped"
                end try
                try
                    set rPos to (player position as text)
                on error
                    set rPos to "0"
                end try
                try
                    set rShuf to (shuffling as text)
                on error
                    set rShuf to "false"
                end try
                try
                    set rRep to (repeating as text)
                on error
                    set rRep to "false"
                end try
                try
                    set rVol to (sound volume as text)
                on error
                    set rVol to "100"
                end try
                try
                    set trk to current track
                on error
                    set trk to missing value
                end try
                try
                    set rId to (id of trk as text)
                on error
                    set rId to ""
                end try
                try
                    set rName to (name of trk as text)
                on error
                    set rName to ""
                end try
                try
                    set rArtist to (artist of trk as text)
                on error
                    set rArtist to ""
                end try
                try
                    set rAlbum to (album of trk as text)
                on error
                    set rAlbum to ""
                end try
                try
                    set rDur to (duration of trk as text)
                on error
                    set rDur to "0"
                end try
                try
                    set rArt to (artwork url of trk as text)
                on error
                    set rArt to ""
                end try
            end tell
            return rState & sep & rPos & sep & rShuf & sep & rRep & sep & rVol & sep & rId & sep & rName & sep & rArtist & sep & rAlbum & sep & rDur & sep & rArt
        end timeout
        """

    /// Fallback that reads only the core terms (`player state`, `player position` and `id`, `name`, `artist`,
    /// `album`, `duration` of `current track`), for a Spotify build whose dictionary lacks an optional term and
    /// so makes `statusScript` fail to compile. Same output format: shuffle, repeat and volume come back as
    /// their defaults and the artwork URL is empty (the oEmbed cover fallback takes over).
    public static let coreStatusScript = """
        with timeout of 5 seconds
            if application id "com.spotify.client" is not running then return "NOT_RUNNING"
            set sep to character id 31
            set rState to "stopped"
            set rPos to "0"
            set rId to ""
            set rName to ""
            set rArtist to ""
            set rAlbum to ""
            set rDur to "0"
            set trk to missing value
            tell application id "com.spotify.client"
                try
                    set rState to (player state as text)
                on error
                    set rState to "stopped"
                end try
                try
                    set rPos to (player position as text)
                on error
                    set rPos to "0"
                end try
                try
                    set trk to current track
                on error
                    set trk to missing value
                end try
                try
                    set rId to (id of trk as text)
                on error
                    set rId to ""
                end try
                try
                    set rName to (name of trk as text)
                on error
                    set rName to ""
                end try
                try
                    set rArtist to (artist of trk as text)
                on error
                    set rArtist to ""
                end try
                try
                    set rAlbum to (album of trk as text)
                on error
                    set rAlbum to ""
                end try
                try
                    set rDur to (duration of trk as text)
                on error
                    set rDur to "0"
                end try
            end tell
            return rState & sep & rPos & sep & "false" & sep & "false" & sep & "100" & sep & rId & sep & rName & sep & rArtist & sep & rAlbum & sep & rDur & sep & ""
        end timeout
        """

    /// Frozen entry point: nil when the output cannot be a status line (including "not running").
    public static func parse(_ output: String, now: Date) -> PlaybackSnapshot? {
        if case .snapshot(let snapshot) = parseResult(output, now: now) { return snapshot }
        return nil
    }

    /// Full result including the not-running sentinel.
    public static func parseResult(_ output: String, now: Date) -> SpotifyScriptResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .invalid }
        if trimmed == notRunningSentinel { return .notRunning }

        let fields = output.split(separator: separator, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard fields.count >= 5 else { return .invalid }

        let state = playbackState(fields[0])
        let position = max(0, number(fields[1]) ?? 0)
        let shuffling = fields[2].lowercased() == "true"
        let repeating = fields[3].lowercased() == "true"
        let volume = clampedVolume(number(fields[4]))

        var track: TrackInfo?
        if fields.count >= fieldCount, !fields[5].isEmpty {
            let durationMs = max(0, number(fields[9]) ?? 0)
            track = TrackInfo(
                id: fields[5], title: fields[6], artist: fields[7], album: fields[8],
                durationSeconds: durationMs / 1000, artworkURL: artworkURL(fields[10]))
        }
        let snapshot = PlaybackSnapshot(
            track: track,
            // No track and not playing means "nothing to show", whatever Spotify calls it.
            state: track == nil && state != .playing ? .stopped : state,
            positionSeconds: position, positionTimestamp: now, shuffling: shuffling, repeating: repeating,
            volume: volume)
        return .snapshot(snapshot)
    }

    // MARK: Field decoding

    /// "playing" / "paused" / "stopped", or the raw enum codes AppleScript prints when terminology is missing.
    static func playbackState(_ raw: String) -> PlaybackState {
        // Raw codes are case-sensitive (kPSP playing, kPSp paused, kPSS stopped): check before lowercasing.
        if raw.contains("kPSP") { return .playing }
        if raw.contains("kPSp") { return .paused }
        if raw.contains("kPSS") { return .stopped }
        switch raw.lowercased() {
        case "playing": return .playing
        case "paused": return .paused
        default: return .stopped
        }
    }

    static func artworkURL(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "missing value" { return nil }
        return value
    }

    static func clampedVolume(_ value: Double?) -> Int {
        guard let value else { return 100 }
        return Int(min(max(value.rounded(), 0), 100))
    }

    /// Parses AppleScript numbers, which are locale formatted ("12,5" in German locales) and may use exponent
    /// notation ("1.5E+2"). When both separators appear the later one is the decimal separator ("1.234,5" and
    /// "1,234.5" are both 1234.5). Non-finite values are rejected.
    static func number(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let parsed = Double(value), parsed.isFinite { return parsed }
        if let comma = value.lastIndex(of: ","), let dot = value.lastIndex(of: ".") {
            if comma > dot {
                value = value.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                value = value.replacingOccurrences(of: ",", with: "")
            }
        } else {
            value = value.replacingOccurrences(of: ",", with: ".")
        }
        guard let parsed = Double(value), parsed.isFinite else { return nil }
        return parsed
    }
}
