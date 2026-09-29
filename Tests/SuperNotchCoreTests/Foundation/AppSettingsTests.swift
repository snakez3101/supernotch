// Owner: FOUNDATION.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("AppSettings")
struct AppSettingsTests {
    @Test func defaultsMatchRequirements() {
        let settings = AppSettings()
        #expect(settings.hoverOpenDelay == 0.15)
        #expect(settings.doneAutoCollapse == 4)
        #expect(settings.retention == .sevenDays)
        #expect(settings.clipboardLimit == 200)
        #expect(settings.toggleNotchHotkey == .toggleNotchDefault)
        #expect(settings.clipboardHotkey == .clipboardHistoryDefault)
        #expect(settings.usageWarningThreshold == 0.8)
    }

    @Test func roundTrip() throws {
        var settings = AppSettings()
        settings.closedMode = .invisible
        settings.clipboardHotkey = nil
        settings.claudeConfigDirOverride = "~/work/.claude"
        let decoded = AppSettings.decode(from: settings.encoded())
        #expect(decoded == settings)
        #expect(decoded.clipboardHotkey == nil)
    }

    @Test func tolerantDecodingKeepsDefaultsForMissingAndMalformedKeys() {
        let json = #"{"closedMode":"invisible","hoverOpenDelay":"fast","unknownFutureKey":42}"#
        let decoded = AppSettings.decode(from: Data(json.utf8))
        #expect(decoded.closedMode == .invisible)
        #expect(decoded.hoverOpenDelay == 0.15)
        #expect(decoded.popupOnDone == true)
    }

    @Test func garbageFallsBackToDefaults() {
        #expect(AppSettings.decode(from: Data("nope".utf8)) == AppSettings())
        #expect(AppSettings.decode(from: nil) == AppSettings())
    }

    @Test func normalizeClamps() {
        var settings = AppSettings()
        settings.clipboardLimit = 5
        settings.hoverOpenDelay = -1
        settings.claudeConfigDirOverride = "  "
        settings.normalize()
        #expect(settings.clipboardLimit == 20)
        #expect(settings.hoverOpenDelay == 0)
        #expect(settings.claudeConfigDirOverride == nil)
    }
}

@Suite("KeyCombo")
struct KeyComboTests {
    @Test func descriptions() {
        #expect(KeyCombo.toggleNotchDefault.description == "⌥⌘N")
        #expect(KeyCombo.clipboardHistoryDefault.description == "⌥⌘V")
        #expect(KeyCombo(keyCode: 49, carbonModifiers: KeyCombo.controlKey | KeyCombo.shiftKey).description == "⌃⇧Space")
    }

    @Test func validity() {
        #expect(KeyCombo.toggleNotchDefault.isValidGlobalHotkey)
        #expect(!KeyCombo(keyCode: 9, carbonModifiers: KeyCombo.shiftKey).isValidGlobalHotkey)
    }
}

@Suite("Paths")
struct PathsTests {
    @Test func appSupportLayout() {
        let paths = SuperNotchPaths(homeDirectory: "/Users/me/")
        #expect(paths.appSupport == "/Users/me/Library/Application Support/SuperNotch")
        #expect(paths.hookBinary == "/Users/me/Library/Application Support/SuperNotch/bin/supernotch-hook")
        #expect(paths.hookBinary.contains(HookInstallSpec.defaultMarker))
        #expect(paths.shelfIndex.hasSuffix("/Shelf/items.json"))
    }

    @Test func socketPathFallsBackWhenTooLong() {
        let short = SocketPath.resolve(homeDirectory: "/Users/me", uid: 501, environment: [:])
        #expect(short == "/Users/me/Library/Application Support/SuperNotch/hook.sock")
        let longHome = "/Users/" + String(repeating: "x", count: 80)
        #expect(SocketPath.resolve(homeDirectory: longHome, uid: 501, environment: [:]) == "/tmp/supernotch-501.sock")
        #expect(SocketPath.resolve(homeDirectory: "/Users/me", uid: 501, environment: ["SUPERNOTCH_SOCKET": "/x.sock"])
            == "/x.sock")
    }

    @Test func claudeConfigResolution() {
        #expect(ClaudePaths.resolve(environment: [:], homeDirectory: "/h").settingsFile == "/h/.claude/settings.json")
        #expect(
            ClaudePaths.resolve(environment: ["CLAUDE_CONFIG_DIR": "~/cc"], homeDirectory: "/h").configDirectory
                == "/h/cc")
        #expect(
            ClaudePaths.resolve(environment: ["CLAUDE_CONFIG_DIR": "/e"], homeDirectory: "/h", override: "/o")
                .configDirectory == "/o")
    }
}
