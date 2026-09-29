import Foundation

// Owner: claude-core. Pure classification of Claude Code processes from argv / executable paths. Used by
// `supernotch-hook` (parent-chain walk, SPEC §D.7) and available to claude-app (e.g. to drop headless pids from
// `claude agents --json` before adoption, or to run `claude agents` with the right binary).

public enum ClaudeProcess {
    /// argv[0] basenames of the CLI.
    public static let executableNames: Set<String> = ["claude", "claude-code"]
    /// Script runners that may host a JavaScript build of the CLI.
    public static let scriptRunners: Set<String> = ["node", "bun", "deno"]

    /// Whether argv / the executable path belong to a Claude Code CLI process (native build, npm build under
    /// node/bun, or the copy bundled with Claude Desktop). Case-sensitive: "Claude" is the Desktop app itself.
    public static func isClaude(arguments: [String], executablePath: String?) -> Bool {
        let argv0 = arguments.first.map(basename) ?? ""
        if executableNames.contains(argv0) { return true }
        if let executablePath {
            if executableNames.contains(basename(executablePath)) { return true }
            // Native installer: ~/.local/share/claude/versions/2.1.284 (argv0 may be that path).
            if executablePath.contains("/claude/versions/") { return true }
        }
        let runner = scriptRunners.contains(argv0) || executablePath.map { scriptRunners.contains(basename($0)) } == true
        guard runner else { return false }
        return arguments.dropFirst().prefix(3).contains(where: isClaudeScript)
    }

    /// `-p` / `--print` (non-interactive). Desktop and VS Code also use it; see `HookContext.isHeadless`.
    public static func isPrintMode(arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0 == "-p" || $0 == "--print" || $0.hasPrefix("--print=") }
    }

    /// argv prefix that re-runs this install: `[executable]` for native builds, `[runner, script]` for npm builds.
    /// Nil when no absolute path is known (the app must never fall back to a bare "claude" under launchd).
    public static func invocation(arguments: [String], executablePath: String?) -> [String]? {
        let argv0 = arguments.first ?? ""
        let runner = scriptRunners.contains(basename(argv0))
            || executablePath.map { scriptRunners.contains(basename($0)) } == true
        if runner {
            guard let script = arguments.dropFirst().prefix(3).first(where: isClaudeScript), script.hasPrefix("/") else {
                return nil
            }
            let interpreter = executablePath.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? (argv0.hasPrefix("/") ? argv0 : nil)
            return interpreter.map { [$0, script] }
        }
        if let executablePath, executablePath.hasPrefix("/") { return [executablePath] }
        return argv0.hasPrefix("/") ? [argv0] : nil
    }

    /// The GUI app hosting a session: the first ancestor above the claude process whose executable lives in an
    /// `.app` bundle ("/Applications/iTerm.app"). `chain` is nearest-first, as in `HookContext.processChain`.
    public static func hostAppPath(chain: [HookProcessEntry], claudePID: Int32?) -> String? {
        var candidates = chain[...]
        if let claudePID, let index = chain.firstIndex(where: { $0.pid == claudePID }) {
            candidates = chain[(index + 1)...]
        }
        for entry in candidates {
            if let path = entry.path, let bundle = HookContext.appBundlePath(in: path) { return bundle }
        }
        return nil
    }

    /// Linux `/proc/<pid>/stat` tty_nr → device path (pseudo terminals and virtual consoles only).
    public static func ttyPath(linuxTTYNumber number: Int) -> String? {
        guard number > 0 else { return nil }
        let major = (number >> 8) & 0xFFF
        let minor = (number & 0xFF) | ((number >> 12) & 0xFFF00)
        switch major {
        case 136...143: return "/dev/pts/\(minor + (major - 136) * 256)"
        case 4 where minor < 64: return "/dev/tty\(minor)"
        default: return nil
        }
    }

    static func isClaudeScript(_ argument: String) -> Bool {
        executableNames.contains(basename(argument)) || argument.contains("@anthropic-ai/claude-code")
            || argument.contains("claude-code/cli")
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
