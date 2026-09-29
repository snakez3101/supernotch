import Foundation

// CONTRACT FILE (SPEC §D.7). Owner: claude-core. Constants shared by the app and `supernotch-hook`.

public enum IPCConfig {
    /// Wire protocol version (`v` field). Bump only with a migration plan: old hooks talk to new apps.
    public static let protocolVersion = 1

    /// Socket file name inside the SuperNotch Application Support folder.
    public static let socketFileName = "hook.sock"

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin including the terminating NUL.
    public static let maxSocketPathBytes = 103

    /// Environment override for the socket path (tests, debugging). Honoured by both sides.
    public static let socketPathEnvironmentKey = "SUPERNOTCH_SOCKET"

    /// Set to "1" in the environment of every `claude` process SuperNotch itself spawns (Haiku titles,
    /// `claude agents --json`). The hook reports it as `context.isInternal`; the reducer ignores those sessions.
    public static let internalMarkerEnvironmentKey = "SUPERNOTCH_INTERNAL"

    /// Set to "1" to make `supernotch-hook` append diagnostics to ~/Library/Logs/SuperNotch/hook.log.
    public static let hookDebugEnvironmentKey = "SUPERNOTCH_HOOK_DEBUG"

    /// Hook → app connect timeout. On timeout the hook exits 0 with empty stdout (fail open).
    public static let connectTimeout: TimeInterval = 0.1

    /// Write timeout for a single envelope.
    public static let writeTimeout: TimeInterval = 0.25

    /// How long a blocking PermissionRequest hook waits for the app's reply before giving up (fail open:
    /// exit 0, empty stdout → Claude Code shows its own prompt). Must stay below `permissionHookTimeout`.
    public static let permissionReplyTimeout: TimeInterval = 290

    /// `timeout` (seconds) written into settings.json for the PermissionRequest hook entry.
    public static let permissionHookTimeout = 300

    /// `timeout` (seconds) written into settings.json for every non-blocking hook entry.
    public static let defaultHookTimeout = 10

    /// Upper bound for one NDJSON message (hook payloads can include large tool inputs).
    public static let maxMessageBytes = 4 * 1024 * 1024

    /// Upper bound for the reply line the hook accepts from the app.
    public static let maxReplyBytes = 1 * 1024 * 1024

    /// Strings in a hook payload longer than this are truncated by the hook before sending
    /// (`HookPayloadCompactor`). Keeps envelopes small even when `tool_input` holds a whole file.
    public static let maxPayloadStringBytes = 16 * 1024

    /// The hook stops reading stdin after this long (Claude Code always closes it; this only guards
    /// against a caller that never does, so a hook can never hang a session).
    public static let stdinReadTimeout: TimeInterval = 5

    // `supernotch-hook statusline` execs the user's original command (no artificial timeout, no orphans):
    // Claude Code reads and cancels it directly, exactly as without the bridge (SPEC §D.7 revised).

    /// Argument that precedes the user's original statusLine command in our bridge command:
    /// `'…/supernotch-hook' statusline --wrap '<original command>'`.
    public static let statusLineWrapArgument = "--wrap"

    /// Test/debug override (seconds) for `permissionReplyTimeout`, honoured by the hook only when it parses
    /// to a value in 0.05…`permissionReplyTimeout`.
    public static let replyTimeoutEnvironmentKey = "SUPERNOTCH_HOOK_REPLY_TIMEOUT"
}

/// Resolves the hook socket path identically in the app and in `supernotch-hook`.
public enum SocketPath {
    /// - Returns: `$SUPERNOTCH_SOCKET` if set, else `<home>/Library/Application Support/SuperNotch/hook.sock`
    ///   if it fits in `sun_path`, else `/tmp/supernotch-<uid>.sock`.
    public static func resolve(homeDirectory: String, uid: UInt32, environment: [String: String]) -> String {
        if let override = environment[IPCConfig.socketPathEnvironmentKey], !override.isEmpty {
            return override
        }
        let primary = SuperNotchPaths(homeDirectory: homeDirectory).appSupport + "/" + IPCConfig.socketFileName
        if primary.utf8.count <= IPCConfig.maxSocketPathBytes { return primary }
        return fallback(uid: uid)
    }

    public static func fallback(uid: UInt32) -> String { "/tmp/supernotch-\(uid).sock" }
}
