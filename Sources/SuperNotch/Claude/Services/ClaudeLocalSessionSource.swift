// Owner: claude-app. The v1 `SessionSource` (SPEC §D.1 seam): local Claude Code sessions.
//
// Event-driven first (SPEC §F.1):
// * Hook socket (`ClaudeHookSocketServer`) → `.hook` / `.permissionConnectionClosed`.
// * Liveness: one kqueue process-exit source per claude PID (no polling), plus a start-time check against
//   PID reuse when the source is created. `<config>/sessions/` removals are a second exit hint.
// * `.tick` for the store's watchdog (stale rows, parked Desktop rows, title grace, hidden-session cleanup):
//   about every 30 s (with timer tolerance) while any session exists, including hidden and parked ones; never
//   without sessions. Paused while the Mac sleeps or the screen is locked.
// * `claude agents --json --all` (SPEC §E.3): once shortly after launch and after wake/unlock (adopts sessions
//   that started while nothing was listening; headless and internal PIDs are dropped first), and as a slow
//   drift fallback while a 🟡/🔴 session has been silent for ≥ 60 s (backoff up to 5 min). Gives up after 3
//   consecutive failures.

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
    /// argv prefix of the user's Claude Code (latest `HookContext.claudeInvocation`), kept up to date by the model.
    var claudeInvocation: [String]?
    /// False in the smoke test (SPEC §D.10: never spawn `claude`).
    var allowsAgentsPolling = true

    private var server: ClaudeHookSocketServer?
    private var sink: (@MainActor (SessionEvent) -> Void)?
    private let sessionFiles = ClaudeSessionFileWatcher()
    private var exitWatchers: [Int32: ClaudeProcessExitWatcher] = [:]
    private var knownSessions: [Session] = []
    private var tickTask: Task<Void, Never>?
    private var launchPollTask: Task<Void, Never>?
    private var isPaused = false

    // `claude agents --json` (give up after 3 consecutive failures, SPEC §E.3).
    private var agentsFailures = 0
    private var agentsDisabled = false
    private var agentsRunning = false
    private var lastAgentsPoll: Date?
    private var agentsInterval: TimeInterval = ClaudeLocalSessionSource.minAgentsInterval

    nonisolated static let tickInterval: TimeInterval = 30
    nonisolated static let launchPollDelay: TimeInterval = 3
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
        // Sessions that were already running before SuperNotch started (app restart or update).
        launchPollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.launchPollDelay))
            guard !Task.isCancelled, let self else { return }
            self.launchPollTask = nil
            self.pollAgentsIfNeeded(force: true)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        sink = nil
        launchPollTask?.cancel()
        launchPollTask = nil
        stopTickTimer()
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
        updateTickTimer()
    }

    func setConfigDirectory(_ directory: String) {
        guard directory != configDirectory else { return }
        configDirectory = directory
        sessionFiles.stop()
        if !knownSessions.isEmpty {
            sessionFiles.start(directory: ClaudePaths(configDirectory: directory).sessionsDirectory)
        }
    }

    /// System sleep or screen lock: no ticks and no agents polls (processes and hooks keep their own events).
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            stopTickTimer()
        } else {
            recheckAfterPause()
            updateTickTimer()
        }
    }

    /// Claude Desktop quit: every Desktop session ended with it (running ones would otherwise be parked).
    func handleDesktopTerminated() {
        let now = Date()
        for session in knownSessions where session.host.kind == .claudeDesktop {
            sink?(.sessionEnded(sessionID: session.id, now: now))
        }
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
        endOrphanedDesktopSessions()
        agentsInterval = Self.minAgentsInterval
        pollAgentsIfNeeded(force: true)
    }

    /// Desktop sessions without a process (parked, or never had a pid) end when Claude Desktop is not running.
    private func endOrphanedDesktopSessions() {
        let orphans = knownSessions.filter { $0.pid == nil && $0.host.kind == .claudeDesktop }
        guard !orphans.isEmpty, !isDesktopAppRunning() else { return }
        let now = Date()
        for session in orphans {
            sink?(.sessionEnded(sessionID: session.id, now: now))
        }
    }

    // MARK: - Watchdog tick

    /// Sessions whose state can drift: visible and 🟡 or 🔴.
    private var hasActiveWork: Bool {
        knownSessions.contains { $0.isVisible && ($0.phase == .working || $0.phase.isNeedsInput) }
    }

    /// One tick loop while any session exists and the Mac is awake and unlocked.
    private func updateTickTimer() {
        guard !isPaused, sink != nil, !knownSessions.isEmpty else {
            stopTickTimer()
            return
        }
        guard tickTask == nil else { return }
        let interval = Self.tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 3))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func stopTickTimer() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        sink?(.tick)
        endOrphanedDesktopSessions()
        pollAgentsIfNeeded(force: false)
    }

    // MARK: - claude agents --json

    /// `force`: launch / wake (always, to adopt sessions). Otherwise only while a 🟡/🔴 session has been silent
    /// for a while, with backoff.
    private func pollAgentsIfNeeded(force: Bool) {
        guard allowsAgentsPolling, !agentsDisabled, !agentsRunning, !isPaused, sink != nil else { return }
        let now = Date()
        if !force {
            guard hasActiveWork else { return }
            if let last = lastAgentsPoll, now.timeIntervalSince(last) < agentsInterval { return }
            let silent = knownSessions.contains { session in
                session.isVisible && (session.phase == .working || session.phase.isNeedsInput)
                    && now.timeIntervalSince(session.updatedAt) >= Self.silenceBeforeAgentsPoll
            }
            guard silent else { return }
            agentsInterval = min(agentsInterval * 2, Self.maxAgentsInterval)
        }
        agentsRunning = true
        lastAgentsPoll = now
        let home = homeDirectory
        let configDirectory = configDirectory
        let invocation = claudeInvocation
        let hint = knownSessions.lazy.compactMap(\.claudeExecutablePath).first(where: ClaudeCLIEnvironment.isUsableHint)
        let knownIDs = Set(knownSessions.map(\.id))
        Task { [weak self] in
            let entries = await Self.runAgentsList(
                homeDirectory: home, configDirectory: configDirectory, invocation: invocation, hint: hint,
                knownIDs: knownIDs)
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
            guard !entries.isEmpty else { return }
            self.sink?(.agentsSnapshot(entries))
        }
    }

    /// Runs `claude agents --json --all` off the main thread. Entries for sessions the store does not know yet
    /// (adoption candidates) are dropped when their process is headless or internal (SPEC §E.2).
    private nonisolated static func runAgentsList(
        homeDirectory: String, configDirectory: String, invocation: [String]?, hint: String?, knownIDs: Set<String>
    ) async -> [AgentsListEntry]? {
        let timeout = agentsTimeout
        return await ClaudeBackground.run { () -> [AgentsListEntry]? in
            let environment = ClaudeCLIEnvironment.shared
            guard
                let command = environment.claudeInvocation(
                    homeDirectory: homeDirectory, reported: invocation, hint: hint),
                let executable = command.first,
                let output = ClaudeProcessRunner.runSync(
                    executable: executable, arguments: Array(command.dropFirst()) + ["agents", "--json", "--all"],
                    environment: environment.environment(homeDirectory: homeDirectory, configDirectory: configDirectory),
                    currentDirectory: homeDirectory, timeout: timeout),
                output.succeeded,
                let entries = try? AgentsListEntry.decodeList(output.stdout)
            else { return nil }
            return entries.filter { entry in
                guard let id = entry.sessionId, !knownIDs.contains(id), let pid = entry.pid else { return true }
                return !ClaudeProcessInspector.isHiddenClaudeProcess(pid: pid)
            }
        }
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
            // Not class-bound (no `[weak source]`); cancelling in the handler (or `cancel()`/`deinit`) breaks
            // the cycle.
            source.setEventHandler {
                source.cancel()
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
