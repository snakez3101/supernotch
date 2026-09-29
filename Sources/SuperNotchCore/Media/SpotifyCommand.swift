import Foundation

// Owner: media. AppleScript for the playback commands (SPEC §A.5) plus the mapping from AppleScript /
// TCC error numbers to the Automation permission states of `MediaModel.automationPermission` (SPEC §D.4).

public enum SpotifyCommand: Sendable, Equatable {
    case playPause
    case next
    case previous
    case seek(seconds: Double)

    /// A complete script. It re-checks `is running` (a bare `tell application` would launch Spotify) and is
    /// bounded by a timeout so a hung Spotify can never block the serial AppleScript queue for minutes.
    public var script: String {
        let body: String
        switch self {
        case .playPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .seek(let seconds): body = "set player position to (\(Self.milliseconds(seconds)) / 1000)"
        }
        return """
            with timeout of 5 seconds
                if application id "com.spotify.client" is running then
                    tell application id "com.spotify.client"
                        \(body)
                    end tell
                end if
            end timeout
            """
    }

    /// Whole milliseconds, clamped to 0…24 h. Integer arithmetic keeps the script independent of the
    /// user's decimal separator.
    static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int((min(max(seconds, 0), 86_400) * 1000).rounded())
    }
}

/// Automation (Apple Events / TCC) permission for controlling Spotify. Frozen cases (SPEC §D.4).
public enum MediaAutomationPermission: String, Sendable, Equatable, CaseIterable {
    case unknown
    case granted
    case denied
    case notRunning

    /// Maps `AEDeterminePermissionToAutomateTarget` results: noErr granted, -1743 denied, -1744 would need
    /// consent (never asked), -600 target not running. Anything else stays unknown. The connect flow uses the
    /// stricter rules of `MediaPermissionFlow` / `merging(silent:into:)` instead.
    public init(osStatus: Int32) {
        switch osStatus {
        case 0: self = .granted
        case -1743: self = .denied
        case -600: self = .notRunning
        default: self = .unknown
        }
    }
}

/// Classification of an `NSAppleScript` error number.
public enum SpotifyScriptFailure: Sendable, Equatable {
    /// errAEEventNotPermitted (-1743): the user denied Automation for Spotify.
    case permissionDenied
    /// errAEEventWouldRequireUserConsent (-1744) / errAENoUserInteraction (-1713): never asked yet.
    case consentRequired
    /// procNotFound (-600) / connectionInvalid (-609): Spotify is not running (any more).
    case notRunning
    /// errAETimeout (-1712)
    case timedOut
    case other(Int)

    public init(appleScriptErrorNumber number: Int) {
        switch number {
        case -1743: self = .permissionDenied
        case -1744, -1713: self = .consentRequired
        case -600, -609: self = .notRunning
        case -1712: self = .timedOut
        default: self = .other(number)
        }
    }

    /// The permission state this failure implies, if any.
    public var impliedPermission: MediaAutomationPermission? {
        switch self {
        case .permissionDenied: return .denied
        case .consentRequired: return .unknown
        case .notRunning: return .notRunning
        case .timedOut, .other: return nil
        }
    }
}

/// System Settings deep links for Privacy & Security > Automation (SPEC §A.5), tried in this order.
public enum MediaSystemSettingsLink {
    /// macOS 13+ (System Settings).
    public static let automation =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
    /// The System Preferences era link, used when the modern one does not open.
    public static let legacyAutomation = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    public static let automationCandidates = [automation, legacyAutomation]
    /// Last resort: open System Settings itself.
    public static let systemSettingsBundleID = "com.apple.systempreferences"
}
