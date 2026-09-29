import Foundation

// Owner: claude-core. Signatures FROZEN (SPEC §D.1); transition rules per SPEC §E (refined, see below).
// Pure reducer: no clocks, no IO. The caller passes `now` and performs the returned effects.
//
// Refinements over the SPEC §E.1 table (all covered by fixture tests):
// * Visibility is decided by host first: Desktop (`claude-desktop*`, `local_` host id) and VS Code
//   (`claude-vscode`) drive the CLI with `-p`/stream-json but are visible; `sdk-*`, Cowork (`local-agent`) and
//   plain `claude -p` are `.hiddenHeadless`; `SUPERNOTCH_INTERNAL=1` is `.hiddenInternal`.
// * AskUserQuestion arrives as a PermissionRequest: passthrough + `.needsInput(.question)`, never a card.
// * Subagent PermissionRequests get a card on the parent session (labelled via `agentType`). Other subagent
//   events never change the parent's phase, except when resolving that subagent's own card.
// * #98: late PostToolUse / PostToolUseFailure / PreCompact / PostCompact / SubagentStart never revive a done or
//   idle session. A main-thread PreToolUse does (it precedes execution, so it is never "late": Stop-hook
//   continuations, `/goal`, crons). A session first seen through a tool event starts `.working`.
// * Pending permissions are linked to their PreToolUse `tool_use_id` and resolved by the PostToolUse /
//   PostToolUseFailure / PermissionDenied carrying it (input matching as fallback). Every pending card of a
//   session is dropped (passthrough) on UserPromptSubmit, Stop, StopFailure, Notification idle_prompt and a
//   fresh transcript interrupt, because none of them can happen while a native dialog is open.
// * A connection that closes after our own reply timeout keeps `.needsInput(.permission)` (native prompt still up).
// * Subagents are counted by `agent_id` (SubagentStop also fires for internal agents that never started).
// * Desktop sessions whose process ends with SessionEnd(reason "other") or exits are "parked" (row kept, pid
//   dropped) for `desktopParkedLifetime`, because Desktop may run one CLI process per turn. A synthetic
//   `SessionEvent.sessionEnded` always removes.
// * `claude agents --json` corrects drift only after hooks were silent for `agentsIdleGrace` (a snapshot taken
//   before the latest hook must not undo it) and adopts unknown live sessions (app restart).
// * Haiku titles are requested only when Claude Code produced no title after its first turn (or 30 s) and a
//   transcript read confirmed it (`TitleResolver.shouldRequestGeneration`).

public struct SessionStoreConfiguration: Sendable, Hashable {
    /// `working` with no event for this long ⇒ `isStale`.
    public var staleAfter: TimeInterval
    /// Hooks must have been silent this long before `claude agents --json` may change a phase
    /// (agents `status=idle` while we think `working` ⇒ done, etc.).
    public var agentsIdleGrace: TimeInterval
    /// Characters of `last_assistant_message` kept for the done peek.
    public var assistantPreviewLength: Int
    /// Create rows for live sessions that `claude agents --json` lists but no hook has reported yet.
    public var adoptAgentsSessions: Bool
    /// A removed session id ignores late hooks (other than SessionStart / UserPromptSubmit) and agents adoption
    /// for this long.
    public var tombstoneLifetime: TimeInterval
    /// Hidden sessions (internal, headless, pre-warm) without events for this long are forgotten.
    public var hiddenSessionLifetime: TimeInterval
    /// How long a parked Desktop session stays without new events (0 disables parking).
    public var desktopParkedLifetime: TimeInterval
    /// See `TitleResolver.shouldRequestGeneration`.
    public var titleGenerationGrace: TimeInterval
    /// Also ask Haiku to compress native titles longer than `TitleResolver.maxWords` (default off: native titles
    /// are shortened locally, REQUIREMENTS "only if none exists").
    public var compressLongNativeTitles: Bool
    /// Without a timestamp on the interrupt entry, a transcript interrupt read within this long after a new
    /// prompt is ignored (the transcript may not contain the new prompt yet).
    public var interruptRaceWindow: TimeInterval

    public init(
        staleAfter: TimeInterval = 600, agentsIdleGrace: TimeInterval = 10, assistantPreviewLength: Int = 140,
        adoptAgentsSessions: Bool = true, tombstoneLifetime: TimeInterval = 600,
        hiddenSessionLifetime: TimeInterval = 3600, desktopParkedLifetime: TimeInterval = 1800,
        titleGenerationGrace: TimeInterval = TitleResolver.generationGraceSeconds,
        compressLongNativeTitles: Bool = false, interruptRaceWindow: TimeInterval = 3
    ) {
        self.staleAfter = staleAfter
        self.agentsIdleGrace = agentsIdleGrace
        self.assistantPreviewLength = assistantPreviewLength
        self.adoptAgentsSessions = adoptAgentsSessions
        self.tombstoneLifetime = tombstoneLifetime
        self.hiddenSessionLifetime = hiddenSessionLifetime
        self.desktopParkedLifetime = desktopParkedLifetime
        self.titleGenerationGrace = titleGenerationGrace
        self.compressLongNativeTitles = compressLongNativeTitles
        self.interruptRaceWindow = interruptRaceWindow
    }
}

public struct SessionStore: Sendable {
    public let configuration: SessionStoreConfiguration
    /// All known sessions keyed by session id, including hidden ones.
    public private(set) var sessions: [String: Session] = [:]
    /// Pending permission requests keyed by request id.
    public private(set) var permissions: [String: PermissionRequest] = [:]
    public private(set) var usage: UsageLimits?

    /// Per-session bookkeeping that is not part of the public `Session`.
    private var meta: [String: SessionMeta] = [:]
    /// Recently removed session ids → removal time.
    private var tombstones: [String: Date] = [:]

    /// Prefix of envelope ids built by `HookEnvelope.synthetic` (app-made events).
    static let syntheticPrefix = "synthetic-"
    /// Tool uses remembered per session to link PermissionRequests to a `tool_use_id`.
    static let recentToolUseLimit = 32

    public init(configuration: SessionStoreConfiguration = .init()) {
        self.configuration = configuration
    }

    // MARK: - Queries

    /// Visible sessions: red, yellow, green, grey; then most recent phase change first.
    public var visibleSessions: [Session] {
        sessions.values.filter(\.isVisible).sorted { lhs, rhs in
            if lhs.trafficLight != rhs.trafficLight { return lhs.trafficLight > rhs.trafficLight }
            if lhs.phaseChangedAt != rhs.phaseChangedAt { return lhs.phaseChangedAt > rhs.phaseChangedAt }
            return lhs.id < rhs.id
        }
    }

    /// Pending permissions of visible sessions, oldest first.
    public var pendingPermissions: [PermissionRequest] {
        permissions.values.filter { sessions[$0.sessionID]?.isVisible ?? false }.sorted { lhs, rhs in
            lhs.receivedAt != rhs.receivedAt ? lhs.receivedAt < rhs.receivedAt : lhs.id < rhs.id
        }
    }

    /// Most urgent light across visible sessions; nil when there are none.
    public var aggregateLight: TrafficLight? { sessions.values.filter(\.isVisible).map(\.trafficLight).max() }

    /// True while a Desktop session is kept after its process ended (see header).
    public func isParked(_ sessionID: String) -> Bool { meta[sessionID]?.parkedAt != nil }

    // MARK: - Restoring persisted state (app launch)

    /// Seeds usage persisted by the app (`sn.claude.usage`). Windows that already reset are dropped; live data the
    /// store already has wins within the same window (`UsageLimits.merged`). No effects.
    public mutating func restoreUsage(_ restored: UsageLimits?, now: Date = Date()) {
        guard let restored else { return }
        let merged = (usage.map { restored.merged(with: $0) } ?? restored).pruned(now: now)
        usage = merged.isEmpty ? nil : merged
    }

    /// Re-inserts sessions the app persisted before a restart or update (only ids the store does not know and
    /// did not just remove). Pending cards are dropped (their hook connections died with the old process);
    /// liveness and `claude agents --json` correct anything stale. Returns `sessionAppeared` effects.
    public mutating func restoreSessions(_ restored: [Session], now: Date) -> [SessionEffect] {
        var effects: [SessionEffect] = []
        for var session in restored.sorted(by: { $0.id < $1.id })
        where sessions[session.id] == nil && tombstones[session.id] == nil {
            session.pendingPermissionIDs = []
            session.isStale = false
            session.updatedAt = now
            sessions[session.id] = session
            var meta = SessionMeta()
            meta.titleRequested = session.titleCandidates.generated != nil
            self.meta[session.id] = meta
            if session.isVisible { effects.append(.sessionAppeared(sessionID: session.id)) }
        }
        return effects
    }

    // MARK: - Reducer

    public mutating func apply(_ event: SessionEvent, now: Date) -> [SessionEffect] {
        var effects: [SessionEffect] = []
        let before = sessions
        switch event {
        case .hook(let envelope):
            applyHook(envelope, now: now, effects: &effects)
        case .permissionAnswered(let requestID, _):
            applyAnswered(requestID, now: now, effects: &effects)
        case .permissionConnectionClosed(let requestID):
            applyConnectionClosed(requestID, now: now, effects: &effects)
        case .agentsSnapshot(let entries):
            applyAgents(entries, now: now, effects: &effects)
        case .processExited(let pid):
            for id in sessions.keys.sorted() where sessions[id]?.pid == pid {
                endProcess(id, reason: nil, now: now, effects: &effects)
            }
        case .transcript(let sessionID, let signals):
            applyTranscript(sessionID, signals: signals, now: now, effects: &effects)
        case .titleGenerated(let sessionID, let title):
            let cleaned = TitleResolver.sanitizeGenerated(title)
            update(sessionID) { session, meta in
                meta.titleRequested = true
                if let cleaned { session.titleCandidates.generated = cleaned }
            }
        case .tick:
            applyTick(now: now, effects: &effects)
        }
        finalize(before: before, now: now, effects: &effects)
        return effects
    }

    // MARK: - Hooks

    private mutating func applyHook(_ envelope: HookEnvelope, now: Date, effects: inout [SessionEffect]) {
        if envelope.event == .statusLine {
            applyStatusLine(envelope, now: now, effects: &effects)
            return
        }
        let hook = envelope.hook
        let context = envelope.context
        guard let sessionID = hook.sessionID, !context.isRemote else {
            replyPassthroughIfHeld(envelope, effects: &effects)
            return
        }
        let isSynthetic = envelope.id.hasPrefix(Self.syntheticPrefix)
        if let removedAt = tombstones[sessionID] {
            let revives = envelope.event == .sessionStart || envelope.event == .userPromptSubmit
            if now.timeIntervalSince(removedAt) < configuration.tombstoneLifetime && !revives {
                replyPassthroughIfHeld(envelope, effects: &effects)
                return
            }
            tombstones[sessionID] = nil
        }
        if envelope.event == .sessionEnd {
            replyPassthroughIfHeld(envelope, effects: &effects)
            if isSynthetic {
                remove(sessionID, now: now, effects: &effects)
            } else {
                endProcess(sessionID, reason: hook.endReason ?? "other", now: now, effects: &effects)
            }
            return
        }

        let isNew = sessions[sessionID] == nil
        var session = sessions[sessionID] ?? makeSession(id: sessionID, envelope: envelope, now: now)
        var meta = self.meta[sessionID] ?? SessionMeta()
        absorbContext(envelope, into: &session)
        session.updatedAt = now
        session.isStale = false
        if !isSynthetic { meta.lastHookAt = now }
        meta.parkedAt = nil
        let agentID = hook.agentID
        let isSubagent = agentID != nil

        switch envelope.event {
        case .sessionStart:
            if hook.source == "clear" && !isNew {
                clearPending(&session, &meta, effects: &effects)
                session.titleCandidates = TitleCandidates()
                session.firstPrompt = nil
                session.lastAssistantPreview = nil
                session.lastError = nil
                session.hasBackgroundWork = false
                session.phase = .idle
                meta.resetConversation()
            }
            if let title = hook.sessionTitle { session.titleCandidates.sessionTitle = title }
            effects.append(.transcriptRefreshNeeded(sessionID: sessionID))

        case .userPromptSubmit where !isSubagent:
            clearPending(&session, &meta, effects: &effects)
            session.phase = .working
            session.lastError = nil
            session.lastAssistantPreview = nil
            session.hasBackgroundWork = false
            if session.firstPrompt == nil, let prompt = hook.prompt,
                !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                session.firstPrompt = String(prompt.prefix(2_000))
                meta.firstPromptAt = now
            }
            meta.turnStartedAt = now
            promoteIfPrewarmed(&session)
            effects.append(.transcriptRefreshNeeded(sessionID: sessionID))

        case .preToolUse:
            meta.rememberToolUse(hook, limit: Self.recentToolUseLimit)
            guard !isSubagent else { break }
            if hook.toolName == "AskUserQuestion" {
                session.phase = .needsInput(.question)
            } else if session.pendingPermissionIDs.isEmpty {
                session.phase = .working
            }
            promoteIfPrewarmed(&session)

        case .postToolUse, .postToolUseFailure:
            let resolved = resolvePermission(for: hook, session: &session, meta: &meta, effects: &effects)
            if isSubagent {
                if resolved { resumeIfUnblocked(&session) }
                break
            }
            if session.pendingPermissionIDs.isEmpty && (isNew || resolved || session.phase.isActive) {
                session.phase = .working  // #98: done / idle stay as they are
            }
            promoteIfPrewarmed(&session)

        case .permissionDenied:
            if resolvePermission(for: hook, session: &session, meta: &meta, effects: &effects) {
                resumeIfUnblocked(&session)  // auto mode denied; Claude continues
            }

        case .subagentStart:
            if let agentID { meta.subagentIDs.insert(agentID) }
            if session.pendingPermissionIDs.isEmpty && (isNew || session.phase == .working) {
                session.phase = .working
            }

        case .subagentStop:
            if let agentID { meta.subagentIDs.remove(agentID) }

        case .preCompact, .postCompact:
            if isNew { session.phase = .working }

        case .permissionRequest:
            applyPermissionRequest(envelope, session: &session, meta: &meta, now: now, effects: &effects)

        case .notification:
            applyNotification(hook, session: &session, meta: &meta, isNew: isNew, effects: &effects)

        case .stop where !isSubagent, .stopFailure where !isSubagent:
            clearPending(&session, &meta, effects: &effects)
            session.phase = .done
            if envelope.event == .stop {
                if let message = hook.lastAssistantMessage {
                    session.lastAssistantPreview = Self.preview(message, length: configuration.assistantPreviewLength)
                }
                session.hasBackgroundWork = hook.backgroundTaskCount > 0
                if hook.backgroundTasks != nil && !hook.hasBackgroundSubagents { meta.subagentIDs.removeAll() }
            } else {
                session.lastError = Self.describeStopFailure(hook)
            }
            meta.completedTurns += 1
            meta.lastStopAt = now
            promoteIfPrewarmed(&session)
            effects.append(.transcriptRefreshNeeded(sessionID: sessionID))

        default:
            break  // Unknown / future events and subagent-scoped Stop only refresh updatedAt.
        }

        sessions[sessionID] = session
        self.meta[sessionID] = meta
    }

    private mutating func applyPermissionRequest(
        _ envelope: HookEnvelope, session: inout Session, meta: inout SessionMeta, now: Date,
        effects: inout [SessionEffect]
    ) {
        let hook = envelope.hook
        let answerable = session.visibility == .visible || session.visibility == .hiddenUntilFirstPrompt
        // AskUserQuestion's question UI *is* the permission prompt: Allow/Deny would be wrong. Jump to chat.
        if hook.toolName == "AskUserQuestion" {
            replyPassthroughIfHeld(envelope, effects: &effects)
            if answerable {
                session.phase = .needsInput(.question)
                promoteIfPrewarmed(&session)
            }
            return
        }
        guard answerable else {
            replyPassthroughIfHeld(envelope, effects: &effects)
            return
        }
        promoteIfPrewarmed(&session)
        guard envelope.expectsReply, let request = PermissionRequest(envelope: envelope, now: now) else {
            // Nobody waits for an answer (old hook, fire-and-forget): show red, answer in the chat.
            session.phase = .needsInput(.permission)
            return
        }
        if let toolUseID = meta.linkToolUse(for: request) { meta.requestToolUseIDs[request.id] = toolUseID }
        if permissions[request.id] == nil { session.pendingPermissionIDs.append(request.id) }
        permissions[request.id] = request
        session.phase = .needsInput(.permission)
        effects.append(.permissionAdded(requestID: request.id))
    }

    private mutating func applyNotification(
        _ hook: HookPayload, session: inout Session, meta: inout SessionMeta, isNew: Bool,
        effects: inout [SessionEffect]
    ) {
        let type = hook.notificationType ?? ""
        if let kind = NotificationType.needsInputKind(for: type) {
            if session.pendingPermissionIDs.isEmpty {
                session.phase = .needsInput(kind)
                promoteIfPrewarmed(&session)
            }
        } else if type == NotificationType.idlePrompt {
            // Claude finished responding a minute ago and waits for a prompt: nothing can still be pending.
            clearPending(&session, &meta, effects: &effects)
            if session.visibility != .hiddenUntilFirstPrompt && (session.phase != .idle || isNew) {
                session.phase = .done
            }
        } else if NotificationType.resumesWork.contains(type) {
            resumeIfUnblocked(&session)
        }
    }

    private func makeSession(id: String, envelope: HookEnvelope, now: Date) -> Session {
        let hook = envelope.hook
        return Session(
            id: id, cwd: hook.cwd ?? "", transcriptPath: hook.transcriptPath,
            host: SessionHost(context: envelope.context),
            visibility: Self.visibility(for: envelope.context, event: envelope.event), startedAt: now)
    }

    /// SPEC §E.2, host first (Desktop / VS Code run as `-p` but are visible).
    static func visibility(for context: HookContext, event: HookEventName) -> SessionVisibility {
        if context.isInternal { return .hiddenInternal }
        if context.isHeadless { return .hiddenHeadless }
        if context.isDesktopHost && event == .sessionStart { return .hiddenUntilFirstPrompt }  // Desktop pre-warm
        return .visible
    }

    private func absorbContext(_ envelope: HookEnvelope, into session: inout Session) {
        let hook = envelope.hook
        let context = envelope.context
        if hook.agentID == nil {
            if let cwd = hook.cwd { session.cwd = cwd }
            if let path = hook.transcriptPath { session.transcriptPath = path }
        }
        if let pid = context.claudePID { session.pid = pid }
        if let start = context.claudeStartTime { session.pidStartTime = start }
        if let exe = context.claudeExecutablePath { session.claudeExecutablePath = exe }
        let host = SessionHost(context: context)
        if host.kind != .unknown || session.host.kind == .unknown {
            var merged = host
            // Keep identifiers an earlier event knew but this one lacks.
            merged.tty = host.tty ?? session.host.tty
            merged.appBundleID = host.appBundleID ?? session.host.appBundleID
            merged.desktopSessionID = host.desktopSessionID ?? session.host.desktopSessionID
            session.host = merged
        }
        // Hidden-ness only ever gets stricter (a later event may reveal an internal/headless session that was
        // first seen through `claude agents --json`).
        let classified = Self.visibility(for: context, event: .preToolUse)
        if classified != .visible, session.visibility == .visible || session.visibility == .hiddenUntilFirstPrompt {
            session.visibility = classified
        }
    }

    private func promoteIfPrewarmed(_ session: inout Session) {
        if session.visibility == .hiddenUntilFirstPrompt { session.visibility = .visible }
    }

    /// `.needsInput` without a card left behind ⇒ `.working`.
    private func resumeIfUnblocked(_ session: inout Session) {
        if session.phase.isNeedsInput && session.pendingPermissionIDs.isEmpty { session.phase = .working }
    }

    private func replyPassthroughIfHeld(_ envelope: HookEnvelope, effects: inout [SessionEffect]) {
        if envelope.expectsReply { effects.append(.replyPassthrough(requestID: envelope.id)) }
    }

    // MARK: - Permissions

    /// Resolves the pending request a tool event belongs to: by the linked `tool_use_id` when there is one,
    /// otherwise by tool name + input (`PermissionRequest.matches`). PreToolUse never resolves (it precedes
    /// the prompt).
    private mutating func resolvePermission(
        for hook: HookPayload, session: inout Session, meta: inout SessionMeta, effects: inout [SessionEffect]
    ) -> Bool {
        guard !session.pendingPermissionIDs.isEmpty, let toolName = hook.toolName else { return false }
        let toolUseID = hook.toolUseID
        var match: String?
        if let toolUseID {
            match = session.pendingPermissionIDs.first { meta.requestToolUseIDs[$0] == toolUseID }
        }
        if match == nil {
            match = session.pendingPermissionIDs.first { id in
                guard let request = permissions[id], request.agentID == hook.agentID else { return false }
                if toolUseID != nil, meta.requestToolUseIDs[id] != nil { return false }  // linked elsewhere
                return request.matches(toolName: toolName, toolInput: hook.toolInput)
            }
        }
        guard let match else { return false }
        removePermission(match, session: &session, meta: &meta, passthrough: true, effects: &effects)
        return true
    }

    private mutating func removePermission(
        _ requestID: String, session: inout Session, meta: inout SessionMeta, passthrough: Bool,
        effects: inout [SessionEffect]
    ) {
        session.pendingPermissionIDs.removeAll { $0 == requestID }
        meta.requestToolUseIDs[requestID] = nil
        guard permissions.removeValue(forKey: requestID) != nil else { return }
        effects.append(.permissionRemoved(requestID: requestID))
        if passthrough { effects.append(.replyPassthrough(requestID: requestID)) }
    }

    /// Drops every pending card of the session and lets the held hooks fall back to the native prompt.
    private mutating func clearPending(_ session: inout Session, _ meta: inout SessionMeta, effects: inout [SessionEffect]) {
        for requestID in session.pendingPermissionIDs {
            removePermission(requestID, session: &session, meta: &meta, passthrough: true, effects: &effects)
        }
    }

    private mutating func applyAnswered(_ requestID: String, now: Date, effects: inout [SessionEffect]) {
        guard let request = permissions[requestID] else { return }
        guard var session = sessions[request.sessionID] else {
            permissions[requestID] = nil
            effects.append(.permissionRemoved(requestID: requestID))
            return
        }
        var meta = self.meta[request.sessionID] ?? SessionMeta()
        removePermission(requestID, session: &session, meta: &meta, passthrough: false, effects: &effects)
        // Allow and deny both let Claude continue (deny feeds the message back to Claude).
        resumeIfUnblocked(&session)
        session.updatedAt = now
        sessions[request.sessionID] = session
        self.meta[request.sessionID] = meta
    }

    private mutating func applyConnectionClosed(_ requestID: String, now: Date, effects: inout [SessionEffect]) {
        guard let request = permissions[requestID] else { return }
        guard var session = sessions[request.sessionID] else {
            permissions[requestID] = nil
            effects.append(.permissionRemoved(requestID: requestID))
            return
        }
        var meta = self.meta[request.sessionID] ?? SessionMeta()
        removePermission(requestID, session: &session, meta: &meta, passthrough: false, effects: &effects)
        // Our hook gave up after its reply timeout: the native prompt is still waiting for the user.
        let hookTimedOut = now.timeIntervalSince(request.receivedAt) >= IPCConfig.permissionReplyTimeout - 5
        if !hookTimedOut { resumeIfUnblocked(&session) }
        session.updatedAt = now
        sessions[request.sessionID] = session
        self.meta[request.sessionID] = meta
        // Closed early: answered in the terminal, or the turn was interrupted (Esc fires no Stop).
        effects.append(.transcriptRefreshNeeded(sessionID: request.sessionID))
    }

    // MARK: - Transcript, status line, ticks

    private mutating func applyTranscript(
        _ sessionID: String, signals: TranscriptSignals, now: Date, effects: inout [SessionEffect]
    ) {
        guard var session = sessions[sessionID] else { return }
        var meta = self.meta[sessionID] ?? SessionMeta()
        meta.lastTranscriptAt = now
        if let custom = signals.customTitle { session.titleCandidates.customTitle = custom }
        if let ai = signals.aiTitle {
            session.titleCandidates.aiTitle = ai
        } else if let summary = signals.summary, session.titleCandidates.aiTitle == nil {
            session.titleCandidates.aiTitle = summary
        }
        if signals.interrupted && isFreshInterrupt(signals.interruptedAt, meta: meta, now: now) {
            switch session.phase {
            case .working, .needsInput:
                clearPending(&session, &meta, effects: &effects)
                session.phase = .done
            case .idle, .done:
                break
            }
        }
        sessions[sessionID] = session
        self.meta[sessionID] = meta
    }

    /// An interrupt counts only if it belongs to the current turn (a read racing a new prompt sees the previous
    /// turn's marker as the newest entry).
    private func isFreshInterrupt(_ interruptedAt: Date?, meta: SessionMeta, now: Date) -> Bool {
        guard let turnStart = meta.turnStartedAt else { return true }
        if let interruptedAt { return interruptedAt >= turnStart.addingTimeInterval(-1) }
        return now.timeIntervalSince(turnStart) >= configuration.interruptRaceWindow
    }

    private mutating func applyStatusLine(_ envelope: HookEnvelope, now: Date, effects: inout [SessionEffect]) {
        let payload = envelope.payload
        if let report = UsageLimits.fromStatusLine(payload, now: now) {
            let merged = (usage.map { $0.merged(with: report) } ?? report).pruned(now: now)
            let next = merged.isEmpty ? nil : merged
            let windowsChanged = next?.fiveHour != usage?.fiveHour || next?.sevenDay != usage?.sevenDay
            let refreshed = next.map { new in usage.map { new.updatedAt.timeIntervalSince($0.updatedAt) >= 60 } ?? true }
            if windowsChanged || refreshed == true {
                usage = next
                effects.append(.usageUpdated)
            }
        }
        // `session_name`: a /rename name or Claude Code's generated title (never the default display name).
        if let sessionID = payload["session_id"]?.stringValue, var session = sessions[sessionID],
            let name = payload["session_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty, !TitleResolver.isDefaultAgentsName(name, projectName: session.projectName)
        {
            session.titleCandidates.sessionTitle = name
            sessions[sessionID] = session
        }
    }

    private mutating func applyTick(now: Date, effects: inout [SessionEffect]) {
        for id in sessions.keys.sorted() {
            guard var session = sessions[id] else { continue }
            let idleFor = now.timeIntervalSince(session.updatedAt)
            if !session.isVisible && idleFor >= configuration.hiddenSessionLifetime {
                remove(id, now: now, effects: &effects)
                continue
            }
            if let parkedAt = meta[id]?.parkedAt, now.timeIntervalSince(parkedAt) >= configuration.desktopParkedLifetime,
                idleFor >= configuration.desktopParkedLifetime
            {
                remove(id, now: now, effects: &effects)
                continue
            }
            if session.phase == .working && !session.isStale && idleFor >= configuration.staleAfter {
                session.isStale = true
                sessions[id] = session
            }
        }
        if let current = usage {
            let pruned = current.pruned(now: now)
            if pruned != current {
                usage = pruned.isEmpty ? nil : pruned
                effects.append(.usageUpdated)
            }
        }
        tombstones = tombstones.filter { now.timeIntervalSince($0.value) < configuration.tombstoneLifetime }
    }

    // MARK: - Agents snapshot (drift correction + adoption)

    private mutating func applyAgents(_ entries: [AgentsListEntry], now: Date, effects: inout [SessionEffect]) {
        for entry in entries {
            guard let id = entry.sessionId else { continue }
            guard var session = sessions[id] else {
                adoptIfPossible(entry, id: id, now: now, effects: &effects)
                continue
            }
            let meta = self.meta[id] ?? SessionMeta()
            if let name = entry.name, !TitleResolver.isDefaultAgentsName(name, projectName: session.projectName) {
                session.titleCandidates.agentsName = name
            }
            if let pid = entry.pid, session.pid == nil, meta.parkedAt == nil { session.pid = pid }
            if entry.state == "failed" || entry.state == "stopped" {
                remove(id, now: now, effects: &effects)
                continue
            }
            let hooksSilentFor = now.timeIntervalSince(meta.lastHookAt ?? session.startedAt)
            let mayCorrect = hooksSilentFor >= configuration.agentsIdleGrace
            let pending = !session.pendingPermissionIDs.isEmpty
            if entry.status == "busy" || (entry.status == nil && entry.state == "working") {
                session.updatedAt = now  // alive and working (e.g. a long tool call): not stale
                session.isStale = false
                if mayCorrect && !pending && session.phase != .working { session.phase = .working }
            } else if entry.status == "waiting" || (entry.status == nil && entry.state == "blocked") {
                if mayCorrect && !session.phase.isNeedsInput, let kind = entry.needsInputKind {
                    session.phase = .needsInput(kind)
                    promoteIfPrewarmed(&session)
                }
            } else if entry.status == "idle" || (entry.status == nil && entry.state == "done") {
                if mayCorrect && !pending && (session.phase == .working || session.phase.isNeedsInput) {
                    session.phase = .done
                }
            }
            sessions[id] = session
        }
    }

    /// Adopts a live session nobody reported yet (e.g. SuperNotch was restarted). Hooks refine it later.
    private mutating func adoptIfPossible(
        _ entry: AgentsListEntry, id: String, now: Date, effects: inout [SessionEffect]
    ) {
        guard configuration.adoptAgentsSessions, !id.isEmpty, tombstones[id] == nil, let pid = entry.pid,
            let cwd = entry.cwd, !cwd.isEmpty, entry.state != "failed", entry.state != "stopped",
            entry.kind == nil || entry.kind == "interactive" || entry.kind == "background"
        else { return }
        let phase: SessionPhase
        switch (entry.status, entry.state) {
        case ("busy"?, _), (nil, "working"?): phase = .working
        case ("waiting"?, _), (nil, "blocked"?): phase = entry.needsInputKind.map { .needsInput($0) } ?? .done
        case ("idle"?, _), (nil, "done"?): phase = .done
        default: phase = .idle
        }
        var session = Session(
            id: id, cwd: cwd, pid: pid, phase: phase, startedAt: entry.startedDate ?? now, updatedAt: now,
            phaseChangedAt: now)
        if let name = entry.name, !TitleResolver.isDefaultAgentsName(name, projectName: session.projectName) {
            session.titleCandidates.agentsName = name
        }
        sessions[id] = session
        meta[id] = SessionMeta()
        effects.append(.transcriptRefreshNeeded(sessionID: id))
    }

    // MARK: - Removal and parking

    /// SessionEnd (non-synthetic) or process exit. Desktop Code-tab rows are parked instead of removed.
    private mutating func endProcess(_ id: String, reason: String?, now: Date, effects: inout [SessionEffect]) {
        guard var session = sessions[id] else {
            tombstones[id] = now
            return
        }
        let parkable =
            configuration.desktopParkedLifetime > 0 && session.host.kind == .claudeDesktop && session.isVisible
            && session.phase != .idle && (reason == nil || reason == "other")
        guard parkable else {
            remove(id, now: now, effects: &effects)
            return
        }
        var meta = self.meta[id] ?? SessionMeta()
        clearPending(&session, &meta, effects: &effects)
        if session.phase == .working || session.phase.isNeedsInput { session.phase = .done }
        session.pid = nil
        session.pidStartTime = nil
        session.updatedAt = now
        meta.subagentIDs.removeAll()
        meta.parkedAt = now
        sessions[id] = session
        self.meta[id] = meta
    }

    private mutating func remove(_ id: String, now: Date, effects: inout [SessionEffect]) {
        tombstones[id] = now
        guard let session = sessions.removeValue(forKey: id) else { return }
        for requestID in session.pendingPermissionIDs where permissions.removeValue(forKey: requestID) != nil {
            effects.append(.permissionRemoved(requestID: requestID))
            effects.append(.replyPassthrough(requestID: requestID))
        }
        meta[id] = nil
        if session.isVisible { effects.append(.sessionRemoved(sessionID: id)) }
    }

    // MARK: - Helpers

    private mutating func update(_ id: String, _ body: (inout Session, inout SessionMeta) -> Void) {
        guard var session = sessions[id] else { return }
        var meta = self.meta[id] ?? SessionMeta()
        body(&session, &meta)
        sessions[id] = session
        self.meta[id] = meta
    }

    static func preview(_ message: String, length: Int) -> String {
        let flat = TitleResolver.collapseWhitespace(message)
        return flat.count > length ? String(flat.prefix(max(length - 1, 0))) + "…" : flat
    }

    /// Readable text for the ⚠ badge of a StopFailure.
    static func describeStopFailure(_ hook: HookPayload) -> String {
        if let message = hook.lastAssistantMessage { return preview(message, length: 140) }
        switch hook.error {
        case "rate_limit"?: return "Rate limit reached"
        case "overloaded"?: return "Claude is overloaded"
        case "authentication_failed"?, "oauth_org_not_allowed"?: return "Authentication failed"
        case "billing_error"?, "account_on_hold"?: return "Billing problem"
        case "invalid_request"?: return "Invalid request"
        case "model_not_found"?: return "Model not found"
        case "server_error"?: return "API server error"
        case "max_output_tokens"?: return "Output token limit reached"
        case let other?: return other
        case nil: return "The turn failed"
        }
    }

    /// Recomputes titles, subagent counts and title requests; emits appearance / removal / phase effects by
    /// diffing with `before`.
    private mutating func finalize(before: [String: Session], now: Date, effects: inout [SessionEffect]) {
        for id in sessions.keys.sorted() {
            guard var session = sessions[id] else { continue }
            var meta = self.meta[id] ?? SessionMeta()
            session.activeSubagents = meta.subagentIDs.count
            session.title = TitleResolver.resolve(
                session.titleCandidates, firstPrompt: session.firstPrompt, projectName: session.projectName)
            let old = before[id]
            if session.isVisible, old?.isVisible != true {
                effects.append(.sessionAppeared(sessionID: id))
            } else if old?.isVisible == true, !session.isVisible {
                effects.append(.sessionRemoved(sessionID: id))
            }
            if let old, old.phase != session.phase {
                session.phaseChangedAt = now
                if session.isVisible && old.isVisible {
                    effects.append(.phaseChanged(sessionID: id, from: old.phase, to: session.phase))
                }
            }
            requestTitleIfNeeded(id, session: session, meta: &meta, now: now, effects: &effects)
            sessions[id] = session
            self.meta[id] = meta
        }
    }

    private func requestTitleIfNeeded(
        _ id: String, session: Session, meta: inout SessionMeta, now: Date, effects: inout [SessionEffect]
    ) {
        guard session.isVisible, !meta.titleRequested else { return }
        let candidates = session.titleCandidates
        if configuration.compressLongNativeTitles && TitleResolver.needsCompression(candidates) {
            meta.titleRequested = true
            effects.append(.titleGenerationNeeded(sessionID: id))
            return
        }
        guard TitleResolver.needsGeneration(candidates, firstPrompt: session.firstPrompt) else { return }
        let sinceFirstPrompt = meta.firstPromptAt.map { now.timeIntervalSince($0) } ?? 0
        guard meta.completedTurns > 0 || sinceFirstPrompt >= configuration.titleGenerationGrace else { return }
        // Checkpoint: the transcript must have been read after the turn ended / after we asked for a re-read.
        let checkpoint = [meta.lastStopAt, meta.titleRefreshRequestedAt].compactMap { $0 }.max()
        let readSince = meta.lastTranscriptAt.map { read in checkpoint.map { read >= $0 } ?? false } ?? false
        let askedLongAgo = meta.titleRefreshRequestedAt.map {
            now.timeIntervalSince($0) >= configuration.titleGenerationGrace
        } ?? false
        if TitleResolver.shouldRequestGeneration(
            candidates, firstPrompt: session.firstPrompt, completedTurns: meta.completedTurns,
            secondsSinceFirstPrompt: sinceFirstPrompt, transcriptReadSinceCheckpoint: readSince,
            transcriptUnavailable: askedLongAgo, graceSeconds: configuration.titleGenerationGrace)
        {
            meta.titleRequested = true
            effects.append(.titleGenerationNeeded(sessionID: id))
        } else if meta.titleRefreshRequestedAt == nil {
            meta.titleRefreshRequestedAt = now
            if !effects.contains(.transcriptRefreshNeeded(sessionID: id)) {
                effects.append(.transcriptRefreshNeeded(sessionID: id))
            }
        }
    }
}

// MARK: - Private bookkeeping

private struct ToolUseRecord: Sendable {
    var toolUseID: String
    var toolName: String
    var input: JSONValue?
    var agentID: String?
}

private struct SessionMeta: Sendable {
    var titleRequested = false
    var titleRefreshRequestedAt: Date?
    var lastHookAt: Date?
    var lastTranscriptAt: Date?
    var lastStopAt: Date?
    var firstPromptAt: Date?
    var turnStartedAt: Date?
    var completedTurns = 0
    var subagentIDs: Set<String> = []
    var parkedAt: Date?
    /// PreToolUse calls, newest last (bounded).
    var recentToolUses: [ToolUseRecord] = []
    /// Pending request id → the `tool_use_id` of the PreToolUse it belongs to.
    var requestToolUseIDs: [String: String] = [:]

    mutating func resetConversation() {
        titleRequested = false
        titleRefreshRequestedAt = nil
        lastStopAt = nil
        firstPromptAt = nil
        turnStartedAt = nil
        completedTurns = 0
        subagentIDs = []
        recentToolUses = []
        requestToolUseIDs = [:]
    }

    mutating func rememberToolUse(_ hook: HookPayload, limit: Int) {
        guard let toolUseID = hook.toolUseID, let toolName = hook.toolName else { return }
        recentToolUses.append(
            ToolUseRecord(toolUseID: toolUseID, toolName: toolName, input: hook.toolInput, agentID: hook.agentID))
        if recentToolUses.count > limit { recentToolUses.removeFirst(recentToolUses.count - limit) }
    }

    /// Newest unlinked PreToolUse of the same agent, tool and input.
    func linkToolUse(for request: PermissionRequest) -> String? {
        let linked = Set(requestToolUseIDs.values)
        return recentToolUses.last { record in
            record.agentID == request.agentID && !linked.contains(record.toolUseID)
                && request.matches(toolName: record.toolName, toolInput: record.input)
        }?.toolUseID
    }
}

extension SessionPhase {
    /// `.working` or `.needsInput` (a turn is in flight).
    fileprivate var isActive: Bool {
        switch self {
        case .working, .needsInput: return true
        case .idle, .done: return false
        }
    }
}
