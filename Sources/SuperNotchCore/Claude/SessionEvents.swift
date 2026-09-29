import Foundation

// CONTRACT FILE (SPEC §D.2/§E). Owner: claude-core.

/// Signals extracted from the tail of a transcript JSONL (undocumented format, parsed tolerantly).
public struct TranscriptSignals: Sendable, Hashable {
    /// Last `{"type":"custom-title","customTitle":…}` entry.
    public var customTitle: String?
    /// Last `{"type":"ai-title","aiTitle":…}` entry.
    public var aiTitle: String?
    /// Last legacy `{"type":"summary","summary":…}` entry.
    public var summary: String?
    /// The newest user/assistant entry is a "[Request interrupted by user" marker (Esc does not fire Stop).
    public var interrupted: Bool

    public init(customTitle: String? = nil, aiTitle: String? = nil, summary: String? = nil, interrupted: Bool = false) {
        self.customTitle = customTitle
        self.aiTitle = aiTitle
        self.summary = summary
        self.interrupted = interrupted
    }
}

/// Everything that can change the session store. Produced by `SessionSource`s and the app.
public enum SessionEvent: Sendable, Hashable {
    /// A hook (or statusLine bridge) envelope arrived.
    case hook(HookEnvelope)
    /// The app answered a PermissionRequest from the notch.
    case permissionAnswered(requestID: String, decision: PermissionDecision)
    /// The blocking hook connection closed before we answered (answered in the terminal, hook timed out,
    /// Claude killed the hook).
    case permissionConnectionClosed(requestID: String)
    /// Output of `claude agents --json --all` (drift correction).
    case agentsSnapshot([AgentsListEntry])
    /// Liveness check found the process gone (kill(pid,0) == ESRCH or start time changed).
    case processExited(pid: Int32)
    /// Transcript tail was (re)read.
    case transcript(sessionID: String, TranscriptSignals)
    /// A Haiku-generated short title is ready.
    case titleGenerated(sessionID: String, title: String)
    /// Periodic watchdog (every ~30 s while sessions exist).
    case tick
}

/// Side effects the store asks its owner (ClaudeSessionsModel) to perform or react to.
public enum SessionEffect: Sendable, Hashable {
    /// Session became visible (new row).
    case sessionAppeared(sessionID: String)
    case sessionRemoved(sessionID: String)
    case phaseChanged(sessionID: String, from: SessionPhase, to: SessionPhase)
    case permissionAdded(requestID: String)
    case permissionRemoved(requestID: String)
    /// The app must immediately answer the held hook connection with `HookReply(decision: nil)`
    /// (hidden session, AskUserQuestion, request superseded). Always accompanies removal of a pending request.
    case replyPassthrough(requestID: String)
    /// No usable native title: generate one with Haiku from `firstPrompt` (or compress a long native title).
    case titleGenerationNeeded(sessionID: String)
    /// Re-read the transcript tail (titles, interrupt marker).
    case transcriptRefreshNeeded(sessionID: String)
    case usageUpdated
}

/// Seam for session providers (SPEC §D.3). v1 has one: the local hook/agents source (claude-app).
/// A future cloud source (claude.ai/code) implements the same protocol and emits `SessionEvent`s.
@MainActor
public protocol SessionSource: AnyObject {
    /// Stable identifier, e.g. "local".
    var sourceID: String { get }
    /// Begin delivering events to `sink` on the main actor.
    func start(sink: @escaping @MainActor (SessionEvent) -> Void)
    func stop()
}
