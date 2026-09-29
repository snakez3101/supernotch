import Foundation

// Owner: media. What the permission UI shows for every state of `MediaPermissionFlow`: one source of truth for
// onboarding (step 3), Settings > Music and the Home tab, so all three always offer the same way out.

/// A button of the permission UI. `MediaModel.perform(_:)` runs it.
public enum MediaPermissionAction: String, Sendable, Equatable, CaseIterable {
    case allow
    case openSpotifyAndAllow
    case tryAgain
    case openSystemSettings
    case resetAndAskAgain
    case copyResetCommand
    case checkAgain

    /// Onboarding and Settings.
    public var title: String {
        switch self {
        case .allow: return "Allow Access to Spotify"
        case .openSpotifyAndAllow: return "Open Spotify and Allow Access"
        case .tryAgain: return "Try Again"
        case .openSystemSettings: return "Open System Settings"
        case .resetAndAskAgain: return "Reset & Ask Again"
        case .copyResetCommand: return "Copy Command"
        case .checkAgain: return "Check Again"
        }
    }

    /// The 200 pt Home column (two small buttons side by side).
    public var shortTitle: String {
        switch self {
        case .allow: return "Allow Access"
        case .openSpotifyAndAllow: return "Open Spotify"
        case .tryAgain: return "Try Again"
        case .openSystemSettings: return "Settings"
        case .resetAndAskAgain: return "Reset & Ask"
        case .copyResetCommand: return "Copy Command"
        case .checkAgain: return "Check Again"
        }
    }
}

/// Colour of the status dot.
public enum MediaPermissionTone: Sendable, Equatable {
    /// Green: allowed.
    case allowed
    /// Orange: not decided yet, or the last request got no answer.
    case attention
    /// Red: denied.
    case blocked
    /// Grey: Spotify is not running.
    case inactive
    /// A spinner instead of the dot.
    case busy
}

public struct MediaPermissionPresentation: Sendable, Equatable {
    public let tone: MediaPermissionTone
    /// Next to the status dot ("Allowed", "Not allowed", …).
    public let status: String
    /// Headline of the Home empty state (one short line).
    public let title: String
    /// One or two sentences for onboarding and Settings.
    public let detail: String?
    /// At most ~60 characters, for the Home column.
    public let compactDetail: String?
    /// SF Symbol for the Home empty state.
    public let symbol: String
    /// Buttons, primary first. Empty while busy or allowed.
    public let actions: [MediaPermissionAction]
    /// Set when the reset could not run: the exact command to paste into Terminal.
    public let terminalCommand: String?

    public var isBusy: Bool { tone == .busy }

    public init(
        tone: MediaPermissionTone, status: String, title: String, detail: String?, compactDetail: String?,
        symbol: String, actions: [MediaPermissionAction], terminalCommand: String? = nil
    ) {
        self.tone = tone
        self.status = status
        self.title = title
        self.detail = detail
        self.compactDetail = compactDetail
        self.symbol = symbol
        self.actions = actions
        self.terminalCommand = terminalCommand
    }

    /// Precedence: a request in progress, then granted, then Spotify not running, then a failed request, then
    /// the stored decision.
    public init(permission: MediaAutomationPermission, request: MediaPermissionRequestState, resetCommand: String) {
        switch request {
        case .waitingForSpotify:
            self.init(
                tone: .busy, status: "Waiting for Spotify…", title: "Waiting for Spotify…",
                detail: "macOS asks as soon as Spotify is ready.",
                compactDetail: "macOS asks as soon as Spotify is ready.",
                symbol: "music.note", actions: [])
            return
        case .asking:
            self.init(
                tone: .busy, status: "Waiting for macOS…", title: "Waiting for macOS…",
                detail: "Answer the macOS dialog \u{201C}SuperNotch wants to control Spotify\u{201D}. "
                    + "It can take a moment to appear.",
                compactDetail: "Answer the dialog \u{201C}SuperNotch wants to control Spotify\u{201D}.",
                symbol: "hourglass", actions: [])
            return
        case .resetting:
            self.init(
                tone: .busy, status: "Resetting…", title: "Resetting access…",
                detail: "Clearing SuperNotch\u{2019}s old Automation decision, then macOS asks again.",
                compactDetail: "Clearing the old decision…", symbol: "arrow.clockwise", actions: [])
            return
        case .idle, .failed:
            break
        }

        switch permission {
        case .granted:
            self.init(
                tone: .allowed, status: "Allowed", title: "Spotify is ready",
                detail: "You can change this in System Settings > Privacy & Security > Automation.",
                compactDetail: nil, symbol: "checkmark.circle", actions: [])
            return
        case .notRunning:
            self.init(
                tone: .inactive, status: "Spotify isn\u{2019}t running", title: "Spotify isn\u{2019}t running",
                detail: "macOS can only ask while Spotify is running.",
                compactDetail: "macOS can only ask while Spotify runs.", symbol: "music.note",
                actions: [.openSpotifyAndAllow])
            return
        case .unknown, .denied:
            break
        }

        if case .failed(let problem) = request {
            switch problem {
            case .resetFailed:
                self.init(
                    tone: .blocked, status: "Not allowed", title: "Couldn\u{2019}t reset access",
                    detail: "SuperNotch couldn\u{2019}t run the reset. Run this command in Terminal, then click "
                        + "Try Again:",
                    compactDetail: "Copy the command, run it in Terminal, then try again.", symbol: "terminal",
                    actions: [.copyResetCommand, .tryAgain, .openSystemSettings], terminalCommand: resetCommand)
            case .noAnswer:
                self.init(
                    tone: .attention, status: "macOS didn\u{2019}t answer", title: "macOS didn\u{2019}t answer",
                    detail: "The permission dialog never came back. Try again; if no dialog appears, reset "
                        + "SuperNotch\u{2019}s Automation permission and ask again.",
                    compactDetail: "The permission dialog never came back.", symbol: "exclamationmark.triangle",
                    actions: [.tryAgain, .resetAndAskAgain, .openSystemSettings])
            case .couldNotAsk(let status):
                self.init(
                    tone: .attention, status: "Couldn\u{2019}t ask macOS", title: "Couldn\u{2019}t ask macOS",
                    detail: "macOS couldn\u{2019}t show the permission dialog (error \(status)). Try again, or reset "
                        + "SuperNotch\u{2019}s Automation permission and ask again.",
                    compactDetail: "macOS couldn\u{2019}t show the dialog (error \(status)).",
                    symbol: "exclamationmark.triangle", actions: [.tryAgain, .resetAndAskAgain, .openSystemSettings])
            }
            return
        }

        if permission == .denied {
            self.init(
                tone: .blocked, status: "Not allowed", title: "Spotify access is off",
                detail: "Turn on Spotify for SuperNotch in System Settings > Privacy & Security > Automation, or "
                    + "reset and ask again. If no dialog appears after a reset, quit and reopen SuperNotch.",
                compactDetail: "Allow it in System Settings, or reset and ask again.", symbol: "lock.fill",
                actions: [.openSystemSettings, .resetAndAskAgain, .checkAgain])
            return
        }

        self.init(
            tone: .attention, status: "Not allowed yet", title: "Allow Spotify control",
            detail: "macOS asks once, and only while Spotify is running. No Spotify login needed.",
            compactDetail: "macOS asks once. No Spotify login needed.", symbol: "music.note", actions: [.allow])
    }
}
