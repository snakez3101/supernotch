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
    public static let statusScript = makeStatusScript(includeOptionalTerms: true)

    /// Fallback that reads only the terms every Spotify version has had (`player state`, `player position` and
    /// `id`, `name`, `artist`, `album`, `duration` of `current track`). Same output format; shuffle, repeat and
    /// volume come back as their defaults and the artwork URL is empty (the oEmbed cover fallback takes over).
    public static let coreStatusScript = makeStatusScript(includeOptionalTerms: false)

    static func makeStatusScript(includeOptionalTerms: Bool) -> String {
        func read(_ variable: String, _ expression: String) -> String {
            """
                    try
                        set \(variable) to (\(expression)) as text
                    on error
                    end try

            """
        }
        var reads = read("rState", "player state") + read("rPos", "player position")
        if includeOptionalTerms {
            reads += read("rShuf", "shuffling") + read("rRep", "repeating") + read("rVol", "sound volume")
        }
        reads += """
                    set trk to missing value
                    try
                        set trk to current track
                    on error
                    end try
                    if trk is not missing value then

            """
        var trackReads = read("rId", "id of trk") + read("rName", "name of trk") + read("rArtist", "artist of trk")
            + read("rAlbum", "album of trk") + read("rDur", "duration of trk")
        if includeOptionalTerms { trackReads += read("rArt", "artwork url of trk") }
        // Indent the track reads one level deeper (inside the `if`).
        reads += trackReads.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    " + $0 }.joined(separator: "\n")
        reads += """
                    end if

            """
        return """
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
                tell application id "com.spotify.client"
            \(reads)    end tell
                return rState & sep & rPos & sep & rShuf & sep & rRep & sep & rVol & sep & rId & sep & rName & sep & rArtist & sep & rAlbum & sep & rDur & sep & rArt
            end timeout
            """
    }

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
