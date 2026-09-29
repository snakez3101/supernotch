// Owner: claude-app. The app-side Claude model (SPEC §D.4, frozen API) and the glue around Core's pure
// `SessionStore` reducer:
//
//   ClaudeLocalSessionSource (socket, liveness, agents, tick) ─┐
//   transcript reads, Haiku titles, the user's answers ────────┼─► SessionStore.apply ─► effects ─► popups,
//                                                              ┘                                  replies,
//                                                                                                 titles…
// Core owns the session rules (AskUserQuestion pass-through, stale cards, title timing); this file performs
// effects. State survives restarts: usage in `UserDefaults` (`sn.claude.usage`, SPEC §D.9), visible sessions
// in `claude-sessions.json` (Application Support), both restored on start. Liveness then drops dead ones.
// Foundation + Observation only: AppKit lives in ClaudeSystemBridge / ClaudeSessionFocuser.

import Foundation
import Observation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Observable
final class ClaudeSessionsModel {

    // MARK: - Frozen API (SPEC §D.4)

    /// Visible sessions, sorted red › yellow › green › grey, then most recent phase change first.
    private(set) var sessions: [Session] = []
    /// Pending permission requests of visible sessions, oldest first.
    private(set) var permissions: [PermissionRequest] = []
    /// Latest usage limits (statusLine bridge), pruned when windows reset, kept across restarts.
    private(set) var usage: UsageLimits?
    /// Most urgent light across visible sessions (nil without sessions).
    private(set) var aggregateLight: TrafficLight?
    private(set) var hookStatus: ClaudeHookStatus = .unknown

    var hasActiveSessions: Bool { !sessions.isEmpty }

    /// Usage at or above the warning threshold (closed-notch warning dot, orange bars).
    var isUsageWarning: Bool {
        let current = settings.settings
        guard current.claudeEnabled, current.showUsageLimits, let usage else { return false }
        return usage.isWarning(threshold: current.usageWarningThreshold)
    }

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    func permission(id: String) -> PermissionRequest? {
        permissions.first { $0.id == id }
    }

    /// Answers a permission card: replies on the held hook connection, then updates the store.
    func answer(requestID: String, decision: PermissionDecision) {
        guard store.permissions[requestID] != nil else {
            Log.claude.info("answer for a request that is already gone")
            notch.withdraw(popupID: PopupRequest.claudePermissionID(requestID))
            return
        }
        source?.reply(requestID: requestID, decision: decision)
        apply(.permissionAnswered(requestID: requestID, decision: decision))
    }

    /// "Answer in the chat instead": releases the held hook (Claude Code shows its own prompt) and jumps to the
    /// session. The row stays 🔴 because the native prompt is now waiting there.
    func answerInChat(requestID: String) {
        guard let request = store.permissions[requestID] else { return }
        source?.reply(requestID: requestID, decision: nil)
        apply(.permissionConnectionClosed(requestID: requestID))
        apply(
            .hook(
                .synthetic(
                    .notification, sessionID: request.sessionID, now: Date(),
                    fields: [("notification_type", .string(NotificationType.permissionPrompt))])))
        focus(sessionID: request.sessionID)
    }

    /// Jump to chat (SPEC §D.8): Claude Desktop deep link or the hosting terminal, best effort.
    func focus(sessionID: String) {
        guard let session = store.sessions[sessionID] else { return }
        notch.withdraw(popupID: PopupRequest.claudeSessionID(sessionID))
        focuser.focus(session, hostAppPath: hostAppPaths[sessionID])
    }

    // MARK: - Extra state for Settings / onboarding

    /// An install / uninstall / repair is running.
    private(set) var isHookOperationRunning = false
    /// Result of the last hook operation ("Hooks installed.", or the error).
    private(set) var hookMessage: String?
    /// Backup written by the last operation.
    private(set) var lastBackupPath: String?
    /// The exact JSON our entries add (onboarding / settings preview).
    private(set) var hookPreview = ""
    /// Resolved Claude config folder (override › $CLAUDE_CONFIG_DIR › ~/.claude).
    private(set) var configDirectory: String
    /// Config folders reported by hooks (CLAUDE_CONFIG_DIR) that differ from `configDirectory`.
    private(set) var detectedConfigDirectories: [String] = []
    /// Extra config folders we installed into, with their status.
    private(set) var extraConfigStatuses: [String: ClaudeHookStatus] = [:]
    /// "2.1.268" when `claude --version` could be read.
    private(set) var claudeVersionText: String?
    /// False when no `claude` executable was found.
    private(set) var isClaudeCLIFound = true
    /// Why the hook socket is not listening (nil when fine).
    private(set) var socketError: String?

    var settingsFilePath: String { ClaudePaths(configDirectory: configDirectory).settingsFile }
    var backupDirectory: String { paths.settingsBackupDirectory }

    // MARK: - Dependencies and internal state

    let settings: SettingsStore
    let notch: NotchViewModel
    @ObservationIgnored private let paths: SuperNotchPaths
    @ObservationIgnored private let installer: ClaudeHookInstaller
    @ObservationIgnored private let titleGenerator: ClaudeTitleGenerator
    @ObservationIgnored private let focuser: ClaudeSessionFocuser
    @ObservationIgnored private let transcriptWatcher = ClaudeTranscriptWatcher()

    @ObservationIgnored private var store = SessionStore()
    @ObservationIgnored private var source: ClaudeLocalSessionSource?
    @ObservationIgnored private var workspaceObserver: ClaudeWorkspaceObserver?
    @ObservationIgnored private var settingsToken: SettingsStore.ObserverToken?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var pendingEvents: [SessionEvent] = []
    @ObservationIgnored private var usageExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptReadsInFlight: Set<String> = []
    @ObservationIgnored private var transcriptReadsDirty: Set<String> = []
    @ObservationIgnored private var watchedTranscripts: [String: String] = [:]
    /// Per session, from the hook context: the argv prefix that runs its Claude Code and its GUI host app.
    @ObservationIgnored private var invocations: [String: [String]] = [:]
    @ObservationIgnored private var hostAppPaths: [String: String] = [:]
    @ObservationIgnored private var latestInvocation: [String]?
    @ObservationIgnored private var setupGeneration = 0
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var discoveryRunning = false

    static let usageDefaultsKey = "sn.claude.usage"
    static let extraConfigDirectoriesKey = "sn.claude-app.extraConfigDirectories"
    static let smokeTestEnvironmentKey = "SUPERNOTCH_SMOKE_TEST"
    static let sessionsFileName = "claude-sessions.json"
    /// Persisted sessions older than this are not restored.
    static let sessionsMaxAge: TimeInterval = 7 * 86_400

    init(settings: SettingsStore, notch: NotchViewModel) {
        self.settings = settings
        self.notch = notch
        let home = NSHomeDirectory()
        let paths = SuperNotchPaths(homeDirectory: home)
        self.paths = paths
        installer = ClaudeHookInstaller(paths: paths, appVersion: Self.appVersion)
        titleGenerator = ClaudeTitleGenerator(paths: paths)
        focuser = ClaudeSessionFocuser(homeDirectory: home)
        configDirectory = Self.resolveConfigDirectory(settings.settings, homeDirectory: home)
        store.restoreUsage(Self.loadPersistedUsage(), now: Date())
        usage = store.usage
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        titleGenerator.onTitle = { [weak self] sessionID, title in
            self?.apply(.titleGenerated(sessionID: sessionID, title: title))
        }
        titleGenerator.isStillNeeded = { [weak self] sessionID in
            self?.titleStillNeeded(sessionID) ?? false
        }
        transcriptWatcher.onChange = { [weak self] sessionID in
            self?.refreshTranscript(sessionID)
        }
        settingsToken = settings.observe { [weak self] old, new in
            self?.settingsChanged(old: old, new: new)
        }
        workspaceObserver = ClaudeWorkspaceObserver(
            onPauseChange: { [weak self] paused in
                self?.isPaused = paused
                self?.source?.setPaused(paused)
            },
            onApplicationTerminated: { [weak self] bundleID in
                if bundleID == SessionHost.claudeDesktopBundleID { self?.source?.handleDesktopTerminated() }
            })
        if settings.settings.claudeEnabled {
            startSource()
            restorePersistedSessions()
        }
        refreshSetup(syncBinary: !Self.isSmokeTest, allowRepair: !Self.isSmokeTest)
        scheduleUsageExpiry()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        persistSessions()
        persistUsage()
        settingsToken?.cancel()
        settingsToken = nil
        workspaceObserver?.invalidate()
        workspaceObserver = nil
        stopSource()
        usageExpiryTask?.cancel()
        usageExpiryTask = nil
        titleGenerator.cancelAll()
        titleGenerator.onTitle = nil
        titleGenerator.isStillNeeded = nil
        transcriptWatcher.onChange = nil
    }

    private func startSource() {
        guard source == nil else { return }
        let path = SocketPath.resolve(
            homeDirectory: paths.homeDirectory, uid: UInt32(getuid()), environment: ProcessInfo.processInfo.environment)
        let source = ClaudeLocalSessionSource(
            socketPath: path, homeDirectory: paths.homeDirectory, configDirectory: configDirectory)
        source.isDesktopAppRunning = {
            ClaudeSystemBridge.isApplicationRunning(bundleID: SessionHost.claudeDesktopBundleID)
        }
        source.claudeInvocation = latestInvocation
        source.allowsAgentsPolling = !Self.isSmokeTest
        source.start { [weak self] event in
            self?.apply(event)
        }
        source.setPaused(isPaused)
        self.source = source
        socketError = source.serverError
    }

    /// Stops listening (held hooks fail open) and forgets every session (usage is kept).
    private func stopSource() {
        source?.stop()
        source = nil
        socketError = nil
        transcriptWatcher.stopAll()
        watchedTranscripts = [:]
        for request in store.permissions.values {
            notch.withdraw(popupID: PopupRequest.claudePermissionID(request.id))
        }
        for id in store.sessions.keys {
            notch.withdraw(popupID: PopupRequest.claudeSessionID(id))
        }
        let currentUsage = store.usage
        store = SessionStore()
        store.restoreUsage(currentUsage, now: Date())
        invocations = [:]
        hostAppPaths = [:]
        publish()
    }

    // MARK: - Event pipeline

    /// Applies events in order; events raised while applying (effects) are queued behind.
    private func apply(_ event: SessionEvent) {
        pendingEvents.append(event)
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        while !pendingEvents.isEmpty {
            applyNow(pendingEvents.removeFirst())
        }
    }

    private func applyNow(_ event: SessionEvent) {
        if case .hook(let envelope) = event {
            noteConfigDirectory(
                ClaudeConfigDiscovery.configDirectory(fromTranscriptPath: envelope.hook.transcriptPath)
                    ?? envelope.context.claudeConfigDir)
            noteProcessInfo(envelope)
        }
        let now = Date()
        let effects = store.apply(event, now: now)
        publish()
        perform(effects, now: now)
        syncSourceAndWatches()
    }

    private func syncSourceAndWatches() {
        source?.update(sessions: Array(store.sessions.values))
        updateTranscriptWatches()
    }

    /// Copies the store's derived state into observable properties (only when changed).
    private func publish() {
        let visible = store.visibleSessions
        if visible != sessions { sessions = visible }
        let pending = store.pendingPermissions
        if pending != permissions { permissions = pending }
        let light = store.aggregateLight
        if light != aggregateLight { aggregateLight = light }
        let current = store.usage.flatMap { Self.pruned($0, now: Date()) }
        if current != usage { usage = current }
    }

    private func perform(_ effects: [SessionEffect], now: Date) {
        for effect in effects {
            switch effect {
            case .sessionAppeared(let sessionID):
                sessionAppeared(sessionID, now: now)
            case .sessionRemoved(let sessionID):
                sessionRemoved(sessionID)
            case .phaseChanged(let sessionID, let from, let to):
                phaseChanged(sessionID, from: from, to: to, now: now)
            case .permissionAdded(let requestID):
                presentPermission(requestID, now: now)
            case .permissionRemoved(let requestID):
                notch.withdraw(popupID: PopupRequest.claudePermissionID(requestID))
            case .replyPassthrough(let requestID):
                source?.reply(requestID: requestID, decision: nil)
            case .titleGenerationNeeded(let sessionID):
                scheduleTitleGeneration(sessionID)
            case .transcriptRefreshNeeded(let sessionID):
                refreshTranscript(sessionID)
            case .usageUpdated:
                persistUsage()
                scheduleUsageExpiry()
            @unknown default:
                break
            }
        }
    }

    /// Hook context facts the store does not keep: how to run this Claude Code, and which app hosts it.
    private func noteProcessInfo(_ envelope: HookEnvelope) {
        let context = envelope.context
        guard !context.isInternal, let sessionID = envelope.hook.sessionID else { return }
        if let invocation = context.claudeInvocation, !invocation.isEmpty {
            invocations[sessionID] = invocation
            if latestInvocation != invocation {
                latestInvocation = invocation
                source?.claudeInvocation = invocation
            }
        }
        if let hostApp = context.hostAppPath, !hostApp.isEmpty { hostAppPaths[sessionID] = hostApp }
    }

    // MARK: - Popups (SPEC §A.6)

    private func sessionAppeared(_ sessionID: String, now: Date) {
        if let cached = titleGenerator.cachedTitle(for: sessionID) {
            apply(.titleGenerated(sessionID: sessionID, title: cached))
        }
        // A pre-warmed Desktop session can become visible directly in a needs-input state.
        if let session = store.sessions[sessionID], session.phase.isNeedsInput, !hasCard(for: session) {
            presentNeedsInput(session, now: now)
        }
    }

    private func sessionRemoved(_ sessionID: String) {
        titleGenerator.cancel(sessionID: sessionID)
        invocations[sessionID] = nil
        hostAppPaths[sessionID] = nil
        notch.withdraw(popupID: PopupRequest.claudeSessionID(sessionID))
    }

    private func phaseChanged(_ sessionID: String, from: SessionPhase, to: SessionPhase, now: Date) {
        let popupID = PopupRequest.claudeSessionID(sessionID)
        switch to {
        case .done:
            if from.isNeedsInput { notch.withdraw(popupID: popupID) }
            // 🟢 only for a turn that actually ran (not idle → done on an idle_prompt of a resumed session).
            guard from == .working || from.isNeedsInput else { return }
            presentDone(sessionID, now: now)
        case .working, .idle:
            notch.withdraw(popupID: popupID)
        case .needsInput(let kind):
            guard let session = store.sessions[sessionID] else { return }
            if kind == .permission, hasCard(for: session) {
                notch.withdraw(popupID: popupID)  // The permission card covers it.
            } else {
                presentNeedsInput(session, now: now)
            }
        }
    }

    /// 🟢 peek. The shell's popup queue holds `.info` requests back for `NotchMetrics.popupDebounce`, and a 🟢 that
    /// turns 🟡 again is withdrawn above, so a quick flip never pops up (SPEC §A.6).
    private func presentDone(_ sessionID: String, now: Date) {
        let current = settings.settings
        guard current.claudeEnabled, current.popupOnDone, let session = store.sessions[sessionID], session.isVisible
        else { return }
        notch.present(
            .claudeDone(
                sessionID: sessionID, hostAppBundleID: ClaudeHostApps.bundleID(for: session.host),
                autoDismissAfter: current.doneAutoCollapse, now: now))
    }

    private func presentNeedsInput(_ session: Session, now: Date) {
        let current = settings.settings
        guard current.claudeEnabled, current.popupOnNeedsInput, session.isVisible else { return }
        notch.present(
            .claudeNeedsInput(
                sessionID: session.id, hostAppBundleID: ClaudeHostApps.bundleID(for: session.host), now: now))
    }

    private func presentPermission(_ requestID: String, now: Date) {
        guard let request = store.permissions[requestID] else { return }
        let session = store.sessions[request.sessionID]
        let current = settings.settings
        let expanded = notch.presentation.isExpanded
        let canShowCard = current.claudeEnabled && notch.geometry != nil && (current.popupOnNeedsInput || expanded)
        guard canShowCard else {
            // Nobody will see a card: never hold the hook (Claude Code shows its own prompt).
            source?.reply(requestID: requestID, decision: nil)
            apply(.permissionConnectionClosed(requestID: requestID))
            return
        }
        guard current.popupOnNeedsInput else { return }  // Expanded: the inline card in Home shows it.
        let host = session.flatMap { ClaudeHostApps.bundleID(for: $0.host) }
        notch.present(.claudePermission(requestID: requestID, hostAppBundleID: host, now: now))
    }

    /// The session has a pending Allow/Deny card.
    private func hasCard(for session: Session) -> Bool {
        session.pendingPermissionIDs.contains { store.permissions[$0] != nil }
    }

    // MARK: - Transcripts

    /// `transcript_path` from the hooks, or the derived path for a session adopted from `claude agents`.
    private func transcriptPath(for session: Session) -> String? {
        if let path = session.transcriptPath, !path.isEmpty { return path }
        return ClaudePaths(configDirectory: configDirectory).transcriptFile(cwd: session.cwd, sessionID: session.id)
    }

    private func refreshTranscript(_ sessionID: String) {
        guard let session = store.sessions[sessionID], transcriptPath(for: session) != nil else { return }
        if transcriptReadsInFlight.contains(sessionID) {
            transcriptReadsDirty.insert(sessionID)
            return
        }
        Task { [weak self] in
            await self?.loadTranscript(sessionID)
        }
    }

    /// Reads the transcript off the main thread and applies new signals (identical reads are skipped).
    private func loadTranscript(_ sessionID: String) async {
        guard let session = store.sessions[sessionID], let path = transcriptPath(for: session),
            !transcriptReadsInFlight.contains(sessionID)
        else { return }
        transcriptReadsInFlight.insert(sessionID)
        let signals = await ClaudeBackground.run {
            ClaudeTranscriptReader.readSignals(path: path)
        }
        transcriptReadsInFlight.remove(sessionID)
        // Always report a successful read (even if unchanged): the store's title timing waits for a read after
        // each turn. Identical results are cheap for the reducer.
        if let signals, store.sessions[sessionID] != nil {
            apply(.transcript(sessionID: sessionID, signals))
        }
        if transcriptReadsDirty.remove(sessionID) != nil { refreshTranscript(sessionID) }
    }

    /// Transcripts are watched only while their session works (interrupt marker, fresh ai-title).
    private func updateTranscriptWatches() {
        var targets: [String: String] = [:]
        for session in store.sessions.values where session.isVisible && session.phase == .working {
            if let path = transcriptPath(for: session) { targets[session.id] = path }
        }
        guard targets != watchedTranscripts else { return }
        watchedTranscripts = targets
        transcriptWatcher.update(targets: targets)
    }

    // MARK: - Titles (SPEC §E.4)

    /// The store asks only when Claude Code produced no title of its own after its first turn (Core's timing
    /// rules); the generator re-checks `titleStillNeeded` right before spawning `claude -p`.
    private func scheduleTitleGeneration(_ sessionID: String) {
        if let cached = titleGenerator.cachedTitle(for: sessionID) {
            apply(.titleGenerated(sessionID: sessionID, title: cached))
            return
        }
        guard settings.settings.generateTitlesWithHaiku, !Self.isSmokeTest, let session = store.sessions[sessionID],
            session.isVisible,
            let text = TitleResolver.generationSource(session.titleCandidates, firstPrompt: session.firstPrompt)
        else { return }
        titleGenerator.enqueue(
            ClaudeTitleGenerator.Request(
                sessionID: sessionID, sourceText: text, invocation: invocations[sessionID] ?? latestInvocation,
                executableHint: session.claudeExecutablePath, configDirectory: configDirectory))
    }

    private func titleStillNeeded(_ sessionID: String) -> Bool {
        guard isStarted, settings.settings.generateTitlesWithHaiku, let session = store.sessions[sessionID],
            session.isVisible
        else { return false }
        let candidates = session.titleCandidates
        return TitleResolver.needsGeneration(candidates, firstPrompt: session.firstPrompt)
            || (store.configuration.compressLongNativeTitles && TitleResolver.needsCompression(candidates))
    }

    // MARK: - Persistence (usage: SPEC §D.9; sessions: restored on the next launch)

    private func persistUsage() {
        guard !Self.isSmokeTest else { return }
        let defaults = UserDefaults.standard
        guard let value = store.usage else {
            defaults.removeObject(forKey: Self.usageDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.usageDefaultsKey) }
    }

    private static func loadPersistedUsage() -> UsageLimits? {
        guard !isSmokeTest, let data = UserDefaults.standard.data(forKey: usageDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(UsageLimits.self, from: data)
    }

    private var sessionsFilePath: String { paths.appSupport + "/" + Self.sessionsFileName }

    /// Visible sessions whose liveness can be re-checked after a restart (a PID, or a Desktop row that follows
    /// Claude Desktop). Written on quit (small file, mode 0600).
    private func persistSessions() {
        guard !Self.isSmokeTest else { return }
        let path = sessionsFilePath
        let keep = store.sessions.values.filter(Self.isRestorable).sorted { $0.id < $1.id }
        guard !keep.isEmpty else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let state = ClaudePersistedSessions(version: ClaudePersistedSessions.currentVersion, savedAt: Date(), sessions: keep)
        do {
            try FileManager.default.createDirectory(atPath: paths.appSupport, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: path), options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            Log.claude.error("could not save Claude sessions: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-inserts the sessions saved on the last quit (the file is consumed). No popups for them; the source's
    /// liveness check drops sessions whose process is gone (or whose PID was reused), `claude agents` refines.
    private func restorePersistedSessions() {
        guard !Self.isSmokeTest else { return }
        let path = sessionsFilePath
        guard let data = FileManager.default.contents(atPath: path) else { return }
        try? FileManager.default.removeItem(atPath: path)
        guard let state = try? JSONDecoder().decode(ClaudePersistedSessions.self, from: data),
            state.version == ClaudePersistedSessions.currentVersion,
            Date().timeIntervalSince(state.savedAt) < Self.sessionsMaxAge
        else { return }
        let restored = state.sessions.filter(Self.isRestorable)
        guard !restored.isEmpty else { return }
        _ = store.restoreSessions(restored, now: Date())
        Log.claude.info("restored \(restored.count, privacy: .public) Claude session(s)")
        publish()
        syncSourceAndWatches()
    }

    private static func isRestorable(_ session: Session) -> Bool {
        session.isVisible && (session.pid != nil || session.host.kind == .claudeDesktop)
    }

    /// Pruned copy, nil when no window is left.
    private static func pruned(_ usage: UsageLimits, now: Date) -> UsageLimits? {
        let value = usage.pruned(now: now)
        return value.isEmpty ? nil : value
    }

    /// One timer at the next reset time (no polling).
    private func scheduleUsageExpiry() {
        usageExpiryTask?.cancel()
        usageExpiryTask = nil
        guard let usage else { return }
        let now = Date()
        let resets = [usage.fiveHour?.resetsAt, usage.sevenDay?.resetsAt].compactMap { $0 }.filter { $0 > now }
        guard let next = resets.min() else { return }
        let delay = next.timeIntervalSince(now) + 1
        usageExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.apply(.tick)
            self.publish()
            self.persistUsage()
            self.scheduleUsageExpiry()
        }
    }

    // MARK: - Settings

    private func settingsChanged(old: AppSettings, new: AppSettings) {
        guard isStarted else { return }
        if old.claudeEnabled != new.claudeEnabled {
            if new.claudeEnabled { startSource() } else { stopSource() }
        }
        if old.claudeConfigDirOverride != new.claudeConfigDirOverride {
            let resolved = Self.resolveConfigDirectory(new, homeDirectory: paths.homeDirectory)
            if resolved != configDirectory {
                configDirectory = resolved
                source?.setConfigDirectory(resolved)
                detectedConfigDirectories.removeAll { Self.samePath($0, resolved) }
                refreshSetup(syncBinary: false, allowRepair: false)
            }
        }
        if old.wrapStatusLine != new.wrapStatusLine {
            // Apply the bridge change right away when our hooks are installed.
            if hookStatus.hasOurEntries { installHooks() } else { refreshSetup(syncBinary: false, allowRepair: false) }
        }
        if old.generateTitlesWithHaiku && !new.generateTitlesWithHaiku {
            titleGenerator.cancelAll()
        }
    }

    private static func resolveConfigDirectory(_ settings: AppSettings, homeDirectory: String) -> String {
        ClaudePaths.resolve(
            environment: ProcessInfo.processInfo.environment, homeDirectory: homeDirectory,
            override: settings.claudeConfigDirOverride
        ).configDirectory
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        (lhs as NSString).standardizingPath == (rhs as NSString).standardizingPath
    }

    /// A hook reported a CLAUDE_CONFIG_DIR we do not manage: offer to install there too (SPEC §D.6).
    private func noteConfigDirectory(_ reported: String?) {
        guard let reported, !reported.isEmpty else { return }
        let directory = ClaudePaths.resolve(environment: [:], homeDirectory: paths.homeDirectory, override: reported)
            .configDirectory
        guard !Self.samePath(directory, configDirectory),
            !detectedConfigDirectories.contains(where: { Self.samePath($0, directory) }),
            !installedExtraDirectories.contains(where: { Self.samePath($0, directory) })
        else { return }
        Log.claude.info("hook reports a different Claude config folder")
        detectedConfigDirectories.append(directory)
    }

    // MARK: - Hook installation (SPEC §D.6)

    /// Installs or repairs the hooks in the primary config folder (backup, atomic write, manifest).
    func installHooks() {
        let target = installer.primaryTarget(configDirectory: configDirectory)
        runHookOperation(target: target, install: true)
    }

    /// Removes our entries from the primary and every extra config folder; restores the user's statusLine.
    func uninstallHooks() {
        guard !isHookOperationRunning, !Self.isSmokeTest else { return }
        let installer = self.installer
        let primary = installer.primaryTarget(configDirectory: configDirectory)
        let extras = installedExtraDirectories.map { installer.secondaryTarget(configDirectory: $0) }
        isHookOperationRunning = true
        hookMessage = nil
        Task { [weak self] in
            let outcome = await ClaudeBackground.run {
                ClaudeHookOperations.uninstall(installer: installer, primary: primary, extras: extras)
            }
            guard let self else { return }
            self.isHookOperationRunning = false
            self.hookMessage = outcome.message
            if let backup = outcome.backupPath { self.lastBackupPath = backup }
            if outcome.succeeded { self.installedExtraDirectories = [] }
            self.refreshSetup(syncBinary: false, allowRepair: false)
        }
    }

    /// Installs hooks (no statusLine bridge) into another config folder reported by a session.
    func installHooks(inConfigDirectory directory: String) {
        let target = installer.secondaryTarget(configDirectory: directory)
        runHookOperation(target: target, install: true)
    }

    /// Re-reads settings.json and re-checks the helper (no changes are made).
    func refreshHookStatus() {
        ClaudeCLIEnvironment.shared.invalidate()
        refreshSetup(syncBinary: false, allowRepair: false)
    }

    /// Looks for other Claude config folders (launchd / login shell CLAUDE_CONFIG_DIR, settings.json `env`,
    /// `~/.claude*`). Called when Settings or onboarding appear; results land in `detectedConfigDirectories`.
    func discoverConfigDirectories() {
        guard !discoveryRunning, !Self.isSmokeTest else { return }
        discoveryRunning = true
        let home = paths.homeDirectory
        let managed = [configDirectory] + installedExtraDirectories
        Task { [weak self] in
            let found = await ClaudeBackground.run {
                ClaudeConfigDiscovery.candidates(homeDirectory: home, managed: managed)
            }
            guard let self else { return }
            self.discoveryRunning = false
            for directory in found { self.noteConfigDirectory(directory) }
        }
    }

    private func runHookOperation(target: ClaudeHookInstallTarget, install: Bool) {
        guard !isHookOperationRunning, !Self.isSmokeTest else { return }
        isHookOperationRunning = true
        hookMessage = nil
        let installer = self.installer
        let wrap = settings.settings.wrapStatusLine
        let cli = cliLookup
        let sources = Self.hookSourceCandidates()
        Task { [weak self] in
            let outcome = await ClaudeBackground.run {
                ClaudeHookOperations.install(
                    installer: installer, target: target, wrapStatusLine: wrap, cli: cli, hookSources: sources)
            }
            guard let self else { return }
            self.isHookOperationRunning = false
            self.hookMessage = outcome.message
            if let backup = outcome.backupPath { self.lastBackupPath = backup }
            if outcome.succeeded, !target.isPrimary {
                if !self.installedExtraDirectories.contains(target.configDirectory) {
                    self.installedExtraDirectories.append(target.configDirectory)
                }
                self.detectedConfigDirectories.removeAll { Self.samePath($0, target.configDirectory) }
            }
            self.refreshSetup(syncBinary: false, allowRepair: false)
        }
    }

    /// Syncs the helper binary (launch only), reads `claude --version`, computes the hook status and
    /// auto-repairs an earlier install whose entries went stale.
    private func refreshSetup(syncBinary: Bool, allowRepair: Bool) {
        setupGeneration += 1
        let generation = setupGeneration
        let installer = self.installer
        let primary = installer.primaryTarget(configDirectory: configDirectory)
        // Smoke test (SPEC §D.10): no `claude` spawns, no files outside the temp config folder.
        let extras =
            Self.isSmokeTest ? [] : installedExtraDirectories.map { installer.secondaryTarget(configDirectory: $0) }
        let wrap = settings.settings.wrapStatusLine
        let cli = cliLookup
        let sources = syncBinary ? Self.hookSourceCandidates() : []
        let resolveCLI = !Self.isSmokeTest
        Task { [weak self] in
            let result = await ClaudeBackground.run {
                ClaudeHookOperations.setup(
                    installer: installer, primary: primary, extras: extras, wrapStatusLine: wrap, cli: cli,
                    hookSources: sources, allowRepair: allowRepair, resolveCLI: resolveCLI)
            }
            guard let self, generation == self.setupGeneration else { return }
            self.hookStatus = result.status
            self.extraConfigStatuses = result.extraStatuses
            self.hookPreview = result.preview
            self.claudeVersionText = result.version
            self.isClaudeCLIFound = result.executablePath != nil || Self.isSmokeTest
            if let message = result.message { self.hookMessage = message }
        }
    }

    /// What the background lookup of the `claude` CLI starts from.
    private var cliLookup: ClaudeCLILookup {
        ClaudeCLILookup(
            homeDirectory: paths.homeDirectory, invocation: latestInvocation,
            executableHint: store.sessions.values.lazy.compactMap(\.claudeExecutablePath)
                .first(where: ClaudeCLIEnvironment.isUsableHint))
    }

    private var installedExtraDirectories: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.extraConfigDirectoriesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.extraConfigDirectoriesKey) }
    }

    // MARK: - Environment

    private static var isSmokeTest: Bool {
        ProcessInfo.processInfo.environment[smokeTestEnvironmentKey] == "1"
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Where the bundled hook helper lives: `SuperNotch.app/Contents/Helpers/supernotch-hook`, or next to
    /// the executable for unbundled development builds (`swift build` puts both products side by side).
    private static func hookSourceCandidates() -> [String] {
        var candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + SuperNotchPaths.hookBinaryName).path
        ]
        if let executable = Bundle.main.executableURL {
            candidates.append(
                executable.deletingLastPathComponent().appendingPathComponent(SuperNotchPaths.hookBinaryName).path)
        }
        return candidates
    }
}

/// Sessions saved on quit (`claude-sessions.json` in Application Support).
nonisolated struct ClaudePersistedSessions: Codable, Sendable {
    static let currentVersion = 1
    var version: Int
    var savedAt: Date
    var sessions: [Session]
}

/// Inputs for finding the `claude` CLI off the main thread.
nonisolated struct ClaudeCLILookup: Sendable {
    var homeDirectory: String
    /// Latest `HookContext.claudeInvocation`.
    var invocation: [String]?
    /// A session's executable path that is the real binary (not `node`).
    var executableHint: String?
}

// MARK: - Background hook operations

nonisolated struct ClaudeHookOperationOutcome: Sendable {
    var succeeded: Bool
    var message: String
    var backupPath: String?
}

nonisolated struct ClaudeSetupResult: Sendable {
    var status: ClaudeHookStatus
    var extraStatuses: [String: ClaudeHookStatus]
    var preview: String
    var version: String?
    var executablePath: String?
    var message: String?
}

/// Blocking installer work, run from detached tasks.
nonisolated enum ClaudeHookOperations {
    static func install(
        installer: ClaudeHookInstaller, target: ClaudeHookInstallTarget, wrapStatusLine: Bool, cli: ClaudeCLILookup,
        hookSources: [String]
    ) -> ClaudeHookOperationOutcome {
        if !hookSources.isEmpty {
            switch installer.syncHookBinary(sourceCandidates: hookSources) {
            case .failed(let reason):
                return ClaudeHookOperationOutcome(succeeded: false, message: "Could not copy the hook helper: \(reason)")
            case .upToDate, .updated, .missingSource:
                break
            }
        }
        let version = claudeVersion(cli).version
        let spec = installer.spec(for: target, claudeVersion: version, wrapStatusLine: wrapStatusLine)
        do {
            let outcome = try installer.install(into: target, spec: spec)
            return ClaudeHookOperationOutcome(succeeded: true, message: outcome.message, backupPath: outcome.backupPath)
        } catch {
            return ClaudeHookOperationOutcome(succeeded: false, message: "\(error)")
        }
    }

    static func uninstall(
        installer: ClaudeHookInstaller, primary: ClaudeHookInstallTarget, extras: [ClaudeHookInstallTarget]
    ) -> ClaudeHookOperationOutcome {
        var messages: [String] = []
        var backup: String?
        var succeeded = true
        for target in [primary] + extras {
            do {
                let outcome = try installer.uninstall(from: target)
                if target.isPrimary { messages.insert(outcome.message, at: 0) }
                backup = backup ?? outcome.backupPath
            } catch {
                succeeded = false
                messages.append("\(target.settingsFile): \(error)")
            }
        }
        return ClaudeHookOperationOutcome(
            succeeded: succeeded, message: messages.joined(separator: " "), backupPath: backup)
    }

    static func setup(
        installer: ClaudeHookInstaller, primary: ClaudeHookInstallTarget, extras: [ClaudeHookInstallTarget],
        wrapStatusLine: Bool, cli: ClaudeCLILookup, hookSources: [String], allowRepair: Bool, resolveCLI: Bool
    ) -> ClaudeSetupResult {
        var message: String?
        if !hookSources.isEmpty {
            switch installer.syncHookBinary(sourceCandidates: hookSources) {
            case .updated:
                Log.claude.info("hook helper updated")
            case .failed(let reason):
                Log.claude.error("hook helper copy failed: \(reason, privacy: .public)")
            case .missingSource:
                Log.claude.info("no bundled hook helper found (development build?)")
            case .upToDate:
                break
            }
        }
        let found = resolveCLI ? claudeVersion(cli) : (executable: nil, version: nil)
        let spec = installer.spec(for: primary, claudeVersion: found.version, wrapStatusLine: wrapStatusLine)
        var status = installer.status(of: primary, spec: spec)
        if allowRepair, case .needsRepair = status, installer.hasManifest(for: primary) {
            do {
                status = try installer.install(into: primary, spec: spec).status
                message = "Hooks were repaired automatically."
                Log.claude.info("hooks repaired automatically")
            } catch {
                Log.claude.error("automatic hook repair failed")
            }
        }
        var extraStatuses: [String: ClaudeHookStatus] = [:]
        for extra in extras {
            let extraSpec = installer.spec(for: extra, claudeVersion: found.version, wrapStatusLine: false)
            var extraStatus = installer.status(of: extra, spec: extraSpec)
            if allowRepair, case .needsRepair = extraStatus, installer.hasManifest(for: extra),
                let outcome = try? installer.install(into: extra, spec: extraSpec)
            {
                extraStatus = outcome.status
            }
            extraStatuses[extra.configDirectory] = extraStatus
        }
        return ClaudeSetupResult(
            status: status, extraStatuses: extraStatuses, preview: installer.preview(for: primary, spec: spec),
            version: found.version?.description, executablePath: found.executable, message: message)
    }

    private static func claudeVersion(_ cli: ClaudeCLILookup) -> (executable: String?, version: ClaudeVersion?) {
        let environment = ClaudeCLIEnvironment.shared
        guard
            let invocation = environment.claudeInvocation(
                homeDirectory: cli.homeDirectory, reported: cli.invocation, hint: cli.executableHint)
        else { return (nil, nil) }
        return (
            invocation.last, environment.claudeVersion(invocation: invocation, homeDirectory: cli.homeDirectory)
        )
    }
}
