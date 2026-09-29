// Owner: claude-app. Finds Claude Code config folders other than the one SuperNotch manages (SPEC §D.6).
// A session that uses CLAUDE_CONFIG_DIR=X reads X/settings.json, where our hooks are not installed, so it
// never reports X by itself. Discovery therefore looks where users set that variable (launchd, the login
// shell, `env` in settings.json) and at `~/.claude*` folders. Blocking; call off the main thread.

import Foundation
import SuperNotchCore

nonisolated enum ClaudeConfigDiscovery {
    /// Existing config folders other than `managed`, de-duplicated.
    static func candidates(homeDirectory: String, managed: [String]) -> [String] {
        var raw: [String] = []
        if let value = run("/bin/launchctl", ["getenv", "CLAUDE_CONFIG_DIR"]) { raw.append(value) }
        if let value = loginShellValue() { raw.append(value) }
        for directory in [homeDirectory + "/.claude"] + managed {
            if let value = settingsEnvironmentValue(configDirectory: directory) { raw.append(value) }
        }
        raw += homeConfigFolders(homeDirectory: homeDirectory)

        let excluded = Set(managed.map(standardized))
        var seen = Set<String>()
        var result: [String] = []
        for value in raw {
            let expanded = ClaudePaths.resolve(environment: [:], homeDirectory: homeDirectory, override: value)
                .configDirectory
            let key = standardized(expanded)
            guard !excluded.contains(key), seen.insert(key).inserted, looksLikeConfigFolder(expanded) else {
                continue
            }
            result.append(expanded)
        }
        return result
    }

    /// `<config>/projects/<slug>/<session>.jsonl` → `<config>`.
    static func configDirectory(fromTranscriptPath path: String?) -> String? {
        guard let path, let range = path.range(of: "/projects/", options: .backwards) else { return nil }
        let directory = String(path[..<range.lowerBound])
        return directory.isEmpty ? nil : directory
    }

    static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    // MARK: - Sources

    private static func looksLikeConfigFolder(_ directory: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: directory + "/settings.json")
            || fileManager.fileExists(atPath: directory + "/projects")
    }

    /// `~/.claude-work`, `~/.claude2`… (but not `~/.claude.json` or `~/.claude` itself, which is the default).
    private static func homeConfigFolders(homeDirectory: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: homeDirectory) else { return [] }
        return names.filter { $0.hasPrefix(".claude") && $0 != ".claude" && !$0.hasSuffix(".json") }
            .sorted()
            .map { homeDirectory + "/" + $0 }
            .filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
    }

    /// `env.CLAUDE_CONFIG_DIR` in a settings.json (users may set it there, env-vars.md).
    private static func settingsEnvironmentValue(configDirectory: String) -> String? {
        let file = ClaudePaths(configDirectory: configDirectory).settingsFile
        guard let data = FileManager.default.contents(atPath: file), let json = try? JSONValue.parse(data),
            let value = json["env"]?["CLAUDE_CONFIG_DIR"]?.stringValue, !value.isEmpty
        else { return nil }
        return value
    }

    private static func loginShellValue() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return run(shell, ["-l", "-c", "printf '%s' \"$CLAUDE_CONFIG_DIR\""])
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        var environment = ProcessInfo.processInfo.environment
        environment[IPCConfig.internalMarkerEnvironmentKey] = "1"
        guard
            let output = ClaudeProcessRunner.runSync(
                executable: executable, arguments: arguments, environment: environment,
                currentDirectory: NSHomeDirectory(), timeout: 3, maxOutputBytes: 16 * 1024),
            output.succeeded
        else { return nil }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
        return text
    }
}
