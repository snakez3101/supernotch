// Owner: claude-app. The v1 `SessionSource` (SPEC §D.1 seam): local Claude Code sessions.
//
// * Hook socket (`ClaudeHookSocketServer`) → `.hook` / `.permissionConnectionClosed`.
// * Drift correction while sessions exist (SPEC §E.3), one low-energy heartbeat every 10 s:
//   liveness (kill(pid, 0) + start time), `claude agents --json --all` every 20 s, `.tick` every 30 s.
// * `<config>/sessions/` watcher (process exit hints), Desktop-quit cleanup, re-check on wake.

import Foundation
import SuperNotchCore

final class ClaudeLocalSessionSource: SessionSource {
    let sourceID = "local"

    let socketPath: String
    let homeDirectory: String
    private(set) var configDirectory: String
    /// Why the socket could not be opened (shown in Settings); nil when listening.
    private(set) var serverError: String?

    private var server: ClaudeHookSocketServer?
    private var sink: (@MainActor (SessionEvent) -> Void)?
    private let sessionFiles = ClaudeSessionFileWatcher()
    private var heartbeatTask: Task<Void, Never>?
    private var beat = 0
    private var knownSessions: [Session] = []

    // `claude agents --json` state (SPEC §E.3: give up after 3 consecutive failures).
    private var agentsFailures = 0
    private var agentsDisabled = false
    private var agentsRunning = false

    nonisolated static let heartbeatInterval: TimeInterval = 10
    nonisolated static let agentsTimeout: TimeInterval = 5
    nonisolated static let maxAgentsFailures = 3

    /// Injected by the model (AppKit lives in `ClaudeSystemBridge`).
    var isDesktopAppRunning: () -> Bool = { true }

    init(socketPath: String, homeDirectory: String, configDirectory: String) {
        self.socketPath = socketPath
        self.homeDirectory = homeDirectory
        self.configDirectory = configDirectory
        sessionFiles.onProcessExit = { [weak self] pid in
            self?.sink?(.processExited(pid: pid))
        }
    }

    // MARK: - SessionSource

    func start(sink: @escaping @MainActor (SessionEvent) -> Void) {
        guard server == nil else { return }
        self.sink = sink
        let server = ClaudeHookSocketServer(path: socketPath)
        do {
            try server.start { event in
                // Socket queue → main queue, preserving arrival order.
                DispatchQueue.main.async { [weak self] in
                    self?.deliver(event)
                }
            }
            self.server = server
            serverError = nil
        } catch {
            serverError = "\(error)"
            Log.ipc.error("hook socket failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        sink = nil
        stopHeartbeat()
        sessionFiles.stop()
        knownSessions = []
    }

    var isListening: Bool { server != nil }

    // MARK: - Commands from the model

    /// Answers (or passes through, `decision == nil`) a held PermissionRequest connection.
    func reply(requestID: String, decision: PermissionDecision?) {
        server?.reply(requestID: requestID, decision: decision)
    }

    /// Called after every store change with all sessions (hidden ones need liveness cleanup too).
    func update(sessions: [Session]) {
        knownSessions = sessions
        if sessions.isEmpty {
            stopHeartbeat()
        } else {
            startHeartbeatIfNeeded()
            sessionFiles.start(directory: ClaudePaths(configDirectory: configDirectory).sessionsDirectory)
        }
    }

    func setConfigDirectory(_ directory: String) {
        guard directory != configDirectory else { return }
        configDirectory = directory
        sessionFiles.stop()
        if !knownSessions.isEmpty {
            sessionFiles.start(directory: ClaudePaths(configDirectory: directory).sessionsDirectory)
        }
    }

    /// After sleep: processes may have died and states drifted.
    func handleWake() {
        guard !knownSessions.isEmpty else { return }
        checkLiveness()
        pollAgents()
    }

    /// Claude Desktop quit: its sessions without a PID are gone (sessions with a PID follow liveness).
    func handleDesktopTerminated() {
        endPIDlessDesktopSessions()
        checkLiveness()
    }

    // MARK: - Delivery

    private func deliver(_ event: ClaudeHookSocketServer.Event) {
        guard let sink else {
            // Stopped meanwhile: never leave a hook hanging.
            if case .envelope(let envelope) = event, envelope.expectsReply {
                server?.reply(requestID: envelope.id, decision: nil)
            }
            return
        }
        switch event {
        case .envelope(let envelope):
            sink(.hook(envelope))
        case .connectionClosed(let requestID):
            sink(.permissionConnectionClosed(requestID: requestID))
        }
    }

    // MARK: - Heartbeat (only while sessions exist)

    private func startHeartbeatIfNeeded() {
        guard heartbeatTask == nil else { return }
        beat = 0
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval), tolerance: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                self.heartbeat()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func heartbeat() {
        beat += 1
        checkLiveness()
        if beat % 2 == 0 { pollAgents() }
        if beat % 3 == 0 { sink?(.tick) }
    }

    private func checkLiveness() {
        var exited = Set<Int32>()
        for session in knownSessions {
            guard let pid = session.pid, !exited.contains(pid) else { continue }
            if ClaudeProcessInspector.hasExited(pid: pid, expectedStartTime: session.pidStartTime) {
                exited.insert(pid)
            }
        }
        for pid in exited.sorted() {
            Log.claude.debug("process \(pid, privacy: .public) exited")
            sink?(.processExited(pid: pid))
        }
        if knownSessions.contains(where: { $0.pid == nil && $0.host.kind == .claudeDesktop }), !isDesktopAppRunning() {
            endPIDlessDesktopSessions()
        }
    }

    /// There is no reducer event for "session gone without a PID": synthesize the SessionEnd hook.
    private func endPIDlessDesktopSessions() {
        guard !isDesktopAppRunning() else { return }
        for session in knownSessions where session.pid == nil && session.host.kind == .claudeDesktop {
            var payload = JSONObject()
            payload["session_id"] = .string(session.id)
            payload["hook_event_name"] = .string(HookEventName.sessionEnd.rawValue)
            payload["reason"] = "other"
            let envelope = HookEnvelope(
                id: "supernotch.desktop-quit." + session.id, sentAt: Date().timeIntervalSince1970,
                event: .sessionEnd, expectsReply: false, context: HookContext(), payload: .object(payload))
            sink?(.hook(envelope))
        }
    }

    private func pollAgents() {
        guard !agentsDisabled, !agentsRunning, !knownSessions.isEmpty else { return }
        agentsRunning = true
        let home = homeDirectory
        let configDirectory = configDirectory
        let hint = knownSessions.lazy.compactMap(\.claudeExecutablePath).first { !$0.hasSuffix(".js") }
        Task { [weak self] in
            let entries = await Self.runAgentsList(homeDirectory: home, configDirectory: configDirectory, hint: hint)
            guard let self else { return }
            self.agentsRunning = false
            guard let entries else {
                self.agentsFailures += 1
                if self.agentsFailures >= Self.maxAgentsFailures {
                    self.agentsDisabled = true
                    Log.claude.info("`claude agents --json` unavailable; continuing with hooks only")
                }
                return
            }
            self.agentsFailures = 0
            self.sink?(.agentsSnapshot(entries))
        }
    }

    private nonisolated static func runAgentsList(homeDirectory: String, configDirectory: String, hint: String?)
        async -> [AgentsListEntry]?
    {
        let environment = ClaudeCLIEnvironment.shared
        let executable = await Task.detached(priority: .utility) {
            environment.claudeExecutable(homeDirectory: homeDirectory, hint: hint)
        }.value
        guard let executable else { return nil }
        guard
            let output = await ClaudeProcessRunner.run(
                executable: executable, arguments: ["agents", "--json", "--all"],
                environment: environment.environment(homeDirectory: homeDirectory, configDirectory: configDirectory),
                timeout: agentsTimeout),
            output.succeeded
        else { return nil }
        return try? AgentsListEntry.decodeList(output.stdout)
    }
}
