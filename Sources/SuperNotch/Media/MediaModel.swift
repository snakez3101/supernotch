// Owner: media stream. Observable Spotify state for the views (SPEC §D.4 `MediaModel`, FROZEN API).
//
// Data flow (SPEC §A.5, §F.1):
//   Spotify notification ──► instant snapshot from userInfo ──┐
//                                                             ├──► `snapshot` (position is EXTRAPOLATED by the
//   one batched AppleScript (background queue) ───────────────┘     views from `positionSeconds/Timestamp`)
//
// The AppleScript only runs (a) after a notification, (b) when the Home tab opens, (c) every few seconds while the
// Home tab is visible AND Spotify is playing, (d) once shortly after a track should have ended. While the notch is
// closed there are no timers and no Apple Events: the island only needs the cover and the playing flag.
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
    private(set) var automationPermission: MediaAutomationPermission = .unknown
    /// Dominant saturated colour of the current cover, for subtle tints. nil for greyscale / missing covers.
    private(set) var accent: MediaAccentColor?

    /// Settings › Music › "Enable Spotify".
    var isEnabled: Bool { settingsStore.settings.spotifyEnabled }
    var hasTrack: Bool { isSpotifyRunning && snapshot?.track != nil }
    var isPlaying: Bool { isSpotifyRunning && (snapshot?.isPlaying ?? false) }
    /// Spotify is running and macOS lets us send it commands.
    var canControl: Bool { isSpotifyRunning && automationPermission == .granted }

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
    @ObservationIgnored private var isRequestingPermission = false
    /// "Allow access" was clicked while Spotify was not running: ask as soon as it has launched (within a minute).
    @ObservationIgnored private var pendingPermissionRequestAt: Date?
    /// Track id of the last AppleScript-confirmed snapshot (gates the oEmbed cover fallback).
    @ObservationIgnored private var authoritativeTrackID: String?
    @ObservationIgnored private var currentArtworkKey: String?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollInterval: TimeInterval?
    @ObservationIgnored private var trackEndTask: Task<Void, Never>?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

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

    /// Asks macOS for permission to control Spotify. Spotify must be running for the system prompt to appear,
    /// so when it is not, this launches Spotify and asks as soon as it is up.
    func requestAutomationPermission() {
        guard isEnabled else { return }
        syncRunningState()
        guard isSpotifyRunning else {
            pendingPermissionRequestAt = Date()
            controller.openSpotify()
            return
        }
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        Task { [weak self] in
            guard let self else { return }
            let permission = await self.controller.determinePermission(askUser: true)
            self.isRequestingPermission = false
            self.applyPermission(permission)
            if permission == .granted { self.requestRefresh() }
        }
    }

    /// Silent re-check (no prompt), e.g. after the user came back from System Settings.
    func recheckAutomationPermission() {
        guard isStarted, isEnabled else { return }
        syncRunningState()
        guard isSpotifyRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            let permission = await self.controller.determinePermission(askUser: false)
            self.applyPermission(permission)
            if permission == .granted { self.requestRefresh() }
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
            if let info, let merged = SpotifySnapshotMerger.merge(previous: snapshot, info: info, now: Date()) {
                if merged != snapshot { snapshot = merged }
                updateArtwork()
                updateTimers()
            }
            requestRefresh()  // the script is the source of truth (cover URL, exact position, flags)
        case .launched:
            syncRunningState()
            scheduleLaunchRefresh()
        case .terminated:
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
            if let requestedAt = self.pendingPermissionRequestAt {
                self.pendingPermissionRequestAt = nil
                if Date().timeIntervalSince(requestedAt) < 60 { self.requestAutomationPermission() }
                else { self.requestRefresh() }
            } else {
                self.requestRefresh()
            }
        }
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
            let permission = await controller.determinePermission(askUser: false)
            applyPermission(permission)
            guard automationPermission == .granted else { return }
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
            applyPermission(.granted)
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
        case .permissionDenied, .consentRequired:
            if let implied = failure.impliedPermission { applyPermission(implied) }
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

    private func applyPermission(_ permission: MediaAutomationPermission) {
        if permission != automationPermission {
            automationPermission = permission
            Log.media.info("Spotify Automation permission: \(permission.rawValue, privacy: .public)")
        }
        if permission == .notRunning { syncRunningState() }
    }

    /// Reconciles `isSpotifyRunning` with the system and drops playback state when Spotify is gone.
    private func syncRunningState() {
        let running = isEnabled && SpotifyApp.isRunning
        if running != isSpotifyRunning { isSpotifyRunning = running }
        if running {
            if automationPermission == .notRunning { automationPermission = .unknown }
        } else {
            if isEnabled, automationPermission != .notRunning { automationPermission = .notRunning }
            clearPlayback()
        }
    }

    /// Feature switched off: forget everything and stop all timers.
    private func resetState() {
        cancelTimers()
        retryTask?.cancel()
        launchTask?.cancel()
        pendingPermissionRequestAt = nil
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
        guard isEnabled, isSpotifyRunning, automationPermission == .granted,
            let delay = SpotifyRefreshPlan.trackEndRefreshDelay(for: snapshot, at: Date())
        else { return }
        trackEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.requestRefresh()
        }
    }

    // MARK: Artwork

    private func updateArtwork() {
        guard isSpotifyRunning, let track = snapshot?.track else {
            clearArtwork()
            return
        }
        // The oEmbed fallback is used only once AppleScript has had its say (or is not permitted at all), so a
        // normal track change costs a single image request.
        let allowFallback = automationPermission != .granted || authoritativeTrackID == track.id
        guard let source = SpotifyArtworkPolicy.source(for: track, allowOEmbedFallback: allowFallback) else {
            clearArtwork()  // no cover (yet): never keep the previous track's cover
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
        artwork = nil
        accent = nil
        artworkTask = Task { [weak self, loader = artworkLoader] in
            let result = await loader.load(source)
            guard let self, !Task.isCancelled, self.currentArtworkKey == key, let result else { return }
            self.showArtwork(result)
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
