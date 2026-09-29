import Foundation

// CONTRACT FILE (SPEC §D.5). Owner: claude-core. Wire types of the hook → app socket protocol.

/// Claude Code hook event name (`hook_event_name`). Open set: unknown names round-trip unchanged.
public struct HookEventName: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let sessionStart = HookEventName("SessionStart")
    public static let sessionEnd = HookEventName("SessionEnd")
    public static let userPromptSubmit = HookEventName("UserPromptSubmit")
    public static let preToolUse = HookEventName("PreToolUse")
    public static let postToolUse = HookEventName("PostToolUse")
    public static let postToolUseFailure = HookEventName("PostToolUseFailure")
    public static let permissionRequest = HookEventName("PermissionRequest")
    public static let permissionDenied = HookEventName("PermissionDenied")
    public static let notification = HookEventName("Notification")
    public static let stop = HookEventName("Stop")
    public static let stopFailure = HookEventName("StopFailure")
    public static let subagentStart = HookEventName("SubagentStart")
    public static let subagentStop = HookEventName("SubagentStop")
    public static let preCompact = HookEventName("PreCompact")
    public static let postCompact = HookEventName("PostCompact")

    /// Pseudo event sent by `supernotch-hook statusline` (the statusLine bridge). Never written to settings.json.
    public static let statusLine = HookEventName("StatusLine")

    /// Events installed for every supported Claude Code version (SPEC §D.6).
    public static let baseEvents: [HookEventName] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .permissionRequest,
        .notification, .stop, .subagentStop, .preCompact,
    ]

    /// Newer events, installed only when `claude --version` >= `extendedEventsMinimumVersion`.
    /// Unknown event keys can make older Claude Code versions reject settings.json (claude-island #85).
    public static let extendedEvents: [HookEventName] = [
        .postToolUseFailure, .permissionDenied, .stopFailure, .subagentStart, .postCompact,
    ]

    /// Conservative gate for `extendedEvents` (unverified exact introduction versions; all exist in 2.1.x).
    public static let extendedEventsMinimumVersion = "2.1.0"

    /// Whether the event supports a `matcher` (we then write `"matcher": "*"`).
    public var supportsMatcher: Bool {
        switch self {
        case .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest, .permissionDenied,
            .notification, .sessionStart, .sessionEnd, .subagentStart, .subagentStop, .preCompact,
            .postCompact, .stopFailure:
            return true
        default:
            return false
        }
    }

    /// Only PermissionRequest makes the hook wait for an app reply.
    public var isBlocking: Bool { self == .permissionRequest }
}

/// What `supernotch-hook` learned about its environment (not part of Claude Code's payload).
/// All fields optional/defaulted so old and new hook binaries interoperate.
public struct HookContext: Codable, Sendable, Hashable {
    /// Version of the hook binary (CFBundleShortVersionString of the app that installed it).
    public var hookVersion: String
    /// PID of the owning `claude` process (found by walking up to 8 parents, SPEC §D.5).
    public var claudePID: Int32?
    /// Start time (unix seconds) of `claudePID`, guards against PID reuse.
    public var claudeStartTime: Double?
    /// Absolute path of the `claude` executable (or cli.js), used to run `claude agents --json`.
    public var claudeExecutablePath: String?
    /// Terminal of the claude process, e.g. "/dev/ttys004". Nil for Desktop/IDE sessions.
    public var tty: String?
    public var termProgram: String?  // TERM_PROGRAM (authoritative host hint)
    public var termSessionID: String?  // TERM_SESSION_ID
    public var iTermSessionID: String?  // ITERM_SESSION_ID ("w0t1p0:<UUID>")
    public var tmux: String?  // TMUX
    public var tmuxPane: String?  // TMUX_PANE
    public var kittyWindowID: String?  // KITTY_WINDOW_ID
    public var weztermPane: String?  // WEZTERM_PANE
    public var ghosttyResourcesDir: String?  // GHOSTTY_RESOURCES_DIR (Ghostty detection)
    public var vscodeInjection: Bool  // VSCODE_INJECTION / TERM_PROGRAM=vscode
    public var bundleIdentifier: String?  // __CFBundleIdentifier of the GUI app that spawned the shell
    public var entrypoint: String?  // CLAUDE_CODE_ENTRYPOINT ("cli", "claude-desktop", "sdk-ts", ...)
    public var hostSessionID: String?  // CLAUDE_CODE_HOST_SESSION_ID ("local_<uuid>" for Desktop)
    public var claudeConfigDir: String?  // CLAUDE_CONFIG_DIR
    public var isPrintMode: Bool  // claude argv contains -p / --print
    public var isInternal: Bool  // SUPERNOTCH_INTERNAL=1
    public var isRemote: Bool  // CLAUDE_CODE_REMOTE=true (cloud VM; never expected locally)

    public init(
        hookVersion: String = "0",
        claudePID: Int32? = nil,
        claudeStartTime: Double? = nil,
        claudeExecutablePath: String? = nil,
        tty: String? = nil,
        termProgram: String? = nil,
        termSessionID: String? = nil,
        iTermSessionID: String? = nil,
        tmux: String? = nil,
        tmuxPane: String? = nil,
        kittyWindowID: String? = nil,
        weztermPane: String? = nil,
        ghosttyResourcesDir: String? = nil,
        vscodeInjection: Bool = false,
        bundleIdentifier: String? = nil,
        entrypoint: String? = nil,
        hostSessionID: String? = nil,
        claudeConfigDir: String? = nil,
        isPrintMode: Bool = false,
        isInternal: Bool = false,
        isRemote: Bool = false
    ) {
        self.hookVersion = hookVersion
        self.claudePID = claudePID
        self.claudeStartTime = claudeStartTime
        self.claudeExecutablePath = claudeExecutablePath
        self.tty = tty
        self.termProgram = termProgram
        self.termSessionID = termSessionID
        self.iTermSessionID = iTermSessionID
        self.tmux = tmux
        self.tmuxPane = tmuxPane
        self.kittyWindowID = kittyWindowID
        self.weztermPane = weztermPane
        self.ghosttyResourcesDir = ghosttyResourcesDir
        self.vscodeInjection = vscodeInjection
        self.bundleIdentifier = bundleIdentifier
        self.entrypoint = entrypoint
        self.hostSessionID = hostSessionID
        self.claudeConfigDir = claudeConfigDir
        self.isPrintMode = isPrintMode
        self.isInternal = isInternal
        self.isRemote = isRemote
    }

    /// Fills every environment-derived field. Process-derived fields (PID, tty, exec path, print mode)
    /// are filled by the hook binary afterwards.
    public init(environment env: [String: String], hookVersion: String) {
        func value(_ key: String) -> String? {
            guard let raw = env[key], !raw.isEmpty else { return nil }
            return raw
        }
        self.init(
            hookVersion: hookVersion,
            termProgram: value("TERM_PROGRAM"),
            termSessionID: value("TERM_SESSION_ID"),
            iTermSessionID: value("ITERM_SESSION_ID"),
            tmux: value("TMUX"),
            tmuxPane: value("TMUX_PANE"),
            kittyWindowID: value("KITTY_WINDOW_ID"),
            weztermPane: value("WEZTERM_PANE"),
            ghosttyResourcesDir: value("GHOSTTY_RESOURCES_DIR"),
            vscodeInjection: value("VSCODE_INJECTION") != nil || value("TERM_PROGRAM") == "vscode",
            bundleIdentifier: value("__CFBundleIdentifier"),
            entrypoint: value("CLAUDE_CODE_ENTRYPOINT"),
            hostSessionID: value("CLAUDE_CODE_HOST_SESSION_ID"),
            claudeConfigDir: value("CLAUDE_CONFIG_DIR"),
            isInternal: value(IPCConfig.internalMarkerEnvironmentKey) == "1",
            isRemote: value("CLAUDE_CODE_REMOTE") == "true"
        )
    }

    // Tolerant decoding: every key optional (older/newer hook binaries).
    private enum CodingKeys: String, CodingKey {
        case hookVersion, claudePID, claudeStartTime, claudeExecutablePath, tty, termProgram, termSessionID
        case iTermSessionID, tmux, tmuxPane, kittyWindowID, weztermPane, ghosttyResourcesDir, vscodeInjection
        case bundleIdentifier, entrypoint, hostSessionID, claudeConfigDir, isPrintMode, isInternal, isRemote
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hookVersion: try c.decodeIfPresent(String.self, forKey: .hookVersion) ?? "0",
            claudePID: try c.decodeIfPresent(Int32.self, forKey: .claudePID),
            claudeStartTime: try c.decodeIfPresent(Double.self, forKey: .claudeStartTime),
            claudeExecutablePath: try c.decodeIfPresent(String.self, forKey: .claudeExecutablePath),
            tty: try c.decodeIfPresent(String.self, forKey: .tty),
            termProgram: try c.decodeIfPresent(String.self, forKey: .termProgram),
            termSessionID: try c.decodeIfPresent(String.self, forKey: .termSessionID),
            iTermSessionID: try c.decodeIfPresent(String.self, forKey: .iTermSessionID),
            tmux: try c.decodeIfPresent(String.self, forKey: .tmux),
            tmuxPane: try c.decodeIfPresent(String.self, forKey: .tmuxPane),
            kittyWindowID: try c.decodeIfPresent(String.self, forKey: .kittyWindowID),
            weztermPane: try c.decodeIfPresent(String.self, forKey: .weztermPane),
            ghosttyResourcesDir: try c.decodeIfPresent(String.self, forKey: .ghosttyResourcesDir),
            vscodeInjection: try c.decodeIfPresent(Bool.self, forKey: .vscodeInjection) ?? false,
            bundleIdentifier: try c.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            entrypoint: try c.decodeIfPresent(String.self, forKey: .entrypoint),
            hostSessionID: try c.decodeIfPresent(String.self, forKey: .hostSessionID),
            claudeConfigDir: try c.decodeIfPresent(String.self, forKey: .claudeConfigDir),
            isPrintMode: try c.decodeIfPresent(Bool.self, forKey: .isPrintMode) ?? false,
            isInternal: try c.decodeIfPresent(Bool.self, forKey: .isInternal) ?? false,
            isRemote: try c.decodeIfPresent(Bool.self, forKey: .isRemote) ?? false
        )
    }
}

/// One hook → app message (one NDJSON line).
public struct HookEnvelope: Codable, Sendable, Hashable, Identifiable {
    /// Protocol version (`IPCConfig.protocolVersion`).
    public var v: Int
    /// Unique per hook invocation (UUID string). For blocking requests this is also the PermissionRequest id.
    public var id: String
    /// Unix seconds (with fraction) when the hook built the envelope.
    public var sentAt: Double
    /// Copied from `payload.hook_event_name` (or `.statusLine` for the bridge).
    public var event: HookEventName
    /// True only for PermissionRequest: the hook keeps the connection open and waits for one `HookReply` line.
    public var expectsReply: Bool
    public var context: HookContext
    /// The exact JSON Claude Code wrote to the hook's stdin (statusLine JSON for `.statusLine`).
    public var payload: JSONValue

    public init(
        v: Int = IPCConfig.protocolVersion,
        id: String,
        sentAt: Double,
        event: HookEventName,
        expectsReply: Bool,
        context: HookContext,
        payload: JSONValue
    ) {
        self.v = v
        self.id = id
        self.sentAt = sentAt
        self.event = event
        self.expectsReply = expectsReply
        self.context = context
        self.payload = payload
    }

    /// Typed read-only view of `payload`.
    public var hook: HookPayload { HookPayload(payload) }
    public var sentDate: Date { Date(timeIntervalSince1970: sentAt) }
}

/// App → hook reply for a blocking envelope (one NDJSON line on the same connection).
public struct HookReply: Codable, Sendable, Hashable {
    public var v: Int
    /// The `HookEnvelope.id` being answered.
    public var id: String
    /// nil = passthrough: the hook prints nothing and exits 0, so Claude Code shows its own prompt.
    public var decision: PermissionDecision?

    public init(v: Int = IPCConfig.protocolVersion, id: String, decision: PermissionDecision?) {
        self.v = v
        self.id = id
        self.decision = decision
    }
}
