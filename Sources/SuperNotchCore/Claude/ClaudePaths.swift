import Foundation

// CONTRACT FILE (SPEC §D.6). Owner: claude-core.

/// Claude Code's config directory layout. Respects CLAUDE_CONFIG_DIR (env-vars.md).
public struct ClaudePaths: Sendable, Hashable {
    public let configDirectory: String

    public init(configDirectory: String) {
        var dir = configDirectory
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        self.configDirectory = dir
    }

    /// Resolution order: explicit `override` (Settings → Claude → Config folder) › `CLAUDE_CONFIG_DIR` › `~/.claude`.
    /// A leading "~" is expanded against `homeDirectory`.
    public static func resolve(
        environment: [String: String], homeDirectory: String, override: String? = nil
    ) -> ClaudePaths {
        func expand(_ path: String) -> String {
            if path == "~" { return homeDirectory }
            if path.hasPrefix("~/") { return homeDirectory + String(path.dropFirst()) }
            return path
        }
        if let override, !override.isEmpty { return ClaudePaths(configDirectory: expand(override)) }
        if let env = environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            return ClaudePaths(configDirectory: expand(env))
        }
        return ClaudePaths(configDirectory: homeDirectory + "/.claude")
    }

    /// User settings file the hook installer edits.
    public var settingsFile: String { configDirectory + "/settings.json" }
    /// One small JSON per running interactive session: sessions/<pid>.json (undocumented format).
    public var sessionsDirectory: String { configDirectory + "/sessions" }
    /// Transcripts: projects/<encoded-cwd>/<session-id>.jsonl (always prefer `transcript_path` from hooks).
    public var projectsDirectory: String { configDirectory + "/projects" }

    /// `<project>` folder name for a working directory: every non-alphanumeric character becomes "-"
    /// (sessions.md "Where transcripts are stored"). Nil when the name would exceed 200 characters, because
    /// Claude Code then appends a hash we cannot reproduce.
    public static func projectDirectoryName(forCwd cwd: String) -> String? {
        let name = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return name.isEmpty || name.count > 200 ? nil : name
    }

    /// Best-effort transcript location for a session known only from `claude agents --json` (no hook yet).
    public func transcriptFile(cwd: String, sessionID: String) -> String? {
        guard let folder = Self.projectDirectoryName(forCwd: cwd) else { return nil }
        return projectsDirectory + "/" + folder + "/" + sessionID + ".jsonl"
    }
}

/// Minimal dotted-version comparison for `claude --version` output such as "2.1.268 (Claude Code)".
public struct ClaudeVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first(where: {
            $0.first?.isNumber == true
        }) else { return nil }
        let numbers = token.split(separator: ".").map { part in Int(part.prefix(while: \.isNumber)) ?? 0 }
        guard !numbers.isEmpty else { return nil }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
