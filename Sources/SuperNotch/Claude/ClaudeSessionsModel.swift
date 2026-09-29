// Owner: claude-app. The app-side Claude model (SPEC §D.4, frozen API) and the glue around Core's pure
// `SessionStore` reducer:
//
//   ClaudeLocalSessionSource (socket, liveness, agents, tick) ─┐
//   transcript reads, Haiku titles, the user's answers ────────┼─► SessionStore.apply ─► effects ─► popups,
//                                                              ┘                                  replies,
//                                                                                                 titles…
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

    /// "Answer in the chat instead": releases the held hook (Claude Code shows its own prompt) and jumps
    /// to the session. Also the only action for question-type requests.
    func answerInChat(requestID: String) {
        guard let request = store.permissions[requestID] else { return }
        source?.reply(requestID: requestID, decision: nil)
        apply(.permissionConnectionClosed(requestID: requestID))
        focus(sessionID: request.sessionID)
    }

    /// Jump to chat (SPEC §D.8): Claude Desktop deep link or the hosting terminal, best effort.
    func focus(sessionID: String) {
        guard let session = store.sessions[sessionID] else { return }
        notch.withdraw(popupID: PopupRequest.claudeSessionID(sessionID))
        focuser.focus(session)
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
    private let paths: SuperNotchPaths
    private let installer: ClaudeHookInstaller
    private let titleGenerator: ClaudeTitleGenerator
    private let focuser: ClaudeSessionFocuser
    private let transcriptWatcher = ClaudeTranscriptWatcher()

    @ObservationIgnored private var store = SessionStore()
    @ObservationIgnored private var source: ClaudeLocalSessionSource?
    @ObservationIgnored private var workspaceObserver: ClaudeWorkspaceObserver?
    @ObservationIgnored private var settingsToken: SettingsStore.ObserverToken?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var pendingEvents: [SessionEvent] = []
    @ObservationIgnored private var restoredUsage: UsageLimits?
    @ObservationIgnored private var usageExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var doneTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var titleTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var transcriptReadsInFlight: Set<String> = []
    @ObservationIgnored private var transcriptReadsDirty: Set<String> = []
    @ObservationIgnored private var lastTranscriptSignals: [String: TranscriptSignals] = [:]
    @ObservationIgnored private var watchedTranscripts: [String: String] = [:]
    @ObservationIgnored private var setupGeneration = 0
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var discoveryRunning = false

    static let usageDefaultsKey = "sn.claude.usage"
    static let extraConfigDirectoriesKey = "sn.claude-app.extraConfigDirectories"
    static let smokeTestEnvironmentKey = "SUPERNOTCH_SMOKE_TEST"
    /// Wait for Claude Code's own ai-title before spending a Haiku call.
    static let titleGrace: TimeInterval = 20

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
        let persisted = Self.loadPersistedUsage()
        restoredUsage = persisted
        usage = persisted.flatMap { Self.pruned($0, now: Date()) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        titleGenerator.onTitle = { [weak self] sessionID, title in
            self?.apply(.titleGenerated(sessionID: sessionID, title: title))
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
        if settings.settings.claudeEnabled { startSource() }
        refreshSetup(syncBinary: !Self.isSmokeTest, allowRepair: !Self.isSmokeTest)
        scheduleUsageExpiry()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        settingsToken?.cancel()
        settingsToken = nil
        workspaceObserver?.invalidate()
        workspaceObserver = nil
        stopSource()
        usageExpiryTask?.cancel()
        usageExpiryTask = nil
        titleGenerator.cancelAll()
        titleGenerator.onTitle = nil
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
        source.start { [weak self] event in
            self?.apply(event)
        }
        source.setPaused(isPaused)
        self.source = source
        socketError = source.serverError
    }

    /// Stops listening (held hooks fail open) and forgets every session.
    private func stopSource() {
        source?.stop()
        source = nil
        socketError = nil
        transcriptWatcher.stopAll()
        watchedTranscripts = [:]
        for task in doneTasks.values { task.cancel() }
        doneTasks = [:]
        for task in titleTasks.values { task.cancel() }
        titleTasks = [:]
        for request in store.permissions.values {
            notch.withdraw(popupID: PopupRequest.claudePermissionID(request.id))
        }
        for id in store.sessions.keys {
            notch.withdraw(popupID: PopupRequest.claudeSessionID(id))
        }
        if let current = store.usage { restoredUsage = current }
        store = SessionStore()
        lastTranscriptSignals = [:]
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
        }
        let now = Date()
        let effects = store.apply(event, now: now)
        publish()
        perform(effects, now: now)
        source?.update(sessions: Array(store.sessions.values))
        updateTranscriptWatches()
    }

    /// Copies the store's derived state into observable properties (only when changed).
    private func publish() {
        let visible = store.visibleSessions
        if visible != sessions { sessions = visible }
        // Questions (AskUserQuestion) are never Allow/Deny cards: they are answered in the chat.
        let pending = store.pendingPermissions.filter { !Self.isQuestionTool($0.toolName) }
        if pending != permissions { permissions = pending }
        let light = store.aggregateLight
        if light != aggregateLight { aggregateLight = light }
        if store.usage != nil { restoredUsage = nil }
        let current = (store.usage ?? restoredUsage).flatMap { Self.pruned($0, now: Date()) }
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
        doneTasks.removeValue(forKey: sessionID)?.cancel()
        titleTasks.removeValue(forKey: sessionID)?.cancel()
        titleGenerator.cancel(sessionID: sessionID)
        lastTranscriptSignals[sessionID] = nil
        notch.withdraw(popupID: PopupRequest.claudeSessionID(sessionID))
    }

    private func phaseChanged(_ sessionID: String, from: SessionPhase, to: SessionPhase, now: Date) {
        let popupID = PopupRequest.claudeSessionID(sessionID)
        switch to {
        case .done:
            if from.isNeedsInput { notch.withdraw(popupID: popupID) }
            // 🟢 only for a turn that actually ran (not idle → done on an idle_prompt of a resumed session).
            guard from == .working || from.isNeedsInput else { return }
            scheduleDonePopup(sessionID)
        case .working, .idle:
            doneTasks.removeValue(forKey: sessionID)?.cancel()
            notch.withdraw(popupID: popupID)
        case .needsInput(let kind):
            doneTasks.removeValue(forKey: sessionID)?.cancel()
            guard let session = store.sessions[sessionID] else { return }
            if kind == .permission, hasCard(for: session) {
                notch.withdraw(popupID: popupID)  // The permission card covers it.
            } else if kind == .permission, !session.pendingPermissionIDs.isEmpty {
                return  // Question-type request: `presentPermission` already popped the question peek.
            } else {
                presentNeedsInput(session, now: now)
            }
        }
    }

    /// 🟢 after the debounce (a 🟢 that turns 🟡 again within 0.8 s never pops up).
    private func scheduleDonePopup(_ sessionID: String) {
        doneTasks[sessionID]?.cancel()
        doneTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NotchMetrics.popupDebounce))
            guard !Task.isCancelled, let self else { return }
            self.doneTasks[sessionID] = nil
            let current = self.settings.settings
            guard current.claudeEnabled, current.popupOnDone, let session = self.store.sessions[sessionID],
                session.isVisible, session.phase == .done
            else { return }
            self.notch.present(
                .claudeDone(
                    sessionID: sessionID, hostAppBundleID: ClaudeHostApps.bundleID(for: session.host),
                    autoDismissAfter: current.doneAutoCollapse, now: Date()))
        }
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
        if Self.isQuestionTool(request.toolName) {
            // A question arrives as a PermissionRequest: Allow/Deny cannot answer it. Let Claude Code show
            // its own question UI right away and pop the red "question" peek instead (click → chat).
            source?.reply(requestID: requestID, decision: nil)
            if let session { presentNeedsInput(session, now: now) }
            return
        }
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

    /// The session has a pending Allow/Deny card (not a question).
    private func hasCard(for session: Session) -> Bool {
        session.pendingPermissionIDs.contains { id in
            store.permissions[id].map { !Self.isQuestionTool($0.toolName) } ?? false
        }
    }

    /// Tools whose "permission" prompt is really a question to the user.
    static func isQuestionTool(_ toolName: String) -> Bool {
        toolName == "AskUserQuestion"
    }

    // MARK: - Transcripts

    private func refreshTranscript(_ sessionID: String) {
        guard let path = store.sessions[sessionID]?.transcriptPath, !path.isEmpty else { return }
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
        guard let path = store.sessions[sessionID]?.transcriptPath, !path.isEmpty,
            !transcriptReadsInFlight.contains(sessionID)
        else { return }
        transcriptReadsInFlight.insert(sessionID)
        let signals = await Task.detached(priority: .utility) {
            ClaudeTranscriptReader.readSignals(path: path)
        }.value
        transcriptReadsInFlight.remove(sessionID)
        if let signals, store.sessions[sessionID] != nil, lastTranscriptSignals[sessionID] != signals {
            lastTranscriptSignals[sessionID] = signals
            apply(.transcript(sessionID: sessionID, signals))
        }
        if transcriptReadsDirty.remove(sessionID) != nil { refreshTranscript(sessionID) }
    }

    /// Transcripts are watched only while their session works (interrupt marker, fresh ai-title).
    private func updateTranscriptWatches() {
        var targets: [String: String] = [:]
        for session in store.sessions.values where session.isVisible && session.phase == .working {
            if let path = session.transcriptPath, !path.isEmpty { targets[session.id] = path }
        }
        guard targets != watchedTranscripts else { return }
        watchedTranscripts = targets
        transcriptWatcher.update(targets: targets)
    }

    // MARK: - Titles (SPEC §E.4)

    private func scheduleTitleGeneration(_ sessionID: String) {
        if let cached = titleGenerator.cachedTitle(for: sessionID) {
            apply(.titleGenerated(sessionID: sessionID, title: cached))
            return
        }
        guard settings.settings.generateTitlesWithHaiku, titleTasks[sessionID] == nil,
            let startedAt = store.sessions[sessionID]?.startedAt
        else { return }
        // Claude Code writes its own ai-title after the first response: give it time (SPEC §E.4).
        let delay = max(3, Self.titleGrace - Date().timeIntervalSince(startedAt))
        titleTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.loadTranscript(sessionID)
            self.titleTasks[sessionID] = nil
            guard self.settings.settings.generateTitlesWithHaiku, let session = self.store.sessions[sessionID],
                session.isVisible,
                TitleResolver.needsGeneration(session.titleCandidates, firstPrompt: session.firstPrompt),
                let text = TitleResolver.generationSource(session.titleCandidates, firstPrompt: session.firstPrompt)
            else { return }
            self.titleGenerator.enqueue(
                ClaudeTitleGenerator.Request(
                    sessionID: sessionID, sourceText: text, executableHint: session.claudeExecutablePath,
                    configDirectory: self.configDirectory))
        }
    }

    // MARK: - Usage (SPEC §D.9)

    private func persistUsage() {
        let defaults = UserDefaults.standard
        guard let value = store.usage else {
            defaults.removeObject(forKey: Self.usageDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.usageDefaultsKey) }
    }

    private static func loadPersistedUsage() -> UsageLimits? {
        guard let data = UserDefaults.standard.data(forKey: usageDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(UsageLimits.self, from: data)
    }

    /// Pruned copy, nil when no window is left.
    private static func pruned(_ usage: UsageLimits, now: Date) -> UsageLimits? {
        let value = usage.pruned(now: now)
        return value.fiveHour == nil && value.sevenDay == nil ? nil : value
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
            for task in titleTasks.values { task.cancel() }
            titleTasks = [:]
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
        let primary = installer.primaryTarget(configDirectory: configDirectory)
        let extras = installedExtraDirectories.map { installer.secondaryTarget(configDirectory: $0) }
        guard !isHookOperationRunning else { return }
        isHookOperationRunning = true
        hookMessage = nil
        let installer = installer
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                ClaudeHookOperations.uninstall(installer: installer, primary: primary, extras: extras)
            }.value
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
            let found = await Task.detached(priority: .utility) {
                ClaudeConfigDiscovery.candidates(homeDirectory: home, managed: managed)
            }.value
            guard let self else { return }
            self.discoveryRunning = false
            for directory in found { self.noteConfigDirectory(directory) }
        }
    }

    private func runHookOperation(target: ClaudeHookInstallTarget, install: Bool) {
        guard !isHookOperationRunning else { return }
        isHookOperationRunning = true
        hookMessage = nil
        let installer = installer
        let wrap = settings.settings.wrapStatusLine
        let hint = executableHint
        let home = paths.homeDirectory
        let sources = Self.isSmokeTest ? [] : Self.hookSourceCandidates()
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                ClaudeHookOperations.install(
                    installer: installer, target: target, wrapStatusLine: wrap, executableHint: hint,
                    homeDirectory: home, hookSources: sources)
            }.value
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
        let installer = installer
        let primary = installer.primaryTarget(configDirectory: configDirectory)
        let extras = installedExtraDirectories.map { installer.secondaryTarget(configDirectory: $0) }
        let wrap = settings.settings.wrapStatusLine
        let hint = executableHint
        let home = paths.homeDirectory
        let sources = syncBinary ? Self.hookSourceCandidates() : []
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                ClaudeHookOperations.setup(
                    installer: installer, primary: primary, extras: extras, wrapStatusLine: wrap,
                    executableHint: hint, homeDirectory: home, hookSources: sources, allowRepair: allowRepair)
            }.value
            guard let self, generation == self.setupGeneration else { return }
            self.hookStatus = result.status
            self.extraConfigStatuses = result.extraStatuses
            self.hookPreview = result.preview
            self.claudeVersionText = result.version
            self.isClaudeCLIFound = result.executablePath != nil
            if let message = result.message { self.hookMessage = message }
        }
    }

    private var executableHint: String? {
        store.sessions.values.lazy.compactMap(\.claudeExecutablePath).first { !$0.hasSuffix(".js") }
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
        installer: ClaudeHookInstaller, target: ClaudeHookInstallTarget, wrapStatusLine: Bool,
        executableHint: String?, homeDirectory: String, hookSources: [String]
    ) -> ClaudeHookOperationOutcome {
        if !hookSources.isEmpty {
            switch installer.syncHookBinary(sourceCandidates: hookSources) {
            case .failed(let reason):
                return ClaudeHookOperationOutcome(succeeded: false, message: "Could not copy the hook helper: \(reason)")
            case .upToDate, .updated, .missingSource:
                break
            }
        }
        let version = claudeVersion(executableHint: executableHint, homeDirectory: homeDirectory).version
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
        wrapStatusLine: Bool, executableHint: String?, homeDirectory: String, hookSources: [String],
        allowRepair: Bool
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
        let cli = claudeVersion(executableHint: executableHint, homeDirectory: homeDirectory)
        let spec = installer.spec(for: primary, claudeVersion: cli.version, wrapStatusLine: wrapStatusLine)
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
            let extraSpec = installer.spec(for: extra, claudeVersion: cli.version, wrapStatusLine: false)
            var extraStatus = installer.status(of: extra, spec: extraSpec)
            if allowRepair, case .needsRepair = extraStatus, installer.hasManifest(for: extra),
                let outcome = try? installer.install(into: extra, spec: extraSpec)
            {
                extraStatus = outcome.status
            }
            extraStatuses[extra.configDirectory] = extraStatus
        }
        return ClaudeSetupResult(
            status: status, extraStatuses: extraStatuses, preview: installer.preview(spec: spec),
            version: cli.version?.description, executablePath: cli.executable, message: message)
    }

    private static func claudeVersion(executableHint: String?, homeDirectory: String)
        -> (executable: String?, version: ClaudeVersion?)
    {
        let environment = ClaudeCLIEnvironment.shared
        guard let executable = environment.claudeExecutable(homeDirectory: homeDirectory, hint: executableHint) else {
            return (nil, nil)
        }
        return (executable, environment.claudeVersion(executable: executable, homeDirectory: homeDirectory))
    }
}
