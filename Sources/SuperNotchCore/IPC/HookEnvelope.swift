import Foundation

// CONTRACT FILE (SPEC §D.7). Owner: claude-core. Wire types of the hook → app socket protocol.

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
    public static let extendedEvents: [HookEventName] = [
        .postToolUseFailure, .permissionDenied, .stopFailure, .subagentStart, .postCompact,
    ]

    /// Before Claude Code 2.1.101 one unrecognized hook event name made it ignore the WHOLE settings.json
    /// (CHANGELOG 2.1.101). PostCompact (2.1.76), StopFailure (2.1.78) and PermissionDenied (2.1.89) are newer
    /// than many 2.1.x installs, so the extended set is only written from 2.1.101 on, where unknown names are
    /// skipped harmlessly.
    public static let extendedEventsMinimumVersion = "2.1.101"

    /// First Claude Code version that knows this event (CHANGELOG), nil = present in every supported version.
    /// Used to drop base events a very old CLI would not recognise.
    public var minimumVersion: String? {
        switch self {
        case .permissionRequest: return "2.0.45"
        case .subagentStart: return "2.0.43"
        case .sessionEnd: return "1.0.85"
        case .sessionStart: return "1.0.62"
        case .userPromptSubmit: return "1.0.54"
        case .preCompact: return "1.0.48"
        case .subagentStop: return "1.0.41"
        case .postCompact: return "2.1.76"
        case .stopFailure: return "2.1.78"
        case .permissionDenied: return "2.1.89"
        case .postToolUseFailure: return HookEventName.extendedEventsMinimumVersion
        default: return nil
        }
    }

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
    /// argv prefix that runs this Claude Code install, e.g. `["/Users/me/.local/share/claude/versions/2.1.284"]`
    /// or `["/opt/homebrew/bin/node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]`.
    /// Append `agents --json --all` / `-p …`. The app runs under launchd's PATH, so never rely on "claude".
    public var claudeInvocation: [String]?
    /// Ancestors of the hook, nearest first (the hook's shell, claude, the user's shell, the terminal app…),
    /// up to launchd. Lets the focuser find the exact GUI process hosting the session.
    public var processChain: [HookProcessEntry]?
    /// Enclosing `.app` bundle of the nearest GUI ancestor above claude (e.g. "/Applications/iTerm.app",
    /// "/Applications/Cursor.app"), or derived from VS Code's askpass helper path.
    public var hostAppPath: String?

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
        isRemote: Bool = false,
        claudeInvocation: [String]? = nil,
        processChain: [HookProcessEntry]? = nil,
        hostAppPath: String? = nil
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
        self.claudeInvocation = claudeInvocation
        self.processChain = processChain
        self.hostAppPath = hostAppPath
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
            isInternal: Self.isTruthy(value(IPCConfig.internalMarkerEnvironmentKey)),
            isRemote: Self.isTruthy(value("CLAUDE_CODE_REMOTE")),
            hostAppPath: Self.appBundlePath(in: value("VSCODE_GIT_ASKPASS_NODE") ?? value("VSCODE_GIT_ASKPASS_MAIN"))
        )
        // Undocumented but exported by current Claude Code to hooks; the process walk overrides both.
        if let execPath = value("CLAUDE_CODE_EXECPATH"), execPath.hasPrefix("/") {
            claudeExecutablePath = execPath
            claudeInvocation = [execPath]
        }
        if let pid = value("CLAUDE_PID").flatMap({ Int32($0) }), pid > 1 { claudePID = pid }
    }

    /// "/Applications/Cursor.app/Contents/Frameworks/…" → "/Applications/Cursor.app" (outermost bundle).
    public static func appBundlePath(in path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        return bundle.hasPrefix("/") ? bundle : nil
    }

    static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    /// `CLAUDE_CODE_ENTRYPOINT` values of Claude Desktop's Code tab (regular and 3P builds).
    public static let desktopEntrypoints: Set<String> = ["claude-desktop", "claude-desktop-3p"]
    /// `CLAUDE_CODE_ENTRYPOINT` of Claude Desktop's Cowork agent (not a Code-tab chat; hidden).
    public static let coworkEntrypoint = "local-agent"
    /// `CLAUDE_CODE_ENTRYPOINT` of the VS Code extension's chat panel.
    public static let vscodeEntrypoint = "claude-vscode"

    /// The session is hosted by Claude Desktop's Code tab (entrypoint, inherited bundle id or `local_` host
    /// session id). Cowork (`local-agent`) is excluded.
    public var isDesktopHost: Bool {
        let entry = entrypoint?.lowercased()
        if entry == Self.coworkEntrypoint { return false }
        if let entry, Self.desktopEntrypoints.contains(entry) { return true }
        if bundleIdentifier == SessionHost.claudeDesktopBundleID { return true }
        return hostSessionID?.hasPrefix("local_") == true
    }

    /// A GUI host that shows the conversation to the user even though it may drive the CLI with `-p` /
    /// stream-json (Claude Desktop, the VS Code extension). Such sessions are never "headless".
    public var isInteractiveHost: Bool {
        isDesktopHost || entrypoint?.lowercased() == Self.vscodeEntrypoint
    }

    /// Third-party Agent SDK apps (`sdk-*`), Cowork, and plain `claude -p` runs (SPEC §E.2 `.hiddenHeadless`).
    /// Desktop and VS Code drive the CLI with `-p` / stream-json but show the chat, so they are never headless.
    public var isHeadless: Bool {
        let entry = entrypoint?.lowercased() ?? ""
        if entry.hasPrefix("sdk") || entry == Self.coworkEntrypoint { return true }
        return isPrintMode && !isInteractiveHost
    }

    /// Whether the hook should hold the connection open for a PermissionRequest decision. Internal, remote
    /// and headless sessions never get a card, so their hooks do not wait (Claude decides on its own).
    /// Subagent requests do wait: they surface as a card on the parent session.
    public func shouldAwaitPermissionReply(for event: HookEventName, agentID: String?) -> Bool {
        event.isBlocking && !isInternal && !isRemote && !isHeadless
    }

    // Tolerant decoding: every key optional (older/newer hook binaries).
    private enum CodingKeys: String, CodingKey {
        case hookVersion, claudePID, claudeStartTime, claudeExecutablePath, tty, termProgram, termSessionID
        case iTermSessionID, tmux, tmuxPane, kittyWindowID, weztermPane, ghosttyResourcesDir, vscodeInjection
        case bundleIdentifier, entrypoint, hostSessionID, claudeConfigDir, isPrintMode, isInternal, isRemote
        case claudeInvocation, processChain, hostAppPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hookVersion: (try? c.decodeIfPresent(String.self, forKey: .hookVersion)) ?? "0",
            claudePID: (try? c.decodeIfPresent(Int32.self, forKey: .claudePID)) ?? nil,
            claudeStartTime: (try? c.decodeIfPresent(Double.self, forKey: .claudeStartTime)) ?? nil,
            claudeExecutablePath: (try? c.decodeIfPresent(String.self, forKey: .claudeExecutablePath)) ?? nil,
            tty: (try? c.decodeIfPresent(String.self, forKey: .tty)) ?? nil,
            termProgram: (try? c.decodeIfPresent(String.self, forKey: .termProgram)) ?? nil,
            termSessionID: (try? c.decodeIfPresent(String.self, forKey: .termSessionID)) ?? nil,
            iTermSessionID: (try? c.decodeIfPresent(String.self, forKey: .iTermSessionID)) ?? nil,
            tmux: (try? c.decodeIfPresent(String.self, forKey: .tmux)) ?? nil,
            tmuxPane: (try? c.decodeIfPresent(String.self, forKey: .tmuxPane)) ?? nil,
            kittyWindowID: (try? c.decodeIfPresent(String.self, forKey: .kittyWindowID)) ?? nil,
            weztermPane: (try? c.decodeIfPresent(String.self, forKey: .weztermPane)) ?? nil,
            ghosttyResourcesDir: (try? c.decodeIfPresent(String.self, forKey: .ghosttyResourcesDir)) ?? nil,
            vscodeInjection: (try? c.decodeIfPresent(Bool.self, forKey: .vscodeInjection)) ?? false,
            bundleIdentifier: (try? c.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? nil,
            entrypoint: (try? c.decodeIfPresent(String.self, forKey: .entrypoint)) ?? nil,
            hostSessionID: (try? c.decodeIfPresent(String.self, forKey: .hostSessionID)) ?? nil,
            claudeConfigDir: (try? c.decodeIfPresent(String.self, forKey: .claudeConfigDir)) ?? nil,
            isPrintMode: (try? c.decodeIfPresent(Bool.self, forKey: .isPrintMode)) ?? false,
            isInternal: (try? c.decodeIfPresent(Bool.self, forKey: .isInternal)) ?? false,
            isRemote: (try? c.decodeIfPresent(Bool.self, forKey: .isRemote)) ?? false,
            claudeInvocation: (try? c.decodeIfPresent([String].self, forKey: .claudeInvocation)) ?? nil,
            processChain: (try? c.decodeIfPresent([HookProcessEntry].self, forKey: .processChain)) ?? nil,
            hostAppPath: (try? c.decodeIfPresent(String.self, forKey: .hostAppPath)) ?? nil
        )
    }
}

/// One ancestor process of the hook (`HookContext.processChain`).
public struct HookProcessEntry: Codable, Sendable, Hashable {
    public var pid: Int32
    /// Short command name (`p_comm` / `/proc/<pid>/comm`), e.g. "zsh", "iTerm2", "2.1.284".
    public var name: String
    /// Executable path when readable (same-user processes).
    public var path: String?

    public init(pid: Int32, name: String, path: String? = nil) {
        self.pid = pid
        self.name = name
        self.path = path
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

    /// An envelope the app fabricates itself, e.g. a `SessionEnd` when Claude Desktop quit and took its
    /// pid-less sessions with it (SPEC §E.3). Never expects a reply.
    public static func synthetic(
        _ event: HookEventName, sessionID: String, now: Date, fields: [(String, JSONValue)] = []
    ) -> HookEnvelope {
        var payload = JSONObject([
            ("session_id", .string(sessionID)), ("hook_event_name", .string(event.rawValue)),
        ])
        for (key, value) in fields { payload[key] = value }
        return HookEnvelope(
            id: "synthetic-" + UUID().uuidString, sentAt: now.timeIntervalSince1970, event: event,
            expectsReply: false, context: HookContext(hookVersion: "app"), payload: .object(payload))
    }
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
