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
        #expect(settings.clipboardLimit == 50)
        #expect(settings.hoverOpenDelay == 0)
        #expect(settings.claudeConfigDirOverride == nil)
        settings.clipboardLimit = 5000
        settings.usageWarningThreshold = 0.1
        settings.normalize()
        #expect(settings.clipboardLimit == 1000)
        #expect(settings.usageWarningThreshold == 0.5)
    }

    @Test func decodingNormalizes() {
        let json = #"{"clipboardLimit":3,"doneAutoCollapse":0}"#
        let decoded = AppSettings.decode(from: Data(json.utf8))
        #expect(decoded.clipboardLimit == AppSettings.clipboardLimitRange.lowerBound)
        #expect(decoded.doneAutoCollapse == 1)
    }

    @Test func disabledHotkeyIsNotResurrectedByDefaults() {
        var settings = AppSettings()
        settings.toggleNotchHotkey = nil
        let decoded = AppSettings.decode(from: settings.encoded())
        #expect(decoded.toggleNotchHotkey == nil)
        #expect(decoded.clipboardHotkey == .clipboardHistoryDefault)
        // A missing key (older/newer file) means "default", not "disabled".
        #expect(AppSettings.decode(from: Data("{}".utf8)).toggleNotchHotkey == .toggleNotchDefault)
    }

    @Test func customHotkeyRoundTrips() {
        var settings = AppSettings()
        settings.toggleNotchHotkey = KeyCombo(keyCode: 49, carbonModifiers: KeyCombo.controlKey | KeyCombo.optionKey)
        #expect(AppSettings.decode(from: settings.encoded()).toggleNotchHotkey == settings.toggleNotchHotkey)
    }

    @Test func resetKeepsHistoryAndSystemState() {
        var settings = AppSettings()
        settings.onboardingCompleted = true
        settings.launchAtLogin = true
        settings.closedMode = .invisible
        settings.clipboardLimit = 500
        settings.clipboardHotkey = nil
        let reset = settings.resetToDefaults()
        #expect(reset.onboardingCompleted)
        #expect(reset.launchAtLogin)
        #expect(reset.closedMode == AppSettings.defaults.closedMode)
        #expect(reset.clipboardLimit == 200)
        #expect(reset.clipboardHotkey == .clipboardHistoryDefault)
    }

    @Test func encodingIsDeterministic() {
        let first = AppSettings().encoded()
        let second = AppSettings().encoded()
        #expect(first != nil)
        #expect(first == second)
    }

    @Test func notchStyleGlassRule() {
        #expect(NotchStyle.glass.usesGlass(reduceTransparency: false))
        #expect(!NotchStyle.glass.usesGlass(reduceTransparency: true))
        #expect(!NotchStyle.solidBlack.usesGlass(reduceTransparency: false))
        #expect(!NotchStyle.solidBlack.usesGlass(reduceTransparency: true))
    }

    @Test func retentionIntervals() {
        #expect(RetentionPeriod.off.interval == nil)
        #expect(RetentionPeriod.oneDay.interval == 86_400)
        #expect(RetentionPeriod.sevenDays.interval == TimeInterval(7 * 86_400))
        #expect(RetentionPeriod.thirtyDays.interval == TimeInterval(30 * 86_400))
        #expect(Set(RetentionPeriod.allCases.map(\.displayName)).count == RetentionPeriod.allCases.count)
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

    @Test func defaultsUseOptionCommand() {
        for combo in [KeyCombo.toggleNotchDefault, .clipboardHistoryDefault] {
            #expect(combo.hasCommand && combo.hasOption && !combo.hasShift && !combo.hasControl)
        }
        #expect(KeyCombo.toggleNotchDefault.keyCode == 45)
        #expect(KeyCombo.clipboardHistoryDefault.keyCode == 9)
    }

    @Test func unknownKeyNames() {
        #expect(KeyCombo.keyName(for: 36) == "↩")
        #expect(KeyCombo.keyName(for: 999) == "Key 999")
    }
}

@Suite("Paths")
struct PathsTests {
    @Test func trailingSlashesAreTrimmed() {
        #expect(SuperNotchPaths(homeDirectory: "/Users/me///").homeDirectory == "/Users/me")
        #expect(SuperNotchPaths(homeDirectory: "/").homeDirectory == "/")
    }

    @Test func everyLocationIsInsideTheUsersLibrary() {
        let paths = SuperNotchPaths(homeDirectory: "/Users/me")
        let all = [
            paths.appSupport, paths.binDirectory, paths.hookBinary, paths.hookManifest, paths.settingsBackupDirectory,
            paths.shelfDirectory, paths.shelfIndex, paths.clipboardDirectory, paths.clipboardIndex,
            paths.clipboardImagesDirectory, paths.cacheDirectory, paths.titleCache, paths.logsDirectory,
        ]
        for path in all {
            #expect(path.hasPrefix("/Users/me/Library/"))
            #expect(!path.contains("//"))
        }
        #expect(Set(all).count == all.count)
        #expect(paths.cacheDirectory.hasSuffix(SuperNotchPaths.bundleIdentifier))
    }

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
