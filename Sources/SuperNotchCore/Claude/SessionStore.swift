import Foundation

// Owner: claude-core. Signatures FROZEN (SPEC §D.1); transition rules per SPEC §E.
// Baseline implementation by the foundation. claude-core owns hardening + the fixture test suite.
// Pure reducer: no clocks, no IO. The caller passes `now` and performs the returned effects.

public struct SessionStoreConfiguration: Sendable, Hashable {
    /// `working` with no event for this long ⇒ `isStale`.
    public var staleAfter: TimeInterval
    /// agents `status=idle` while we think `working` for longer than this since the last hook ⇒ done.
    public var agentsIdleGrace: TimeInterval
    /// Characters of `last_assistant_message` kept for the done peek.
    public var assistantPreviewLength: Int

    public init(staleAfter: TimeInterval = 600, agentsIdleGrace: TimeInterval = 10, assistantPreviewLength: Int = 140) {
        self.staleAfter = staleAfter
        self.agentsIdleGrace = agentsIdleGrace
        self.assistantPreviewLength = assistantPreviewLength
    }
}

public struct SessionStore: Sendable {
    public let configuration: SessionStoreConfiguration
    /// All known sessions keyed by session id, including hidden ones.
    public private(set) var sessions: [String: Session] = [:]
    /// Pending permission requests keyed by request id.
    public private(set) var permissions: [String: PermissionRequest] = [:]
    public private(set) var usage: UsageLimits?
    /// Sessions for which a Haiku title was already requested.
    private var titleRequested: Set<String> = []

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

    // MARK: - Reducer

    public mutating func apply(_ event: SessionEvent, now: Date) -> [SessionEffect] {
        var effects: [SessionEffect] = []
        let before = sessions
        switch event {
        case .hook(let envelope):
            applyHook(envelope, now: now, effects: &effects)
        case .permissionAnswered(let requestID, _):
            // Allow and deny both let Claude continue (deny feeds the message back to Claude).
            if let request = permissions.removeValue(forKey: requestID) {
                effects.append(.permissionRemoved(requestID: requestID))
                update(request.sessionID) { session in
                    session.pendingPermissionIDs.removeAll { $0 == requestID }
                    if session.pendingPermissionIDs.isEmpty { session.phase = .working }
                    session.updatedAt = now
                }
            }
        case .permissionConnectionClosed(let requestID):
            if let request = permissions.removeValue(forKey: requestID) {
                effects.append(.permissionRemoved(requestID: requestID))
                update(request.sessionID) { session in
                    session.pendingPermissionIDs.removeAll { $0 == requestID }
                    if session.pendingPermissionIDs.isEmpty, session.phase == .needsInput(.permission) {
                        session.phase = .working
                    }
                    session.updatedAt = now
                }
            }
        case .agentsSnapshot(let entries):
            applyAgents(entries, now: now, effects: &effects)
        case .processExited(let pid):
            for session in sessions.values where session.pid == pid {
                remove(session.id, effects: &effects)
            }
        case .transcript(let sessionID, let signals):
            update(sessionID) { session in
                if let custom = signals.customTitle { session.titleCandidates.customTitle = custom }
                if let ai = signals.aiTitle ?? signals.summary { session.titleCandidates.aiTitle = ai }
                if signals.interrupted, session.phase == .working { session.phase = .done }
            }
            requestTitleIfNeeded(sessionID, effects: &effects)
        case .titleGenerated(let sessionID, let title):
            update(sessionID) { $0.titleCandidates.generated = title }
        case .tick:
            for (id, session) in sessions where session.phase == .working && !session.isStale {
                if now.timeIntervalSince(session.updatedAt) >= configuration.staleAfter {
                    sessions[id]?.isStale = true
                }
            }
            if let current = usage {
                let pruned = current.pruned(now: now)
                if pruned != current {
                    usage = pruned.fiveHour == nil && pruned.sevenDay == nil ? nil : pruned
                    effects.append(.usageUpdated)
                }
            }
        }
        finalize(before: before, now: now, effects: &effects)
        return effects
    }

    // MARK: - Hooks

    private mutating func applyHook(_ envelope: HookEnvelope, now: Date, effects: inout [SessionEffect]) {
        if envelope.event == .statusLine {
            if let limits = UsageLimits.fromStatusLine(envelope.payload, now: now) {
                usage = limits
                effects.append(.usageUpdated)
            }
            return
        }
        let hook = envelope.hook
        let context = envelope.context
        guard let sessionID = hook.sessionID, !context.isRemote else {
            if envelope.expectsReply { effects.append(.replyPassthrough(requestID: envelope.id)) }
            return
        }
        if envelope.event == .sessionEnd {
            if envelope.expectsReply { effects.append(.replyPassthrough(requestID: envelope.id)) }
            remove(sessionID, effects: &effects)
            return
        }

        var session = sessions[sessionID] ?? makeSession(id: sessionID, envelope: envelope, now: now)
        absorbContext(envelope, into: &session)
        session.updatedAt = now
        session.isStale = false
        let isSubagentEvent = hook.agentID != nil

        switch envelope.event {
        case .sessionStart:
            if hook.source == "clear" {
                session.titleCandidates = TitleCandidates()
                session.firstPrompt = nil
                session.lastAssistantPreview = nil
                titleRequested.remove(sessionID)
                session.phase = .idle
            }
            if let title = hook.sessionTitle, !title.isEmpty { session.titleCandidates.sessionTitle = title }
            effects.append(.transcriptRefreshNeeded(sessionID: sessionID))

        case .userPromptSubmit:
            if !isSubagentEvent {
                session.phase = .working
                session.lastError = nil
                if session.firstPrompt == nil, let prompt = hook.prompt, !prompt.isEmpty {
                    session.firstPrompt = String(prompt.prefix(2_000))
                }
                if session.visibility == .hiddenUntilFirstPrompt { session.visibility = .visible }
                effects.append(.transcriptRefreshNeeded(sessionID: sessionID))
            }

        case .preToolUse where hook.toolName == "AskUserQuestion" && !isSubagentEvent:
            session.phase = .needsInput(.question)
            promoteIfPrewarmed(&session)

        case .preToolUse, .postToolUse, .postToolUseFailure, .subagentStart, .preCompact, .postCompact:
            if envelope.event == .subagentStart { session.activeSubagents += 1 }
            let resolved = resolvePermission(for: hook, session: &session, effects: &effects)
            // #98 rule: after Stop/idle, stray tool events do not revive the session.
            let revivable = session.phase != .done && session.phase != .idle
            if (revivable || resolved) && !session.phase.isNeedsInputWithPending(session.pendingPermissionIDs) {
                if case .needsInput(.question) = session.phase, envelope.event == .preToolUse, isSubagentEvent {
                    // A subagent working does not answer the parent's question.
                } else {
                    session.phase = .working
                }
            }
            promoteIfPrewarmed(&session)

        case .subagentStop:
            session.activeSubagents = max(0, session.activeSubagents - 1)

        case .permissionRequest:
            let visible = session.visibility == .visible || session.visibility == .hiddenUntilFirstPrompt
            if visible, let request = PermissionRequest(envelope: envelope, now: now) {
                promoteIfPrewarmed(&session)
                permissions[request.id] = request
                session.pendingPermissionIDs.append(request.id)
                session.phase = .needsInput(.permission)
                effects.append(.permissionAdded(requestID: request.id))
            } else if envelope.expectsReply {
                effects.append(.replyPassthrough(requestID: envelope.id))
            }

        case .permissionDenied:
            _ = resolvePermission(for: hook, session: &session, effects: &effects)
            if session.pendingPermissionIDs.isEmpty, session.phase.isNeedsInput { session.phase = .working }

        case .notification:
            let type = hook.notificationType ?? ""
            if NotificationType.needsInput.contains(type) {
                if session.pendingPermissionIDs.isEmpty {
                    session.phase = .needsInput(type == NotificationType.permissionPrompt ? .permission : .question)
                }
            } else if type == NotificationType.idlePrompt, !session.phase.isNeedsInput {
                session.phase = .done
            }

        case .stop:
            if !isSubagentEvent {
                session.phase = .done
                if let message = hook.lastAssistantMessage {
                    let flat = message.split(whereSeparator: \.isNewline).joined(separator: " ")
                    session.lastAssistantPreview = String(flat.prefix(configuration.assistantPreviewLength))
                }
                for requestID in session.pendingPermissionIDs {
                    permissions[requestID] = nil
                    effects.append(.permissionRemoved(requestID: requestID))
                    effects.append(.replyPassthrough(requestID: requestID))
                }
                session.pendingPermissionIDs = []
                effects.append(.transcriptRefreshNeeded(sessionID: sessionID))
            }

        case .stopFailure:
            session.phase = .done
            session.lastError = hook.error ?? "error"

        default:
            break  // Unknown / future events only refresh updatedAt.
        }

        sessions[sessionID] = session
        requestTitleIfNeeded(sessionID, effects: &effects)
    }

    private func makeSession(id: String, envelope: HookEnvelope, now: Date) -> Session {
        let context = envelope.context
        let host = SessionHost(context: context)
        let visibility: SessionVisibility
        if context.isInternal {
            visibility = .hiddenInternal
        } else if context.isPrintMode || (context.entrypoint?.hasPrefix("sdk") ?? false) {
            visibility = .hiddenHeadless
        } else if host.kind == .claudeDesktop && envelope.event == .sessionStart {
            visibility = .hiddenUntilFirstPrompt  // Desktop pre-warms throwaway sessions
        } else {
            visibility = .visible
        }
        return Session(
            id: id, cwd: envelope.hook.cwd ?? "", transcriptPath: envelope.hook.transcriptPath, host: host,
            visibility: visibility, startedAt: now)
    }

    private func absorbContext(_ envelope: HookEnvelope, into session: inout Session) {
        let hook = envelope.hook
        let context = envelope.context
        if let cwd = hook.cwd, !cwd.isEmpty, hook.agentID == nil { session.cwd = cwd }
        if let path = hook.transcriptPath, hook.agentID == nil { session.transcriptPath = path }
        if let pid = context.claudePID { session.pid = pid }
        if let start = context.claudeStartTime { session.pidStartTime = start }
        if let exe = context.claudeExecutablePath { session.claudeExecutablePath = exe }
        let host = SessionHost(context: context)
        if host.kind != .unknown || session.host.kind == .unknown { session.host = host }
    }

    private func promoteIfPrewarmed(_ session: inout Session) {
        if session.visibility == .hiddenUntilFirstPrompt { session.visibility = .visible }
    }

    /// Removes a pending permission of `session` matching tool name + input (PermissionRequest carries no
    /// tool_use_id). Returns true if one was resolved.
    private mutating func resolvePermission(for hook: HookPayload, session: inout Session,
        effects: inout [SessionEffect]) -> Bool
    {
        // PreToolUse precedes the prompt, so it never resolves one.
        guard hook.hookEventName != .preToolUse, !session.pendingPermissionIDs.isEmpty, let toolName = hook.toolName
        else { return false }
        let input = hook.toolInput
        guard
            let requestID = session.pendingPermissionIDs.first(where: { id in
                guard let request = permissions[id], request.toolName == toolName else { return false }
                return input == nil || request.toolInput == input
            })
        else { return false }
        permissions[requestID] = nil
        session.pendingPermissionIDs.removeAll { $0 == requestID }
        effects.append(.permissionRemoved(requestID: requestID))
        effects.append(.replyPassthrough(requestID: requestID))
        if session.pendingPermissionIDs.isEmpty { session.phase = .working }
        return true
    }

    // MARK: - Agents snapshot (drift correction)

    private mutating func applyAgents(_ entries: [AgentsListEntry], now: Date, effects: inout [SessionEffect]) {
        for entry in entries {
            guard let id = entry.sessionId, var session = sessions[id] else { continue }
            if let name = entry.name, !TitleResolver.isDefaultAgentsName(name, projectName: session.projectName) {
                session.titleCandidates.agentsName = name
            }
            if let pid = entry.pid, session.pid == nil { session.pid = pid }
            let sinceLastEvent = now.timeIntervalSince(session.updatedAt)
            switch (entry.status, entry.state) {
            case (_, "failed"?), (_, "stopped"?):
                remove(id, effects: &effects)
                continue
            case ("busy"?, _), (_, "working"?):
                if !session.phase.isNeedsInput { session.phase = .working }
            case ("waiting"?, _), (_, "blocked"?):
                if !session.phase.isNeedsInput {
                    let waiting = entry.waitingFor?.lowercased() ?? ""
                    session.phase = .needsInput(waiting.contains("permission") ? .permission : .question)
                }
            case ("idle"?, _), (_, "done"?):
                if session.phase == .working, sinceLastEvent > configuration.agentsIdleGrace { session.phase = .done }
            default:
                break
            }
            sessions[id] = session
        }
    }

    // MARK: - Helpers

    private mutating func update(_ id: String, _ body: (inout Session) -> Void) {
        guard var session = sessions[id] else { return }
        body(&session)
        sessions[id] = session
    }

    private mutating func remove(_ id: String, effects: inout [SessionEffect]) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        for requestID in session.pendingPermissionIDs where permissions.removeValue(forKey: requestID) != nil {
            effects.append(.permissionRemoved(requestID: requestID))
            effects.append(.replyPassthrough(requestID: requestID))
        }
        titleRequested.remove(id)
        if session.isVisible { effects.append(.sessionRemoved(sessionID: id)) }
    }

    private mutating func requestTitleIfNeeded(_ id: String, effects: inout [SessionEffect]) {
        guard let session = sessions[id], session.isVisible, !titleRequested.contains(id) else { return }
        if TitleResolver.needsGeneration(session.titleCandidates, firstPrompt: session.firstPrompt) {
            titleRequested.insert(id)
            effects.append(.titleGenerationNeeded(sessionID: id))
        }
    }

    /// Recomputes titles and emits appearance / phase-change effects by diffing with `before`.
    private mutating func finalize(before: [String: Session], now: Date, effects: inout [SessionEffect]) {
        for id in Array(sessions.keys) {
            guard var session = sessions[id] else { continue }
            session.title = TitleResolver.resolve(
                session.titleCandidates, firstPrompt: session.firstPrompt, projectName: session.projectName)
            let old = before[id]
            if session.isVisible, old?.isVisible != true {
                effects.append(.sessionAppeared(sessionID: id))
            }
            if let old, old.phase != session.phase {
                session.phaseChangedAt = now
                if session.isVisible && old.isVisible {
                    effects.append(.phaseChanged(sessionID: id, from: old.phase, to: session.phase))
                }
            }
            sessions[id] = session
        }
    }
}

extension SessionPhase {
    /// needsInput(.permission) that is still backed by a pending request.
    fileprivate func isNeedsInputWithPending(_ pending: [String]) -> Bool {
        if case .needsInput(.permission) = self { return !pending.isEmpty }
        return false
    }
}
