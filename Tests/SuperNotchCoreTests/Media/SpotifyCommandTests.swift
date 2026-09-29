// Owner: media. Command scripts and Automation error mapping.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("SpotifyCommand")
struct SpotifyCommandTests {
    @Test func scriptsNeverLaunchSpotify() {
        for command in [SpotifyCommand.playPause, .next, .previous, .seek(seconds: 12)] {
            let script = command.script
            #expect(script.contains("if application id \"com.spotify.client\" is running then"))
            #expect(script.contains("with timeout of 5 seconds"))
            #expect(!script.contains("tell application \"Spotify\""))
        }
    }

    @Test func commandBodies() {
        #expect(SpotifyCommand.playPause.script.contains("playpause"))
        #expect(SpotifyCommand.next.script.contains("next track"))
        #expect(SpotifyCommand.previous.script.contains("previous track"))
    }

    @Test func seekUsesLocaleIndependentIntegerMilliseconds() {
        #expect(SpotifyCommand.seek(seconds: 12.3456).script.contains("set player position to (12346 / 1000)"))
        #expect(SpotifyCommand.seek(seconds: 0).script.contains("(0 / 1000)"))
        #expect(SpotifyCommand.seek(seconds: -3).script.contains("(0 / 1000)"))
        #expect(SpotifyCommand.seek(seconds: .nan).script.contains("(0 / 1000)"))
        #expect(SpotifyCommand.seek(seconds: .infinity).script.contains("(0 / 1000)"))
        #expect(SpotifyCommand.seek(seconds: 1_000_000).script.contains("(86400000 / 1000)"))
    }

    @Test func permissionFromDeterminePermissionStatus() {
        #expect(MediaAutomationPermission(osStatus: 0) == .granted)
        #expect(MediaAutomationPermission(osStatus: -1743) == .denied)
        #expect(MediaAutomationPermission(osStatus: -1744) == .unknown)
        #expect(MediaAutomationPermission(osStatus: -600) == .notRunning)
        #expect(MediaAutomationPermission(osStatus: -50) == .unknown)
    }

    @Test func appleScriptErrorClassification() {
        #expect(SpotifyScriptFailure(appleScriptErrorNumber: -1743) == .permissionDenied)
        #expect(SpotifyScriptFailure(appleScriptErrorNumber: -1744) == .consentRequired)
        #expect(SpotifyScriptFailure(appleScriptErrorNumber: -1713) == .consentRequired)
        #expect(SpotifyScriptFailure(appleScriptErrorNumber: -600) == .notRunning)
        #expect(SpotifyScriptFailure(appleScriptErrorNumber: -609) == .notRunning)
        #expect(SpotifyScriptFailure(appleScriptErrorNumber: -1712) == .timedOut)
        #expect(SpotifyScriptFailure(appleScriptErrorNumber: -2741) == .other(-2741))

        #expect(SpotifyScriptFailure.permissionDenied.impliedPermission == .denied)
        #expect(SpotifyScriptFailure.consentRequired.impliedPermission == .unknown)
        #expect(SpotifyScriptFailure.notRunning.impliedPermission == .notRunning)
        #expect(SpotifyScriptFailure.timedOut.impliedPermission == nil)
        #expect(SpotifyScriptFailure.other(1).impliedPermission == nil)
    }

    @Test func settingsDeepLinks() {
        #expect(
            MediaSystemSettingsLink.automation
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")
        #expect(
            MediaSystemSettingsLink.legacyAutomation
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        #expect(
            MediaSystemSettingsLink.automationCandidates
                == [MediaSystemSettingsLink.automation, MediaSystemSettingsLink.legacyAutomation])
        for link in MediaSystemSettingsLink.automationCandidates {
            #expect(URL(string: link) != nil)
        }
        #expect(MediaSystemSettingsLink.systemSettingsBundleID == "com.apple.systempreferences")
    }
}
