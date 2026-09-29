// Owner: media stream. Observable Spotify state for the views (SPEC §D.4 `MediaModel`, FROZEN API).
//
// Data flow (SPEC §A.5, §F.1):
//   Spotify notification ──► instant snapshot from userInfo ──┐
//                                                             ├──► `snapshot` (position is EXTRAPOLATED by the
//   one batched AppleScript (background queue) ───────────────┘     views from `positionSeconds/Timestamp`)
//
// The AppleScript only runs (a) after a notification, (b) when the Home tab opens, (c) every few seconds while the
// Home tab is visible AND Spotify is playing, (d) shortly after a track should have ended (a dormant one-shot while
// playing, at most twice per track, normally cancelled by the track-change notification). Nothing polls while
// paused, while the notch is closed, or while Spotify is not running; the island only needs the cover and the
// playing flag, which the notifications deliver.
//
// Automation permission (SPEC §A.5, §A.11) is a small state machine in Core (`MediaPermissionFlow`):
//   "Allow Access" ──► wait for Spotify (launch it if needed; ready = first notification or 4 s after launch)
//                  ──► ONE real Apple Event on the permission queue (the macOS dialog) ── 45 s timeout
//                  ──► granted / denied / "macOS didn't answer" (Try Again, Reset & Ask Again, System Settings)
// Silent checks never prompt, time out after 3 s, and never turn an observed denial back into "not asked".
import AppKit
import Foundation
import Observation
import SuperNotchCore
import os

@Observable
final class MediaModel {
    // MARK: Published state (frozen API + additive extras)

    private(set) var snapshot: PlaybackSnapshot?
    /// True only while the feature is enabled AND the Spotify desktop app is running.
    private(set) var isSpotifyRunning = false
    private(set) var artwork: NSImage?
    /// Automation (TCC) permission plus the request in progress. Mutated only via `updatePermission`.
    private(set) var permissionFlow = MediaPermissionFlow()
    /// Dominant saturated colour of the current cover, for subtle tints. nil for greyscale / missing covers.
    private(set) var accent: MediaAccentColor?

    /// Settings › Music › "Enable Spotify".
    var isEnabled: Bool { settingsStore.settings.spotifyEnabled }
    var hasTrack: Bool { isSpotifyRunning && snapshot?.track != nil }
    var isPlaying: Bool { isSpotifyRunning && (snapshot?.isPlaying ?? false) }
    /// Spotify is running and macOS lets us send it commands.
    var canControl: Bool { isSpotifyRunning && automationPermission == .granted }
    /// Frozen API (SPEC §D.4).
    var automationPermission: MediaAutomationPermission { permissionFlow.permission }
    /// Waiting for Spotify, asking, resetting, or why the last request failed.
    var permissionRequest: MediaPermissionRequestState { permissionFlow.request }
    /// Status, sentences and buttons for the permission UI (onboarding, Settings, Home).
    var permissionPresentation: MediaPermissionPresentation {
        MediaPermissionPresentation(
            permission: permissionFlow.permission, request: permissionFlow.request,
            resetCommand: automationResetCommand)
    }
    /// The Terminal fallback of "Reset & Ask Again".
    var automationResetCommand: String { MediaPermissionReset.terminalCommand(bundleID: Self.ownBundleID) }

    // MARK: Dependencies

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let notch: NotchViewModel
    @ObservationIgnored private let controller = SpotifyController()
    @ObservationIgnored private let artworkLoader = MediaArtworkLoader()

    // MARK: Private state (never read by views)

    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var lastEnabled = true
    @ObservationIgnored private var lastHomeVisible = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var retryCount = 0
    /// Set when the user issued a command; status reads that started before it are stale.
    @ObservationIgnored private var lastCommandAt = Date.distantPast
    /// When we saw Spotify launch (nil when it quit or launched before we started) and whether it has posted a
    /// playback notification since: together they say whether its Apple Event interface is ready.
    @ObservationIgnored private var spotifyLaunchedAt: Date?
    @ObservationIgnored private var sawPlaybackSinceLaunch = false
    /// Track id of the last AppleScript-confirmed snapshot (gates the oEmbed cover fallback).
    @ObservationIgnored private var authoritativeTrackID: String?
    @ObservationIgnored private var currentArtworkKey: String?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollInterval: TimeInterval?
    @ObservationIgnored private var trackEndTask: Task<Void, Never>?
    /// Track-end refreshes already fired for `trackID`. Capped so a track whose real length exceeds the reported
    /// duration (podcasts with inserted ads, a stalled stream) cannot turn the one-shot into a 1.5 s poll.
    @ObservationIgnored private var trackEndRefreshes: (trackID: String, count: Int)?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// Sends the request once Spotify is ready.
    @ObservationIgnored private var askTask: Task<Void, Never>?
    /// Ends "Waiting for Spotify…" if Spotify never comes up.
    @ObservationIgnored private var launchWatchdogTask: Task<Void, Never>?
    /// A few silent checks after a request without an answer (the dialog may still be open).
    @ObservationIgnored private var followUpTask: Task<Void, Never>?

    /// Our own bundle id for `tccutil` (sanitised; falls back to the release id when unbundled).
    private static let ownBundleID = MediaPermissionReset.sanitizedBundleID(Bundle.main.bundleIdentifier)

    // MARK: Init / lifecycle

    init(settings: SettingsStore, notch: NotchViewModel) {
        self.settingsStore = settings
        self.notch = notch
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lastEnabled = isEnabled
        lastHomeVisible = isHomeTabVisible
        controller.onEvent = { [weak self] event in self?.handle(event) }
        controller.start()
        observeInputs()
        applyEnabledState()
    }

    func stop() {
        isStarted = false
        controller.onEvent = nil
        controller.stop()
        cancelTimers()
        launchTask?.cancel()
        launchTask = nil
        retryTask?.cancel()
        retryTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        cancelPermissionTasks()
    }

    // MARK: Commands (frozen API)

    func playPause() {
        guard prepareForCommand() else { return }
        let now = Date()
        lastCommandAt = now
        if let current = snapshot {
            snapshot = current.togglingPlayback(at: now)  // optimistic; the refresh below confirms
            updateTimers()
        }
        dispatch(.playPause, refreshAfter: 0.15)
    }

    func nextTrack() {
        guard prepareForCommand(), canSkipCurrentTrack else { return }
        lastCommandAt = Date()
        dispatch(.next, refreshAfter: 0.3)
    }

    func previousTrack() {
        guard prepareForCommand(), canSkipCurrentTrack else { return }
        lastCommandAt = Date()
        dispatch(.previous, refreshAfter: 0.3)
    }

    func seek(to seconds: Double) {
        guard prepareForCommand() else { return }
        let now = Date()
        lastCommandAt = now
        var target = seconds
        if let current = snapshot {
            let seeked = current.seeking(to: seconds, at: now)
            target = seeked.positionSeconds
            snapshot = seeked
            updateTimers()
        }
        dispatch(.seek(seconds: target), refreshAfter: 0.2)
    }

    /// Asks macOS for permission to control Spotify ("Allow Access", "Try Again"). The dialog only appears while
    /// Spotify runs, so this launches Spotify first when needed and asks once it is ready. Every step ends by
    /// itself (launch watchdog, request timeout), so the button can never stay dead.
    func requestAutomationPermission() {
        guard isEnabled else { return }
        syncRunningState()
        var began = false
        updatePermission { began = $0.beginWaitingForSpotify() }
        guard began else {
            Log.media.info(
                "Automation request ignored: \(String(describing: self.permissionRequest), privacy: .public)")
            return
        }
        followUpTask?.cancel()
        followUpTask = nil
        if isSpotifyRunning {
            askWhenSpotifyIsReady()
            return
        }
        Log.media.info("Automation request: launching Spotify first")
        guard controller.openSpotify() else {
            updatePermission { $0.cancelWaiting() }
            return
        }
        startLaunchWatchdog()
    }

    /// Silent re-check (no prompt), e.g. after the user came back from System Settings.
    func recheckAutomationPermission() {
        guard isStarted, isEnabled else { return }
        syncRunningState()
        guard isSpotifyRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            let permission = await self.runSilentCheck(reason: "recheck")
            if permission == .granted { self.requestRefresh() }
        }
    }

    /// "Reset & Ask Again": `tccutil reset AppleEvents <our bundle id>` (no admin rights needed), then a fresh
    /// request. If tccutil fails, the UI shows the command for Terminal.
    func resetAutomationPermissionAndAsk() {
        guard isEnabled else { return }
        var began = false
        updatePermission { began = $0.beginResetting() }
        guard began else { return }
        followUpTask?.cancel()
        followUpTask = nil
        let bundleID = Self.ownBundleID
        Task { [weak self] in
            guard let self else { return }
            let succeeded = await self.controller.resetPermission(bundleID: bundleID)
            self.updatePermission { $0.finishResetting(succeeded: succeeded) }
            if succeeded, self.isEnabled { self.requestAutomationPermission() }
        }
    }

    /// Puts `automationResetCommand` on the clipboard.
    func copyAutomationResetCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(automationResetCommand, forType: .string)
    }

    /// Runs a button of `permissionPresentation`.
    func perform(_ action: MediaPermissionAction) {
        Log.media.info("Automation action: \(action.rawValue, privacy: .public)")
        switch action {
        case .allow, .openSpotifyAndAllow, .tryAgain: requestAutomationPermission()
        case .openSystemSettings: openAutomationSettings()
        case .resetAndAskAgain: resetAutomationPermissionAndAsk()
        case .copyResetCommand: copyAutomationResetCommand()
        case .checkAgain: recheckAutomationPermission()
        }
    }

    /// Launches Spotify, or brings it to the front.
    func openSpotify() {
        controller.openSpotify()
    }

    /// System Settings › Privacy & Security › Automation.
    func openAutomationSettings() {
        controller.openAutomationSettings()
    }

    // MARK: Input observation (settings + notch visibility), event driven

    private var isHomeTabVisible: Bool {
        if case .expanded(.home) = notch.presentation { return true }
        return false
    }

    private func observeInputs() {
        guard isStarted else { return }
        withObservationTracking {
            _ = notch.presentation
            _ = settingsStore.settings.spotifyEnabled
        } onChange: { [weak self] in
            // `onChange` fires BEFORE the new value is stored; read it on the next MainActor turn.
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                self.inputsChanged()
                self.observeInputs()
            }
        }
    }

    private func inputsChanged() {
        let enabled = isEnabled
        if enabled != lastEnabled {
            lastEnabled = enabled
            applyEnabledState()
            return
        }
        guard enabled else { return }
        let homeVisible = isHomeTabVisible
        if homeVisible != lastHomeVisible {
            lastHomeVisible = homeVisible
            if homeVisible {
                syncRunningState()
                requestRefresh()  // resync position/state the moment somebody can see them
            }
            updateTimers()
        }
    }

    private func applyEnabledState() {
        guard isEnabled else {
            resetState()
            return
        }
        syncRunningState()
        if isSpotifyRunning { requestRefresh() }
    }

    // MARK: Events

    private func handle(_ event: SpotifyControllerEvent) {
        guard isStarted, isEnabled else { return }
        switch event {
        case .playbackChanged(let info):
            syncRunningState()
            guard isSpotifyRunning else { return }
            sawPlaybackSinceLaunch = true
            if permissionFlow.request == .waitingForSpotify {
                // Spotify talks: its Apple Event interface is up. Ask now instead of waiting out the settle delay.
                askTask?.cancel()
                askTask = nil
                askNow()
            }
            if let info, let merged = SpotifySnapshotMerger.merge(previous: snapshot, info: info, now: Date()) {
                if merged != snapshot { snapshot = merged }
                updateArtwork()
                updateTimers()
            }
            requestRefresh()  // the script is the source of truth (cover URL, exact position, flags)
        case .launched:
            spotifyLaunchedAt = Date()
            sawPlaybackSinceLaunch = false
            syncRunningState()
            if permissionFlow.request == .waitingForSpotify, isSpotifyRunning { askWhenSpotifyIsReady() }
            scheduleLaunchRefresh()
        case .terminated:
            spotifyLaunchedAt = nil
            sawPlaybackSinceLaunch = false
            syncRunningState()
        case .didWake:
            syncRunningState()
            if isSpotifyRunning { requestRefresh() }
        }
    }

    /// Spotify's Apple Event interface needs a moment after launch.
    private func scheduleLaunchRefresh() {
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.isStarted else { return }
            self.syncRunningState()
            guard self.isSpotifyRunning else { return }
            self.requestRefresh()
        }
    }

    // MARK: Automation permission flow

    /// Sends the request now, or once Spotify has settled after a launch.
    private func askWhenSpotifyIsReady() {
        launchWatchdogTask?.cancel()
        launchWatchdogTask = nil
        askTask?.cancel()
        askTask = nil
        let launchedAt = spotifyLaunchedAt ?? SpotifyApp.runningApplication?.launchDate
        let delay = SpotifyLaunchReadiness.delayBeforeAsking(
            launchedAt: launchedAt, sawPlaybackNotification: sawPlaybackSinceLaunch, now: Date())
        guard delay > 0 else {
            askNow()
            return
        }
        Log.media.info("Automation request: Spotify just launched, asking in \(delay, privacy: .public) s")
        askTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.askTask = nil
            self.askNow()
        }
    }

    private func askNow() {
        guard isEnabled, permissionFlow.request == .waitingForSpotify else { return }
        syncRunningState()
        guard isSpotifyRunning else {
            // Quit while we waited: keep waiting for the next launch, bounded by the watchdog.
            startLaunchWatchdog()
            return
        }
        var began = false
        updatePermission { began = $0.beginAsking() }
        guard began else { return }
        launchWatchdogTask?.cancel()
        launchWatchdogTask = nil
        Log.media.info("Automation request: sending the probe Apple Event to Spotify")
        let startedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            let result = await self.controller.askPermission(late: { status in
                Task { @MainActor [weak self] in self?.applyLateAnswer(status) }
            })
            self.finishAsking(result, startedAt: startedAt)
        }
    }

    private func finishAsking(_ result: MediaPermissionCallResult, startedAt: Date) {
        let seconds = Date().timeIntervalSince(startedAt)
        switch result {
        case .status(let status):
            Log.media.info(
                "Automation request answered: OSStatus \(status, privacy: .public) after \(seconds, privacy: .public) s"
            )
        case .timedOut:
            Log.media.error("Automation request: macOS did not answer within \(seconds, privacy: .public) s")
        }
        var outcome = MediaPermissionAskOutcome.granted
        updatePermission { outcome = $0.finishAsking(result) }
        switch outcome {
        case .granted:
            requestRefresh()
        case .denied:
            break
        case .notRunning:
            syncRunningState()
        case .problem:
            // The dialog may still be open, or the event reached Spotify but failed there: confirm silently.
            startFollowUpChecks()
        }
    }

    /// The user answered the dialog after we stopped waiting.
    private func applyLateAnswer(_ status: Int32) {
        Log.media.info("Automation request: late answer OSStatus \(status, privacy: .public)")
        guard isEnabled else { return }
        updatePermission { $0.applyLateAnswer(status) }
        if automationPermission == .granted { requestRefresh() }
    }

    /// A few silent checks while a failed request is shown, so a late "OK" shows up without another click.
    private func startFollowUpChecks() {
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            for attempt in 0..<MediaPermissionTimeouts.followUpChecks {
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(MediaPermissionTimeouts.followUpInterval))
                }
                guard let self, !Task.isCancelled else { return }
                guard case .failed = self.permissionRequest, self.isEnabled, self.isSpotifyRunning else { return }
                let permission = await self.runSilentCheck(reason: "follow-up \(attempt + 1)")
                if permission == .granted {
                    self.requestRefresh()
                    return
                }
            }
        }
    }

    /// Ends "Waiting for Spotify…" when Spotify does not come up within a minute.
    private func startLaunchWatchdog() {
        launchWatchdogTask?.cancel()
        launchWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MediaPermissionTimeouts.spotifyLaunch))
            guard let self, !Task.isCancelled else { return }
            self.launchWatchdogTask = nil
            guard self.permissionFlow.request == .waitingForSpotify else { return }
            self.syncRunningState()
            if self.isSpotifyRunning {
                self.askWhenSpotifyIsReady()  // the launch notification got lost
            } else {
                Log.media.error("Automation request: Spotify did not launch; giving up")
                self.updatePermission { $0.cancelWaiting() }
            }
        }
    }

    /// Silent check (never prompts, 3 s timeout) merged into the flow. Returns the permission afterwards.
    @discardableResult
    private func runSilentCheck(reason: String) async -> MediaAutomationPermission {
        let result = await controller.checkPermission()
        switch result {
        case .status(let status):
            Log.media.debug(
                "Automation silent check (\(reason, privacy: .public)): OSStatus \(status, privacy: .public)")
        case .timedOut:
            Log.media.error("Automation silent check (\(reason, privacy: .public)) timed out")
        }
        guard isEnabled else { return automationPermission }
        updatePermission { $0.applyObserved(result) }
        if automationPermission == .notRunning { syncRunningState() }
        return automationPermission
    }

    private func cancelPermissionTasks() {
        askTask?.cancel()
        askTask = nil
        launchWatchdogTask?.cancel()
        launchWatchdogTask = nil
        followUpTask?.cancel()
        followUpTask = nil
    }

    // MARK: Refresh

    private func requestRefresh() {
        guard isStarted, isEnabled, isSpotifyRunning else { return }
        if isRefreshing {
            refreshQueued = true
            return
        }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
            self.isRefreshing = false
            if self.refreshQueued {
                self.refreshQueued = false
                self.requestRefresh()
            }
        }
    }

    private func performRefresh() async {
        // Never send an Apple Event before we know it is allowed: the first one would raise the system prompt
        // at a random moment. The silent check does not prompt.
        if automationPermission != .granted {
            let permission = await runSilentCheck(reason: "refresh")
            guard permission == .granted else { return }
        }

        let requestedAt = Date()
        let result = await controller.fetchStatus()
        guard isStarted, isEnabled else { return }
        if requestedAt < lastCommandAt {
            // The user acted while this read was in flight: it may predate the command. Read again.
            refreshQueued = true
            return
        }

        switch result {
        case .snapshot(let incoming):
            retryCount = 0
            updatePermission { $0.applyObserved(.status(MediaAppleEventStatus.noErr)) }
            if !isSpotifyRunning { syncRunningState() }
            let reconciled = PlaybackReconciler.reconcile(previous: snapshot, incoming: incoming)
            if reconciled != snapshot { snapshot = reconciled }
            authoritativeTrackID = incoming.track?.id
            updateArtwork()
            updateTimers()
        case .notRunning:
            syncRunningState()
        case .failure(let failure):
            handleFailure(failure)
        }
    }

    private func handleFailure(_ failure: SpotifyScriptFailure) {
        switch failure {
        case .permissionDenied:
            updatePermission { $0.applyObserved(.status(MediaAppleEventStatus.notPermitted)) }
        case .consentRequired:
            // Never downgrades an observed denial (see `MediaAutomationPermission.merging(silent:into:)`).
            updatePermission { $0.applyObserved(.status(MediaAppleEventStatus.wouldRequireConsent)) }
        case .notRunning:
            syncRunningState()
        case .timedOut, .other:
            scheduleRetry()
        }
    }

    /// Spotify sometimes answers late right after launch or wake: try again a couple of times, then wait for
    /// the next notification.
    private func scheduleRetry() {
        guard retryCount < 3 else { return }
        retryCount += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.requestRefresh()
        }
    }

    // MARK: Commands plumbing

    /// Whether the user is allowed to command Spotify right now. Otherwise starts the matching recovery flow
    /// (permission prompt or System Settings) instead of failing silently.
    private func prepareForCommand() -> Bool {
        guard isStarted, isEnabled else { return false }
        syncRunningState()
        guard isSpotifyRunning else { return false }
        switch automationPermission {
        case .granted: return true
        case .denied: openAutomationSettings()
        case .unknown, .notRunning: requestAutomationPermission()
        }
        return false
    }

    private var canSkipCurrentTrack: Bool {
        guard let track = snapshot?.track else { return true }
        return MediaDisplay.canSkip(track)
    }

    private func dispatch(_ command: SpotifyCommand, refreshAfter delay: TimeInterval) {
        Task { [weak self] in
            guard let self else { return }
            if let failure = await self.controller.perform(command) { self.handleFailure(failure) }
            // Spotify applies the command asynchronously; give it a moment, then confirm.
            try? await Task.sleep(for: .seconds(delay))
            self.requestRefresh()
        }
    }

    // MARK: State helpers

    /// The only way `permissionFlow` changes: assigns (and logs) only real changes, so views are not invalidated
    /// by no-op transitions.
    private func updatePermission(_ change: (inout MediaPermissionFlow) -> Void) {
        var flow = permissionFlow
        change(&flow)
        guard flow != permissionFlow else { return }
        let old = permissionFlow
        permissionFlow = flow
        if old.permission != flow.permission {
            let from = old.permission.rawValue
            let to = flow.permission.rawValue
            Log.media.info("Spotify Automation permission: \(from, privacy: .public) -> \(to, privacy: .public)")
        }
        if old.request != flow.request {
            Log.media.info("Spotify Automation request: \(String(describing: flow.request), privacy: .public)")
        }
    }

    /// Reconciles `isSpotifyRunning` with the system and drops playback state when Spotify is gone.
    private func syncRunningState() {
        let running = isEnabled && SpotifyApp.isRunning
        if running != isSpotifyRunning { isSpotifyRunning = running }
        if running {
            updatePermission { $0.spotifyDidStart() }
        } else {
            if isEnabled { updatePermission { $0.spotifyDidStop() } }
            clearPlayback()
        }
    }

    /// Feature switched off: forget everything and stop all timers.
    private func resetState() {
        cancelTimers()
        retryTask?.cancel()
        launchTask?.cancel()
        cancelPermissionTasks()
        updatePermission { $0.cancelRequest() }
        isRefreshing = false
        refreshQueued = false
        retryCount = 0
        if isSpotifyRunning { isSpotifyRunning = false }
        clearPlayback()
    }

    private func clearPlayback() {
        cancelTimers()
        authoritativeTrackID = nil
        if snapshot != nil { snapshot = nil }
        clearArtwork()
    }

    // MARK: Timers (only while they are needed)

    private func cancelTimers() {
        pollTask?.cancel()
        pollTask = nil
        pollInterval = nil
        trackEndTask?.cancel()
        trackEndTask = nil
    }

    private func updateTimers() {
        updatePollTask()
        updateTrackEndTask()
    }

    /// Resync poll: only while the Home tab is visible, Spotify is playing and permission is granted.
    private func updatePollTask() {
        let interval = SpotifyRefreshPlan.pollInterval(
            isEnabled: isEnabled, isSpotifyRunning: isSpotifyRunning,
            isAutomationGranted: automationPermission == .granted, isPlaying: isPlaying,
            isHomeTabVisible: isHomeTabVisible)
        if interval == pollInterval, (interval == nil) == (pollTask == nil) { return }
        pollTask?.cancel()
        pollTask = nil
        pollInterval = interval
        guard let interval else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 3))
                guard !Task.isCancelled, let self else { return }
                self.requestRefresh()
            }
        }
    }

    /// One-shot refresh right after the current track should have ended (missed notification safety net).
    private func updateTrackEndTask() {
        trackEndTask?.cancel()
        trackEndTask = nil
        guard isEnabled, isSpotifyRunning, automationPermission == .granted, let trackID = snapshot?.track?.id,
            let delay = SpotifyRefreshPlan.trackEndRefreshDelay(for: snapshot, at: Date())
        else { return }
        if let fired = trackEndRefreshes, fired.trackID == trackID, fired.count >= Self.maxTrackEndRefreshesPerTrack {
            return
        }
        trackEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let count = self.trackEndRefreshes?.trackID == trackID ? (self.trackEndRefreshes?.count ?? 0) : 0
            self.trackEndRefreshes = (trackID, count + 1)
            self.requestRefresh()
        }
    }

    private static let maxTrackEndRefreshesPerTrack = 2

    // MARK: Artwork

    private func updateArtwork() {
        guard isSpotifyRunning, let track = snapshot?.track else {
            clearArtwork()
            return
        }
        // The oEmbed fallback is used only once AppleScript has had its say (or is not permitted at all), so a
        // normal track change costs a single image request.
        let scriptConfirmed = automationPermission != .granted || authoritativeTrackID == track.id
        guard let source = SpotifyArtworkPolicy.source(for: track, allowOEmbedFallback: scriptConfirmed) else {
            // Not known yet (the notification carries no cover URL): keep the previous cover so the change is a
            // smooth crossfade. Once the script has answered and there is still no URL (ads, local files), clear.
            if scriptConfirmed { clearArtwork() }
            return
        }
        let key = source.cacheKey
        if key == currentArtworkKey { return }
        currentArtworkKey = key
        artworkTask?.cancel()
        artworkTask = nil
        if let cached = artworkLoader.cachedResult(for: source) {
            showArtwork(cached)
            return
        }
        // The old cover stays until the new one has loaded; a failed load clears it.
        artworkTask = Task { [weak self, loader = artworkLoader] in
            let result = await loader.load(source)
            guard let self, !Task.isCancelled, self.currentArtworkKey == key else { return }
            if let result {
                self.showArtwork(result)
            } else {
                // Keep the key: a failed URL is not retried on every poll, only when the track changes.
                self.artwork = nil
                self.accent = nil
            }
        }
    }

    private func showArtwork(_ result: MediaArtworkResult) {
        artwork = result.image
        accent = result.accent
    }

    private func clearArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        currentArtworkKey = nil
        if artwork != nil { artwork = nil }
        if accent != nil { accent = nil }
    }
}
