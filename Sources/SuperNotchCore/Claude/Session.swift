import Foundation

// CONTRACT FILE (SPEC §D.1). Owner: claude-core. Additive changes only.

/// Why a session needs the user.
public enum NeedsInputKind: String, Sendable, Hashable, Codable {
    /// A tool permission prompt (Allow / Always allow / Deny can be answered in the notch).
    case permission
    /// Claude asked a question (AskUserQuestion, elicitation). Click jumps to the chat.
    case question
    /// Blocked for another reason (e.g. agents list `state=blocked` with no detail).
    case other
}

/// Session lifecycle phase (SPEC §E state machine).
public enum SessionPhase: Sendable, Hashable {
    /// Started, no prompt yet (grey dot).
    case idle
    /// A turn is running (yellow, subtle pulse).
    case working
    /// Turn finished, waiting for the next prompt (green).
    case done
    /// Blocked on the user (red).
    case needsInput(NeedsInputKind)

    public var trafficLight: TrafficLight {
        switch self {
        case .idle: return .grey
        case .working: return .yellow
        case .done: return .green
        case .needsInput: return .red
        }
    }

    public var isNeedsInput: Bool {
        if case .needsInput = self { return true }
        return false
    }
}

/// Dot colour. Ordered by urgency so aggregates can use `max()`: red > yellow > green > grey.
public enum TrafficLight: Int, Sendable, Hashable, Comparable, CaseIterable {
    case grey = 0
    case green = 1
    case yellow = 2
    case red = 3

    public static func < (lhs: TrafficLight, rhs: TrafficLight) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where the session runs; drives "jump to chat" and focus-aware popups.
public enum SessionHostKind: String, Sendable, Hashable, Codable {
    case terminal
    case claudeDesktop
    case vscode
    case unknown
}

public struct SessionHost: Sendable, Hashable, Codable {
    public var kind: SessionHostKind
    /// Bundle identifier of the GUI app hosting the session if known (e.g. com.googlecode.iterm2,
    /// com.apple.Terminal, com.mitchellh.ghostty, com.anthropic.claudefordesktop, com.microsoft.VSCode).
    public var appBundleID: String?
    public var termProgram: String?
    public var tty: String?
    public var iTermSessionID: String?
    public var termSessionID: String?
    public var tmux: String?
    public var tmuxPane: String?
    public var kittyWindowID: String?
    public var weztermPane: String?
    /// "local_<uuid>" for Claude Desktop Code-tab sessions (CLAUDE_CODE_HOST_SESSION_ID).
    public var desktopSessionID: String?

    public init(
        kind: SessionHostKind = .unknown,
        appBundleID: String? = nil,
        termProgram: String? = nil,
        tty: String? = nil,
        iTermSessionID: String? = nil,
        termSessionID: String? = nil,
        tmux: String? = nil,
        tmuxPane: String? = nil,
        kittyWindowID: String? = nil,
        weztermPane: String? = nil,
        desktopSessionID: String? = nil
    ) {
        self.kind = kind
        self.appBundleID = appBundleID
        self.termProgram = termProgram
        self.tty = tty
        self.iTermSessionID = iTermSessionID
        self.termSessionID = termSessionID
        self.tmux = tmux
        self.tmuxPane = tmuxPane
        self.kittyWindowID = kittyWindowID
        self.weztermPane = weztermPane
        self.desktopSessionID = desktopSessionID
    }

    public static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"
    public static let vscodeBundleID = "com.microsoft.VSCode"

    /// Bundle ids of VS Code and its forks (their integrated terminals set TERM_PROGRAM=vscode).
    public static let vscodeFamilyBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.trae.app",
    ]

    /// Maps `TERM_PROGRAM` to the terminal's bundle id. `TERM_PROGRAM` is the authoritative host hint; the
    /// inherited `__CFBundleIdentifier` can leak between GUI apps (e.g. a tmux server started elsewhere).
    /// Returns nil for ambiguous values ("vscode" covers several editors, "tmux" hides the outer terminal).
    public static func bundleID(forTermProgram termProgram: String?) -> String? {
        switch termProgram?.lowercased() {
        case "iterm.app": return "com.googlecode.iterm2"
        case "apple_terminal": return "com.apple.Terminal"
        case "ghostty": return "com.mitchellh.ghostty"
        case "wezterm": return "com.github.wez.wezterm"
        case "warpterminal": return "dev.warp.Warp-Stable"
        case "hyper": return "co.zeit.hyper"
        case "tabby": return "org.tabby"
        case "kitty": return "net.kovidgoyal.kitty"
        case "rio": return "com.raphaelamorim.rio"
        default: return nil
        }
    }

    /// Derives host info from a hook context (pure; tested).
    public init(context: HookContext) {
        let termBundle = Self.bundleID(forTermProgram: context.termProgram)
        let kind: SessionHostKind
        let bundleID: String?
        if context.isDesktopHost {
            kind = .claudeDesktop
            bundleID = Self.claudeDesktopBundleID
        } else if context.entrypoint?.lowercased() == HookContext.vscodeEntrypoint || context.vscodeInjection
            || context.termProgram?.lowercased() == "vscode"
            || context.bundleIdentifier.map(Self.vscodeFamilyBundleIDs.contains) == true
        {
            kind = .vscode
            bundleID = context.bundleIdentifier ?? Self.vscodeBundleID
        } else if context.tty != nil || context.termProgram != nil || context.tmux != nil
            || context.iTermSessionID != nil || context.termSessionID != nil || context.kittyWindowID != nil
            || context.weztermPane != nil
        {
            kind = .terminal
            bundleID =
                termBundle ?? context.bundleIdentifier
                ?? (context.ghosttyResourcesDir != nil ? "com.mitchellh.ghostty" : nil)
        } else {
            kind = .unknown
            bundleID = termBundle ?? context.bundleIdentifier
        }
        self.init(
            kind: kind,
            appBundleID: bundleID,
            termProgram: context.termProgram,
            tty: context.tty,
            iTermSessionID: context.iTermSessionID,
            termSessionID: context.termSessionID,
            tmux: context.tmux,
            tmuxPane: context.tmuxPane,
            kittyWindowID: context.kittyWindowID,
            weztermPane: context.weztermPane,
            desktopSessionID: context.hostSessionID
        )
    }
}

/// Where a displayed title came from. Higher raw value wins (SPEC §E "title resolution").
public enum TitleSource: Int, Sendable, Hashable, Comparable, Codable {
    /// "<repo>" placeholder (cwd basename).
    case fallback = 0
    /// First prompt, truncated locally, shown while a Haiku title is generated.
    case firstPrompt = 1
    /// 2–4 words generated by `claude -p --model haiku` (cached).
    case generated = 2
    /// `name` from `claude agents --json` when it is not a default name like "my-app-3f".
    case agentsName = 3
    /// `session_title` from SessionStart (`--name` / `/rename`).
    case sessionTitle = 4
    /// Last `ai-title` transcript entry (Claude Code's own Haiku-class title).
    case aiTitle = 5
    /// Last `custom-title` transcript entry (`/rename`, `--name`).
    case customTitle = 6

    public static func < (lhs: TitleSource, rhs: TitleSource) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SessionTitle: Sendable, Hashable, Codable {
    /// Display text, already shortened to at most 4 words / ~28 characters.
    public var text: String
    public var source: TitleSource
    public init(text: String, source: TitleSource) {
        self.text = text
        self.source = source
    }
}

/// Every raw title we know for a session; `TitleResolver` picks one.
public struct TitleCandidates: Sendable, Hashable, Codable {
    public var customTitle: String?
    public var aiTitle: String?
    public var sessionTitle: String?
    public var agentsName: String?
    public var generated: String?
    public init(
        customTitle: String? = nil, aiTitle: String? = nil, sessionTitle: String? = nil,
        agentsName: String? = nil, generated: String? = nil
    ) {
        self.customTitle = customTitle
        self.aiTitle = aiTitle
        self.sessionTitle = sessionTitle
        self.agentsName = agentsName
        self.generated = generated
    }
}

/// Why a session is not shown as a row.
public enum SessionVisibility: String, Sendable, Hashable, Codable {
    case visible
    /// Spawned by SuperNotch itself (SUPERNOTCH_INTERNAL=1).
    case hiddenInternal
    /// `claude -p` / SDK / headless.
    case hiddenHeadless
    /// Desktop pre-warm session that has not received a prompt yet.
    case hiddenUntilFirstPrompt
}

/// One Claude Code session as displayed by SuperNotch.
public struct Session: Sendable, Hashable, Identifiable {
    /// Claude Code `session_id` (UUID string).
    public let id: String
    public var cwd: String
    public var transcriptPath: String?
    public var pid: Int32?
    public var pidStartTime: Double?
    public var claudeExecutablePath: String?
    public var host: SessionHost
    public var phase: SessionPhase
    /// Set by StopFailure (green + ⚠ badge); cleared by the next UserPromptSubmit.
    public var lastError: String?
    public var title: SessionTitle?
    public var titleCandidates: TitleCandidates
    public var firstPrompt: String?
    /// First ~140 chars of `last_assistant_message` from Stop (shown in the green popup).
    public var lastAssistantPreview: String?
    /// Running subagents (SubagentStart − SubagentStop, clamped ≥ 0). Shown as a counter, never as rows.
    public var activeSubagents: Int
    /// Ids of pending `PermissionRequest`s for this session, oldest first.
    public var pendingPermissionIDs: [String]
    public var visibility: SessionVisibility
    /// No hook event for a long time while `working` (watchdog, SPEC §E). UI dims the pulse.
    public var isStale: Bool
    public var startedAt: Date
    /// Last event of any kind.
    public var updatedAt: Date
    /// Last phase change (used for sorting and popup debouncing).
    public var phaseChangedAt: Date
    /// The last Stop listed in-flight `background_tasks` (shell, subagent, monitor…): the turn is done but
    /// background work may wake the session again. Claude-app may skip the 🟢 popup for such turns.
    public var hasBackgroundWork: Bool

    public init(
        id: String,
        cwd: String,
        transcriptPath: String? = nil,
        pid: Int32? = nil,
        pidStartTime: Double? = nil,
        claudeExecutablePath: String? = nil,
        host: SessionHost = SessionHost(),
        phase: SessionPhase = .idle,
        lastError: String? = nil,
        title: SessionTitle? = nil,
        titleCandidates: TitleCandidates = TitleCandidates(),
        firstPrompt: String? = nil,
        lastAssistantPreview: String? = nil,
        activeSubagents: Int = 0,
        pendingPermissionIDs: [String] = [],
        visibility: SessionVisibility = .visible,
        isStale: Bool = false,
        startedAt: Date,
        updatedAt: Date? = nil,
        phaseChangedAt: Date? = nil,
        hasBackgroundWork: Bool = false
    ) {
        self.id = id
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.pid = pid
        self.pidStartTime = pidStartTime
        self.claudeExecutablePath = claudeExecutablePath
        self.host = host
        self.phase = phase
        self.lastError = lastError
        self.title = title
        self.titleCandidates = titleCandidates
        self.firstPrompt = firstPrompt
        self.lastAssistantPreview = lastAssistantPreview
        self.activeSubagents = activeSubagents
        self.pendingPermissionIDs = pendingPermissionIDs
        self.visibility = visibility
        self.isStale = isStale
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.phaseChangedAt = phaseChangedAt ?? startedAt
        self.hasBackgroundWork = hasBackgroundWork
    }

    public var trafficLight: TrafficLight { phase.trafficLight }
    public var isVisible: Bool { visibility == .visible }
    public var hasError: Bool { lastError != nil }

    /// Last path component of `cwd` ("supernotch"); "Claude" when the cwd is unknown or the root.
    public var projectName: String {
        let name = cwd.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "Claude" : name
    }

    /// What the row shows.
    public var displayTitle: String { title?.text ?? projectName }
}
