import Foundation

// Owner: media. The Automation (TCC) connect flow for Spotify as pure logic (SPEC §A.5, §A.10, §A.11):
// status numbers → permission, the request state machine (waiting for Spotify, asking, resetting, failed),
// the "never downgrade an observed denial" rule, timeouts, launch readiness, the tccutil reset command and the
// four-char codes of the harmless Apple Event that raises the system prompt.

/// Apple Event / TCC status numbers the flow understands.
public enum MediaAppleEventStatus {
    public static let noErr: Int32 = 0
    /// procNotFound: the target is not running.
    public static let processNotFound: Int32 = -600
    /// connectionInvalid: the target quit while we talked to it.
    public static let connectionInvalid: Int32 = -609
    /// errAETimeout: no reply in time (the prompt may still be on screen).
    public static let timeout: Int32 = -1712
    /// errAENoUserInteraction: interaction was needed but not allowed.
    public static let noUserInteraction: Int32 = -1713
    /// errAEEventNotPermitted: the user said no (or turned the switch off).
    public static let notPermitted: Int32 = -1743
    /// errAEEventWouldRequireUserConsent: no decision is stored and macOS was not allowed to (or could not) ask.
    public static let wouldRequireConsent: Int32 = -1744
}

/// Why a permission request did not end with a decision.
public enum MediaPermissionProblem: Sendable, Equatable {
    /// macOS did not answer in time: the TCC call hung (a known macOS bug) or nobody answered the dialog.
    case noAnswer
    /// macOS could not show the dialog (-1744, -1713) or failed with an unexpected status.
    case couldNotAsk(status: Int32)
    /// `tccutil reset` could not run or failed: the user has to run the command in Terminal.
    case resetFailed
}

/// What the connect flow is doing right now.
public enum MediaPermissionRequestState: Sendable, Equatable {
    case idle
    /// Spotify is launching (we opened it) or just launched: we ask once it is ready.
    case waitingForSpotify
    /// The real Apple Event is in flight; the system dialog may be on screen.
    case asking
    /// `tccutil reset AppleEvents <our bundle id>` is running.
    case resetting
    /// The last request ended without a decision.
    case failed(MediaPermissionProblem)

    /// A request is in progress (show a spinner, no buttons). Every busy state ends by itself (timeouts).
    public var isBusy: Bool {
        switch self {
        case .waitingForSpotify, .asking, .resetting: return true
        case .idle, .failed: return false
        }
    }
}

/// How one request (the real Apple Event) ended.
public enum MediaPermissionAskOutcome: Sendable, Equatable {
    case granted
    case denied
    case notRunning
    case problem(MediaPermissionProblem)

    /// Success → granted, -1743 → denied, -600/-609 → not running, -1712 or our own timeout → no answer, anything
    /// else (-1744, -1713, unexpected errors) → could not ask.
    public init(_ result: MediaPermissionCallResult) {
        guard case .status(let status) = result else {
            self = .problem(.noAnswer)
            return
        }
        switch status {
        case MediaAppleEventStatus.noErr: self = .granted
        case MediaAppleEventStatus.notPermitted: self = .denied
        case MediaAppleEventStatus.processNotFound, MediaAppleEventStatus.connectionInvalid: self = .notRunning
        case MediaAppleEventStatus.timeout: self = .problem(.noAnswer)
        default: self = .problem(.couldNotAsk(status: status))
        }
    }
}

extension MediaAutomationPermission {
    /// Merges a SILENT observation (`AEDeterminePermissionToAutomateTarget` with askUser false, or the error of a
    /// status script) into `current`.
    ///
    /// * 0 → granted, -1743 → denied, -600/-609 → not running.
    /// * -1744/-1713 ("no decision stored") → unknown, but it never replaces a denial we have observed: a stale
    ///   or mismatching TCC record (ad-hoc signed builds change identity with every build) can read as
    ///   "consent needed" while macOS still refuses the real events.
    /// * A timeout or an unexpected status says nothing reliable: `current` stays.
    public static func merging(silent result: MediaPermissionCallResult, into current: MediaAutomationPermission)
        -> MediaAutomationPermission
    {
        guard case .status(let status) = result else { return current }
        switch status {
        case MediaAppleEventStatus.noErr: return .granted
        case MediaAppleEventStatus.notPermitted: return .denied
        case MediaAppleEventStatus.processNotFound, MediaAppleEventStatus.connectionInvalid: return .notRunning
        case MediaAppleEventStatus.wouldRequireConsent, MediaAppleEventStatus.noUserInteraction:
            return current == .denied ? .denied : .unknown
        default: return current
        }
    }
}

/// The Automation permission plus the request in progress. `MediaModel` keeps one and mutates it only through
/// these transitions, so the rules are tested on Linux.
public struct MediaPermissionFlow: Sendable, Equatable {
    public private(set) var permission: MediaAutomationPermission
    public private(set) var request: MediaPermissionRequestState

    public init(permission: MediaAutomationPermission = .unknown, request: MediaPermissionRequestState = .idle) {
        self.permission = permission
        self.request = request
    }

    // MARK: Spotify running state

    public mutating func spotifyDidStart() {
        if permission == .notRunning { permission = .unknown }
    }

    /// A pending request keeps waiting: we may have launched Spotify ourselves.
    public mutating func spotifyDidStop() {
        permission = .notRunning
    }

    // MARK: Silent observations

    /// A silent check or a status script result. See `MediaAutomationPermission.merging(silent:into:)`.
    public mutating func applyObserved(_ result: MediaPermissionCallResult) {
        permission = MediaAutomationPermission.merging(silent: result, into: permission)
        if case .status(let status) = result { endFailure(ifDecidedBy: status) }
    }

    /// The real answer to a request we already stopped waiting for (the user answered the dialog late). Only a
    /// decision counts; anything else leaves the state alone.
    public mutating func applyLateAnswer(_ status: Int32) {
        switch MediaPermissionAskOutcome(.status(status)) {
        case .granted: permission = .granted
        case .denied: permission = .denied
        case .notRunning, .problem: return
        }
        endFailure(ifDecidedBy: status)
    }

    // MARK: Asking

    /// "Allow Access" / "Try Again". False while another request is in progress.
    @discardableResult
    public mutating func beginWaitingForSpotify() -> Bool {
        guard !request.isBusy else { return false }
        request = .waitingForSpotify
        return true
    }

    /// Spotify did not come up (not installed, launch failed): back to the buttons.
    public mutating func cancelWaiting() {
        if request == .waitingForSpotify { request = .idle }
    }

    /// Spotify is ready: send the real Apple Event. False while asking or resetting.
    @discardableResult
    public mutating func beginAsking() -> Bool {
        switch request {
        case .asking, .resetting: return false
        case .idle, .waitingForSpotify, .failed:
            request = .asking
            return true
        }
    }

    /// The real Apple Event returned (or timed out). If the request was cancelled meanwhile (feature switched
    /// off), only a decision is kept.
    @discardableResult
    public mutating func finishAsking(_ result: MediaPermissionCallResult) -> MediaPermissionAskOutcome {
        let outcome = MediaPermissionAskOutcome(result)
        guard request == .asking else {
            if case .status(let status) = result { applyLateAnswer(status) }
            return outcome
        }
        switch outcome {
        case .granted:
            permission = .granted
            request = .idle
        case .denied:
            permission = .denied
            request = .idle
        case .notRunning:
            permission = .notRunning
            request = .idle
        case .problem(let problem):
            request = .failed(problem)
            if permission == .notRunning { permission = .unknown }
        }
        return outcome
    }

    // MARK: Reset (tccutil)

    /// "Reset & Ask Again". False while another request is in progress.
    @discardableResult
    public mutating func beginResetting() -> Bool {
        guard !request.isBusy else { return false }
        request = .resetting
        return true
    }

    /// After a successful reset no decision is stored any more; the caller asks again right away.
    public mutating func finishResetting(succeeded: Bool) {
        guard request == .resetting else { return }
        if succeeded {
            request = .idle
            if permission != .notRunning { permission = .unknown }
        } else {
            request = .failed(.resetFailed)
        }
    }

    /// The feature was switched off: forget the request in progress (a late result can still record a decision).
    public mutating func cancelRequest() {
        request = .idle
    }

    // MARK: Helpers

    /// Only an actual decision (0 or -1743 just observed) ends a failed request; a denial that is merely kept
    /// from before (a silent -1744) must not hide "macOS didn't answer". A failed reset stays visible while macOS
    /// still says no: its Terminal command is the way out.
    private mutating func endFailure(ifDecidedBy status: Int32) {
        guard case .failed(let problem) = request else { return }
        switch status {
        case MediaAppleEventStatus.noErr: request = .idle
        case MediaAppleEventStatus.notPermitted: if problem != .resetFailed { request = .idle }
        default: break
        }
    }
}

/// Timeouts of the connect flow, in seconds.
public enum MediaPermissionTimeouts {
    /// Waiting for the answer to a real request. Long: the user may be reading the dialog.
    public static let ask: TimeInterval = 45
    /// The probe Apple Event's own reply timeout; shorter than `ask`, so the event normally returns first.
    public static let appleEvent: TimeInterval = 40
    /// Silent status checks.
    public static let silentCheck: TimeInterval = 3
    /// `tccutil reset`.
    public static let reset: TimeInterval = 15
    /// How long "Allow Access" waits for a Spotify we launched to appear.
    public static let spotifyLaunch: TimeInterval = 60
    /// After a request without an answer, check silently this often, this many times (a late answer to a
    /// still-open dialog shows up without another click).
    public static let followUpInterval: TimeInterval = 5
    public static let followUpChecks = 6
}

/// Spotify's Apple Event interface is not ready the moment its process appears.
public enum SpotifyLaunchReadiness {
    /// Ask after Spotify's first PlaybackStateChanged notification or this long after launch, whichever is first.
    public static let settleDelay: TimeInterval = 4

    /// Seconds to wait before sending the request. 0 when Spotify has been up for a while (or we do not know
    /// when it launched) or it already posted a playback notification.
    public static func delayBeforeAsking(launchedAt: Date?, sawPlaybackNotification: Bool, now: Date)
        -> TimeInterval
    {
        guard !sawPlaybackNotification, let launchedAt else { return 0 }
        let age = now.timeIntervalSince(launchedAt)
        guard age >= 0 else { return settleDelay }  // clock moved backwards: be safe
        return max(0, settleDelay - age)
    }
}

/// `tccutil reset AppleEvents <bundle id>` clears the Automation decisions SuperNotch made as the SENDER, so the
/// next request shows the dialog again. It needs no admin rights: AppleEvents decisions live in the user's own
/// TCC database, which the per-user tccd resets on request (`man tccutil`). If it fails anyway, the UI shows the
/// exact command for Terminal.
public enum MediaPermissionReset {
    public static let executablePath = "/usr/bin/tccutil"
    /// Used when the running binary has no bundle id (e.g. `swift run`).
    public static let fallbackBundleID = "io.github.snakez3101.supernotch"

    public static func arguments(bundleID: String) -> [String] {
        ["reset", "AppleEvents", sanitizedBundleID(bundleID)]
    }

    public static func terminalCommand(bundleID: String?) -> String {
        "tccutil reset AppleEvents \(sanitizedBundleID(bundleID))"
    }

    /// A reverse-DNS id (letters, digits, "-", "."), otherwise our own id: the value ends up in a command line.
    public static func sanitizedBundleID(_ candidate: String?) -> String {
        guard let candidate, !candidate.isEmpty, candidate.count <= 255,
            candidate.unicodeScalars.allSatisfy({ allowedScalars.contains($0) }),
            !candidate.hasPrefix("."), !candidate.hasPrefix("-")
        else { return fallbackBundleID }
        return candidate
    }

    private static let allowedScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
}

/// Four-char codes of the probe: `get name of application id "com.spotify.client"` as a raw Apple Event
/// ('core'/'getd' with a property specifier for 'pnam'). Harmless (read-only, no UI in Spotify), and as a REAL
/// event it makes tccd show "SuperNotch wants to control Spotify" when no decision is stored yet.
public enum SpotifyPermissionProbe {
    public static let eventClass = fourCharCode("core")  // kAECoreSuite
    public static let eventID = fourCharCode("getd")  // kAEGetData
    public static let keyDirectObject = fourCharCode("----")
    public static let keyErrorNumber = fourCharCode("errn")
    public static let typeObjectSpecifier = fourCharCode("obj ")
    public static let keyDesiredClass = fourCharCode("want")  // keyAEDesiredClass
    public static let keyContainer = fourCharCode("from")  // keyAEContainer
    public static let keyForm = fourCharCode("form")  // keyAEKeyForm
    public static let keyData = fourCharCode("seld")  // keyAEKeyData
    public static let classProperty = fourCharCode("prop")  // cProperty / typeProperty
    public static let formPropertyID = fourCharCode("prop")
    public static let propertyName = fourCharCode("pnam")  // pName

    /// Big-endian packing of four ASCII characters (`"core"` → 0x636F7265). Anything else → 0.
    public static func fourCharCode(_ string: String) -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return 0 }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
