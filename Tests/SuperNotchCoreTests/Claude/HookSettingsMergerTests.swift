// Owner: claude-core. Seed tests by the foundation (SPEC §D.6).
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("HookSettingsMerger")
struct HookSettingsMergerTests {
    let spec = HookInstallSpec.make(
        hookBinaryPath: "/Users/me/Library/Application Support/SuperNotch/bin/supernotch-hook",
        claudeVersion: ClaudeVersion("2.1.268 (Claude Code)"), wrapStatusLine: true)
    let now = Date(timeIntervalSince1970: 0)

    func install(_ json: String?, manifest: HookManifest? = nil) throws -> HookMergeResult {
        try HookSettingsMerger.install(
            spec: spec, into: json.map { try JSONValue.parse($0) }, previousManifest: manifest,
            settingsFile: "/x/settings.json", appVersion: "0.1.0", now: now)
    }

    @Test func commandIsShellQuoted() {
        #expect(spec.hookCommand == "'/Users/me/Library/Application Support/SuperNotch/bin/supernotch-hook' hook")
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
    }

    @Test func installKeepsUserKeysOrderAndIsIdempotent() throws {
        let user = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say hi"}]}]},"statusLine":{"type":"command","command":"~/.claude/sl.sh","padding":1},"z":1}"#
        let first = try install(user)
        let object = try #require(first.settings.objectValue)
        #expect(object.keys == ["model", "hooks", "statusLine", "z"])
        #expect(first.manifest.originalStatusLine?["command"]?.stringValue == "~/.claude/sl.sh")
        #expect(first.settings["statusLine"]?["padding"]?.intValue == 1)
        let stop = try #require(first.settings["hooks"]?["Stop"]?.arrayValue)
        #expect(stop.count == 2)
        #expect(HookSettingsMerger.state(of: first.settings, spec: spec) == .installed)

        let second = try install(first.settings.serialized(pretty: true), manifest: first.manifest)
        #expect(second.settings.serialized(pretty: true) == first.settings.serialized(pretty: true))
        #expect(!second.changed)
        #expect(second.manifest.originalStatusLine == first.manifest.originalStatusLine)
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
        let removed = try HookSettingsMerger.uninstall(from: installed.settings, manifest: installed.manifest)
        #expect(removed.serialized() == "{}")
    }

    @Test func refusesNonObjectHooks() {
        #expect(throws: HookSettingsError.self) { try install(#"{"hooks":[]}"#) }
        #expect(throws: HookSettingsError.self) { try install("[]") }
    }

    @Test func extendedEventsAreVersionGated() {
        let old = HookInstallSpec.make(hookBinaryPath: "/b", claudeVersion: ClaudeVersion("1.0.90"), wrapStatusLine: false)
        #expect(!old.events.contains(.stopFailure))
        #expect(spec.events.contains(.stopFailure))
        #expect(old.statusLineCommand == nil)
    }
}
