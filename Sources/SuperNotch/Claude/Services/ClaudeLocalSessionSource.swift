// Owner: claude-app. The v1 `SessionSource` (SPEC §D.1 seam): local Claude Code sessions.
//
// Event-driven first (SPEC §F.1):
// * Hook socket (`ClaudeHookSocketServer`) → `.hook` / `.permissionConnectionClosed`.
// * Liveness: one kqueue process-exit source per claude PID (no polling), plus a start-time check against
//   PID reuse when the source is created. `<config>/sessions/` removals are a second exit hint.
// * Drift correction (SPEC §E.3) is a slow fallback that runs only while a visible session is 🟡 or 🔴:
//   every 60 s a `.tick`, and `claude agents --json --all` only when such a session has been silent for
//   ≥ 60 s (backoff up to 5 min). Paused while the Mac sleeps or the screen is locked.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class ClaudeLocalSessionSource: SessionSource {
    let sourceID = "local"

    let socketPath: String
    let homeDirectory: String
    private(set) var configDirectory: String
    /// Why the socket could not be opened (shown in Settings); nil when listening.
    private(set) var serverError: String?

    /// Injected by the model (AppKit lives in `ClaudeSystemBridge`).
    var isDesktopAppRunning: () -> Bool = { true }

    private var server: ClaudeHookSocketServer?
    private var sink: (@MainActor (SessionEvent) -> Void)?
    private let sessionFiles = ClaudeSessionFileWatcher()
    private var exitWatchers: [Int32: ClaudeProcessExitWatcher] = [:]
    private var knownSessions: [Session] = []
    private var driftTask: Task<Void, Never>?
    private var isPaused = false

    // `claude agents --json` (fallback only; give up after 3 consecutive failures, SPEC §E.3).
    private var agentsFailures = 0
    private var agentsDisabled = false
    private var agentsRunning = false
    private var lastAgentsPoll: Date?
    private var agentsInterval: TimeInterval = ClaudeLocalSessionSource.minAgentsInterval

    nonisolated static let driftInterval: TimeInterval = 60
    nonisolated static let silenceBeforeAgentsPoll: TimeInterval = 60
    nonisolated static let minAgentsInterval: TimeInterval = 60
    nonisolated static let maxAgentsInterval: TimeInterval = 300
    nonisolated static let agentsTimeout: TimeInterval = 5
    nonisolated static let maxAgentsFailures = 3

    init(socketPath: String, homeDirectory: String, configDirectory: String) {
        self.socketPath = socketPath
        self.homeDirectory = homeDirectory
        self.configDirectory = configDirectory
        sessionFiles.onProcessExit = { [weak self] pid in
            self?.processExited(pid)
        }
    }

    // MARK: - SessionSource

    func start(sink: @escaping @MainActor (SessionEvent) -> Void) {
        guard server == nil else { return }
        self.sink = sink
        let server = ClaudeHookSocketServer(path: socketPath)
        do {
            try server.start { [weak self] event in
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
        stopDriftTimer()
        sessionFiles.stop()
        for watcher in exitWatchers.values { watcher.cancel() }
        exitWatchers = [:]
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
        let hadSessions = !knownSessions.isEmpty
        knownSessions = sessions
        syncExitWatchers()
        if sessions.isEmpty {
            sessionFiles.stop()
        } else {
            sessionFiles.start(directory: ClaudePaths(configDirectory: configDirectory).sessionsDirectory)
            if !hadSessions { agentsInterval = Self.minAgentsInterval }
        }
        updateDriftTimer()
    }

    func setConfigDirectory(_ directory: String) {
        guard directory != configDirectory else { return }
        configDirectory = directory
        sessionFiles.stop()
        if !knownSessions.isEmpty {
            sessionFiles.start(directory: ClaudePaths(configDirectory: directory).sessionsDirectory)
        }
    }

    /// System sleep or screen lock: stop the drift timer (processes and hooks keep their own events).
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            stopDriftTimer()
        } else {
            recheckAfterPause()
            updateDriftTimer()
        }
    }

    /// Claude Desktop quit: its sessions without a PID are gone (sessions with a PID follow liveness).
    func handleDesktopTerminated() {
        endPIDlessDesktopSessions()
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

    private func processExited(_ pid: Int32) {
        exitWatchers.removeValue(forKey: pid)?.cancel()
        guard knownSessions.contains(where: { $0.pid == pid }) else { return }
        Log.claude.debug("claude process \(pid, privacy: .public) exited")
        sink?(.processExited(pid: pid))
    }

    // MARK: - Liveness (kqueue, no polling)

    private func syncExitWatchers() {
        var wanted: [Int32: Double?] = [:]
        for session in knownSessions {
            if let pid = session.pid, pid > 0 { wanted[pid] = session.pidStartTime }
        }
        for (pid, watcher) in exitWatchers where wanted[pid] == nil {
            watcher.cancel()
            exitWatchers[pid] = nil
        }
        for (pid, startTime) in wanted where exitWatchers[pid] == nil {
            if ClaudeProcessInspector.hasExited(pid: pid, expectedStartTime: startTime) {
                // Already gone (or the PID was reused): report on the next main-queue turn.
                DispatchQueue.main.async { [weak self] in
                    self?.processExited(pid)
                }
                continue
            }
            let watcher = ClaudeProcessExitWatcher(pid: pid) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.processExited(pid)
                }
            }
            exitWatchers[pid] = watcher
        }
    }

    /// After sleep / unlock: exit events were delivered while paused, but double-check cheaply.
    private func recheckAfterPause() {
        for session in knownSessions {
            guard let pid = session.pid else { continue }
            if ClaudeProcessInspector.hasExited(pid: pid, expectedStartTime: session.pidStartTime) {
                processExited(pid)
            }
        }
        endPIDlessDesktopSessions()
        agentsInterval = Self.minAgentsInterval
        pollAgentsIfNeeded(force: true)
    }

    /// There is no reducer event for "session gone without a PID": send a synthetic SessionEnd.
    private func endPIDlessDesktopSessions() {
        let orphans = knownSessions.filter { $0.pid == nil && $0.host.kind == .claudeDesktop }
        guard !orphans.isEmpty, !isDesktopAppRunning() else { return }
        let now = Date()
        for session in orphans {
            sink?(.hook(.synthetic(.sessionEnd, sessionID: session.id, now: now, fields: [("reason", "other")])))
        }
    }

    // MARK: - Drift correction (slow fallback)

    /// Sessions whose state can drift: visible and 🟡 or 🔴.
    private var hasActiveWork: Bool {
        knownSessions.contains { $0.isVisible && ($0.phase == .working || $0.phase.isNeedsInput) }
    }

    private func updateDriftTimer() {
        if hasActiveWork && !isPaused {
            guard driftTask == nil else { return }
            driftTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.driftInterval), tolerance: .seconds(15))
                    guard !Task.isCancelled, let self else { return }
                    self.driftTick()
                }
            }
        } else {
            stopDriftTimer()
        }
    }

    private func stopDriftTimer() {
        driftTask?.cancel()
        driftTask = nil
    }

    private func driftTick() {
        sink?(.tick)
        endPIDlessDesktopSessions()
        pollAgentsIfNeeded(force: false)
    }

    /// Polls `claude agents --json --all` when a 🟡/🔴 session has been silent for a while (with backoff).
    private func pollAgentsIfNeeded(force: Bool) {
        guard !agentsDisabled, !agentsRunning, hasActiveWork else { return }
        let now = Date()
        if !force {
            if let last = lastAgentsPoll, now.timeIntervalSince(last) < agentsInterval { return }
            let silent = knownSessions.contains { session in
                session.isVisible && (session.phase == .working || session.phase.isNeedsInput)
                    && now.timeIntervalSince(session.updatedAt) >= Self.silenceBeforeAgentsPoll
            }
            guard silent else { return }
        }
        agentsRunning = true
        lastAgentsPoll = now
        agentsInterval = min(agentsInterval * 2, Self.maxAgentsInterval)
        let home = homeDirectory
        let configDirectory = configDirectory
        let hint = knownSessions.lazy.compactMap(\.claudeExecutablePath).first(where: ClaudeCLIEnvironment.isUsableHint)
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
        return await Task.detached(priority: .utility) { () -> [AgentsListEntry]? in
            guard let executable = environment.claudeExecutable(homeDirectory: homeDirectory, hint: hint),
                let output = ClaudeProcessRunner.runSync(
                    executable: executable, arguments: ["agents", "--json", "--all"],
                    environment: environment.environment(
                        homeDirectory: homeDirectory, configDirectory: configDirectory),
                    currentDirectory: homeDirectory, timeout: agentsTimeout),
                output.succeeded,
                output.stdout.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x09 && $0 != 0x0D }) == 0x5B  // "["
            else { return nil }
            return try? AgentsListEntry.decodeList(output.stdout)
        }.value
    }
}

/// kqueue-backed "process exited" notification for one PID (Darwin). No polling.
nonisolated final class ClaudeProcessExitWatcher: @unchecked Sendable {
    #if canImport(Darwin)
        private let source: DispatchSourceProcess
    #endif

    private static let queue = DispatchQueue(label: "io.github.snakez3101.supernotch.claude.exit", qos: .utility)

    init(pid: Int32, onExit: @escaping @Sendable () -> Void) {
        #if canImport(Darwin)
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: Self.queue)
            source.setEventHandler { [weak source] in
                source?.cancel()
                onExit()
            }
            self.source = source
            source.resume()
        #endif
    }

    func cancel() {
        #if canImport(Darwin)
            source.cancel()
        #endif
    }

    deinit { cancel() }
}
