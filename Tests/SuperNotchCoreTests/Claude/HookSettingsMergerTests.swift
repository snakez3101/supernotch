// Owner: claude-core. Settings merger (SPEC §D.6): strict parse, key order, unknown keys, idempotency,
// uninstall, statusLine wrap/unwrap, repair detection, version gates, backups.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("HookSettingsMerger")
struct HookSettingsMergerTests {
    static let binary = "/Users/me/Library/Application Support/SuperNotch/bin/supernotch-hook"
    let spec = HookInstallSpec.make(
        hookBinaryPath: HookSettingsMergerTests.binary, claudeVersion: ClaudeVersion("2.1.284 (Claude Code)"),
        wrapStatusLine: true)
    let now = Date(timeIntervalSince1970: 0)
    let settingsFile = "/Users/me/.claude/settings.json"

    func install(_ json: String?, manifest: HookManifest? = nil, spec: HookInstallSpec? = nil) throws -> HookMergeResult {
        try HookSettingsMerger.install(
            spec: spec ?? self.spec, into: try HookSettingsMerger.parseSettings(json.map { Data($0.utf8) }),
            previousManifest: manifest, settingsFile: settingsFile, appVersion: "0.1.0", now: now)
    }

    func text(_ value: JSONValue) -> String { String(decoding: HookSettingsMerger.serialize(value), as: UTF8.self) }

    @Test func commandIsShellQuoted() {
        #expect(spec.hookCommand == "'/Users/me/Library/Application Support/SuperNotch/bin/supernotch-hook' hook")
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.split(ShellQuote.quote("a 'b' \"c\" $HOME\n")) == ["a 'b' \"c\" $HOME\n"])
        #expect(ShellQuote.split(#"x "a \"q\" b" 'c d' e\ f"#) == ["x", "a \"q\" b", "c d", "e f"])
    }

    @Test func installKeepsUserKeysOrderAndIsIdempotent() throws {
        let user = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say hi"}]}]},"statusLine":{"type":"command","command":"~/.claude/sl.sh","padding":1},"z":1}"#
        let first = try install(user)
        let object = try #require(first.settings.objectValue)
        #expect(object.keys == ["model", "hooks", "statusLine", "z"])
        #expect(first.manifest.originalStatusLine?["command"]?.stringValue == "~/.claude/sl.sh")
        #expect(first.settings["statusLine"]?["padding"]?.intValue == 1)
        #expect(
            first.settings["statusLine"]?["command"]?.stringValue
                == "'\(Self.binary)' statusline --wrap '~/.claude/sl.sh'")
        let stop = try #require(first.settings["hooks"]?["Stop"]?.arrayValue)
        #expect(stop.count == 2)
        #expect(stop[0]["hooks"]?[0]?["command"]?.stringValue == "say hi")
        #expect(HookSettingsMerger.state(of: first.settings, spec: spec) == .installed)
        #expect(first.changed)

        let second = try install(text(first.settings), manifest: first.manifest)
        #expect(text(second.settings) == text(first.settings))
        #expect(!second.changed)
        #expect(second.manifest.originalStatusLine == first.manifest.originalStatusLine)
        #expect(second.manifest.createdEventKeys == first.manifest.createdEventKeys)
    }

    @Test func realisticUserFileSurvivesInstallAndUninstall() throws {
        let original = String(decoding: try ClaudeFixtures.data("settings-user", "json"), as: UTF8.self)
        let installed = try install(original)
        let root = try #require(installed.settings.objectValue)
        #expect(root.keys == ["$schema", "model", "permissions", "env", "hooks", "statusLine", "alwaysThinkingEnabled", "unicode"])
        #expect(root["unicode"]?.stringValue == "Grüße ✓ \u{2028} line")
        let hooks = try #require(installed.settings["hooks"]?.objectValue)
        #expect(hooks["CustomFutureEvent"] == ["unknown": "shape"])
        #expect(hooks["PreToolUse"]?.arrayValue?.count == 2)
        #expect(hooks["PreToolUse"]?[0]?["matcher"]?.stringValue == "Bash")
        #expect(installed.settings["statusLine"]?["refreshInterval"]?.intValue == 5)
        #expect(installed.settings["statusLine"]?["padding"]?.intValue == 0)
        #expect(Set(installed.manifest.createdEventKeys) == Set(spec.events.map(\.rawValue)).subtracting(["PreToolUse", "Notification"]))
        #expect(!installed.manifest.createdHooksObject)

        let removed = try HookSettingsMerger.uninstall(from: installed.settings, manifest: installed.manifest)
        #expect(removed == (try JSONValue.parse(original)))
        #expect(removed.objectValue?.keys == (try JSONValue.parse(original)).objectValue?.keys)
    }

    @Test func uninstallRestoresOriginal() throws {
        let user = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say hi"}]}]},"statusLine":{"type":"command","command":"sl"}}"#
        let installed = try install(user)
        let removed = try HookSettingsMerger.uninstall(from: installed.settings, manifest: installed.manifest)
        #expect(removed.serialized() == (try JSONValue.parse(user)).serialized())
    }

    @Test func uninstallFromEmptyFileLeavesEmptyObject() throws {
        let installed = try install(nil)
        #expect(installed.manifest.createdHooksObject)
        #expect(installed.settings["statusLine"]?["command"]?.stringValue == "'\(Self.binary)' statusline")
        #expect(installed.manifest.originalStatusLine == nil)
        let removed = try HookSettingsMerger.uninstall(from: installed.settings, manifest: installed.manifest)
        #expect(removed.serialized() == "{}")
    }

    @Test func uninstallWithoutManifestRemovesOnlyWhatBecameEmpty() throws {
        let user = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say hi"}]}],"PreCompact":[]}}"#
        let installed = try install(user)
        let removed = try HookSettingsMerger.uninstall(from: installed.settings, manifest: nil)
        // Our arrays are gone; the user's (even an empty one) stay; the wrapped statusLine is unwrapped (none).
        #expect(removed.serialized() == #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say hi"}]}],"PreCompact":[]}}"#)
    }

    @Test func refusesInvalidOrUnexpectedDocuments() throws {
        #expect(throws: HookSettingsError.self) { try install(#"{"hooks":[]}"#) }
        #expect(throws: HookSettingsError.self) { try install("[]") }
        #expect(throws: HookSettingsError.self) { try install(#"{"hooks":{"Stop":{"x":1}}}"#) }
        let invalid = try ClaudeFixtures.data("settings-invalid", "json")
        #expect(throws: HookSettingsError.self) { try HookSettingsMerger.parseSettings(invalid) }
        #expect(throws: HookSettingsError.self) { try HookSettingsMerger.parseSettings(Data(#"{"a":1,}"#.utf8)) }
        #expect(try HookSettingsMerger.parseSettings(nil) == nil)
        #expect(try HookSettingsMerger.parseSettings(Data(" \n".utf8)) == nil)
        // "hooks": null is treated as absent.
        let result = try install(#"{"hooks":null}"#)
        #expect(result.settings["hooks"]?["Stop"] != nil)
    }

    @Test func serializationIsPrettyWithTrailingNewline() throws {
        let data = HookSettingsMerger.serialize(try JSONValue.parse(#"{"a":[1,{"b":null}],"c":{}}"#))
        #expect(String(decoding: data, as: UTF8.self) == "{\n  \"a\": [\n    1,\n    {\n      \"b\": null\n    }\n  ],\n  \"c\": {}\n}\n")
    }

    @Test func entryShapePerEvent() throws {
        let installed = try install(nil)
        let hooks = try #require(installed.settings["hooks"])
        #expect(hooks["UserPromptSubmit"]?[0]?["matcher"] == nil)
        #expect(hooks["Stop"]?[0]?["matcher"] == nil)
        #expect(hooks["PreToolUse"]?[0]?["matcher"]?.stringValue == "*")
        #expect(hooks["PermissionRequest"]?[0]?["hooks"]?[0]?["timeout"]?.intValue == 300)
        #expect(hooks["PostToolUse"]?[0]?["hooks"]?[0]?["timeout"]?.intValue == 10)
        #expect(hooks["PostToolUse"]?[0]?["hooks"]?[0]?["type"]?.stringValue == "command")
    }

    @Test func statusLineNeverWrapsItself() throws {
        // A manifest-less file where our bridge is already installed: the original is recovered from --wrap.
        let old = String(decoding: try ClaudeFixtures.data("settings-old-install", "json"), as: UTF8.self)
        let reinstalled = try install(old)
        let command = try #require(reinstalled.settings["statusLine"]?["command"]?.stringValue)
        #expect(command == "'\(Self.binary)' statusline --wrap '~/.claude/statusline.sh --compact'")
        #expect(reinstalled.manifest.originalStatusLine?["command"]?.stringValue == "~/.claude/statusline.sh --compact")
        #expect(reinstalled.settings["statusLine"]?["padding"]?.intValue == 2)
        // Our own command is never recorded as "original" (Open Island #671).
        let poisoned = #"{"statusLine":{"type":"command","command":"/tmp/dev/supernotch-hook statusline"}}"#
        let result = try install(poisoned)
        #expect(result.manifest.originalStatusLine == nil)
        #expect(result.settings["statusLine"]?["command"]?.stringValue == "'\(Self.binary)' statusline")
        #expect(spec.statusLineCommand(wrapping: "'/x/SuperNotch/bin/supernotch-hook' statusline") == spec.statusLineCommand)
    }

    @Test func disablingTheBridgeRestoresTheUsersStatusLine() throws {
        let user = #"{"statusLine":{"type":"command","command":"~/sl.sh","padding":3}}"#
        let withBridge = try install(user)
        let noBridge = HookInstallSpec.make(hookBinaryPath: Self.binary, claudeVersion: nil, wrapStatusLine: false)
        let without = try install(text(withBridge.settings), manifest: withBridge.manifest, spec: noBridge)
        #expect(without.settings["statusLine"] == (try JSONValue.parse(user))["statusLine"])
        #expect(without.manifest.originalStatusLine == nil)
        #expect(!without.manifest.statusLineInstalled)
    }

    @Test func repairDetection() throws {
        #expect(HookSettingsMerger.state(of: nil, spec: spec) == .notInstalled)
        #expect(HookSettingsMerger.state(of: try JSONValue.parse(#"{"hooks":{}}"#), spec: spec) == .notInstalled)
        // Old install path (app moved / other home): every event needs repair.
        let old = try ClaudeFixtures.json("settings-old-install")
        guard case .needsRepair(let missing) = HookSettingsMerger.state(of: old, spec: spec) else {
            Issue.record("expected needsRepair")
            return
        }
        #expect(missing.count == spec.events.count)
        // One event removed by the user.
        var installed = try #require(try install(nil).settings.objectValue)
        var hooks = try #require(installed["hooks"]?.objectValue)
        hooks["Stop"] = nil
        installed["hooks"] = .object(hooks)
        #expect(HookSettingsMerger.state(of: .object(installed), spec: spec) == .needsRepair(missing: [.stop]))
        // Bridge replaced by the user's own status line.
        let full = try install(nil).settings
        var replaced = try #require(full.objectValue)
        replaced["statusLine"] = ["type": "command", "command": "mine.sh"]
        #expect(HookSettingsMerger.state(of: .object(replaced), spec: spec) == .needsRepair(missing: []))
        // Wrong timeout on our PermissionRequest entry.
        let wrongTimeout = text(full).replacingOccurrences(of: "\"timeout\": 300", with: "\"timeout\": 10")
        #expect(
            HookSettingsMerger.state(of: try JSONValue.parse(wrongTimeout), spec: spec)
                == .needsRepair(missing: [.permissionRequest]))
        // Extended events installed but the CLI was downgraded below the gate.
        let oldSpec = HookInstallSpec.make(hookBinaryPath: Self.binary, claudeVersion: ClaudeVersion("2.1.50"), wrapStatusLine: true)
        #expect(HookSettingsMerger.state(of: full, spec: oldSpec) == .needsRepair(missing: []))
        #expect(HookSettingsMerger.state(of: full, spec: spec) == .installed)
    }

    @Test func extendedEventsAreVersionGated() {
        let old = HookInstallSpec.make(hookBinaryPath: "/b", claudeVersion: ClaudeVersion("2.1.100"), wrapStatusLine: false)
        #expect(!old.events.contains(.stopFailure))
        #expect(!old.events.contains(.postToolUseFailure))
        #expect(old.events.contains(.permissionRequest))
        #expect(spec.events.contains(.stopFailure))
        #expect(spec.events.contains(.subagentStart))
        #expect(old.statusLineCommand == nil)
        let unknown = HookInstallSpec.make(hookBinaryPath: "/b", claudeVersion: nil, wrapStatusLine: false)
        #expect(unknown.events == HookEventName.baseEvents)
        // A CLI older than PermissionRequest (2.0.45) must not get the key: it would ignore the whole file.
        let ancient = HookInstallSpec.make(hookBinaryPath: "/b", claudeVersion: ClaudeVersion("2.0.30"), wrapStatusLine: false)
        #expect(!ancient.events.contains(.permissionRequest))
        #expect(ancient.events.contains(.stop))
    }

    @Test func versionParsing() throws {
        #expect(ClaudeVersion("2.1.284 (Claude Code)")?.components == [2, 1, 284])
        #expect(ClaudeVersion("claude 1.0.9")?.description == "1.0.9")
        #expect(ClaudeVersion("garbage") == nil)
        #expect(try #require(ClaudeVersion("2.1.101")) > (try #require(ClaudeVersion("2.1.99"))))
        #expect(ClaudeVersion("2.1") == ClaudeVersion("2.1.0"))
    }

    @Test func manifestDecodingIsTolerant() throws {
        let manifest = try JSONDecoder().decode(HookManifest.self, from: Data(#"{"settingsFile":"/x","events":"oops"}"#.utf8))
        #expect(manifest.settingsFile == "/x")
        #expect(manifest.events.isEmpty)
        let installed = try install(#"{"statusLine":{"type":"command","command":"sl.sh"}}"#)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(HookManifest.self, from: try encoder.encode(installed.manifest))
        #expect(roundTrip == installed.manifest)
        #expect(roundTrip.originalStatusLineCommand == "sl.sh")
    }

    @Test func manifestForAnotherSettingsFileIsIgnored() throws {
        let work = try HookSettingsMerger.install(
            spec: spec, into: nil, previousManifest: nil, settingsFile: "/Users/me/.claude-work/settings.json",
            appVersion: "0.1.0", now: now)
        // Installing into ~/.claude with the other file's manifest must not trust its createdEventKeys.
        let user = #"{"hooks":{"Stop":[]}}"#
        let result = try install(user, manifest: work.manifest)
        #expect(!result.manifest.createdEventKeys.contains("Stop"))
        let removed = try HookSettingsMerger.uninstall(from: result.settings, manifest: result.manifest)
        #expect(removed.serialized() == user)
    }

    @Test func backupPathsAndHelpers() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21T13:33:20Z
        #expect(
            HookSettingsMerger.backupFileName(settingsFile: "/Users/me/.claude/settings.json", date: date)
                == "settings.json.2026-09-21T13-33-20Z.bak")
        #expect(
            HookSettingsMerger.backupPath(
                directory: "/Users/me/Library/Application Support/SuperNotch/Backups/", settingsFile: "/w/.claude-work/settings.json",
                date: date)
                == "/Users/me/Library/Application Support/SuperNotch/Backups/.claude-work.settings.json.2026-09-21T13-33-20Z.bak")
        #expect(HookSettingsMerger.hooksDisabled(in: try JSONValue.parse(#"{"disableAllHooks":true}"#)))
        #expect(!HookSettingsMerger.hooksDisabled(in: nil))
        let preview = HookSettingsMerger.previewEntries(spec: spec, originalStatusLineCommand: "sl.sh")
        #expect(preview["hooks"]?.objectValue?.count == spec.events.count)
        #expect(preview["statusLine"]?["command"]?.stringValue == "'\(Self.binary)' statusline --wrap 'sl.sh'")
        #expect(HookSettingsMerger.isOurCommand("'/a/b/supernotch-hook' hook", marker: HookInstallSpec.defaultMarker))
        #expect(!HookSettingsMerger.isOurCommand("echo supernotch-hook is great", marker: HookInstallSpec.defaultMarker))
    }

    @Test func claudePathsRespectConfigDir() {
        let home = "/Users/me"
        #expect(ClaudePaths.resolve(environment: [:], homeDirectory: home).settingsFile == "/Users/me/.claude/settings.json")
        #expect(
            ClaudePaths.resolve(environment: ["CLAUDE_CONFIG_DIR": "~/.claude-work/"], homeDirectory: home).settingsFile
                == "/Users/me/.claude-work/settings.json")
        #expect(
            ClaudePaths.resolve(environment: ["CLAUDE_CONFIG_DIR": "/x"], homeDirectory: home, override: "/y").configDirectory
                == "/y")
        #expect(ClaudePaths.resolve(environment: ["CLAUDE_CONFIG_DIR": ""], homeDirectory: home).configDirectory == "/Users/me/.claude")
        #expect(ClaudePaths.projectDirectoryName(forCwd: "/Users/me/my_app.v2") == "-Users-me-my-app-v2")
        #expect(
            ClaudePaths(configDirectory: "/Users/me/.claude").transcriptFile(cwd: "/Users/me/app", sessionID: "abc")
                == "/Users/me/.claude/projects/-Users-me-app/abc.jsonl")
        #expect(ClaudePaths.projectDirectoryName(forCwd: "/" + String(repeating: "a", count: 250)) == nil)
    }
}
