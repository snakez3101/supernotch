// Owner: FOUNDATION. Tests for the FOUNDATION contract types in Core (NotchMetrics, NotchPresentation,
// PlaybackSnapshot, ShelfItem, ClipboardEntry).
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("NotchMetrics (foundation)")
struct FoundationNotchMetricsTests {
    @Test func everyStateFitsTheFixedPanel() {
        // Tallest real notch (16" MacBook Pro) is 38 pt; leave room for spring overshoot.
        for notchHeight in [CGFloat(32), 37, 38] {
            #expect(notchHeight + NotchMetrics.expandedExtraHeight < NotchMetrics.panelSize.height - 20)
            #expect(notchHeight + NotchMetrics.permissionPeekExtraHeight < NotchMetrics.panelSize.height - 20)
        }
        #expect(NotchMetrics.expandedWidth <= NotchMetrics.panelSize.width - 20)
        #expect(NotchMetrics.permissionPeekWidth <= NotchMetrics.panelSize.width - 20)
        #expect(NotchMetrics.peekWidth < NotchMetrics.permissionPeekWidth)
    }

    @Test func compactSizesMatchSpec() {
        #expect(NotchMetrics.panelSize == CGSize(width: 580, height: 340))
        #expect(NotchMetrics.expandedWidth == 540)
        #expect(NotchMetrics.expandedExtraHeight == 156)
        #expect(NotchMetrics.peekWidth == 420 && NotchMetrics.peekExtraHeight == 64)
        #expect(NotchMetrics.permissionPeekWidth == 480 && NotchMetrics.permissionPeekExtraHeight == 128)
        #expect(NotchMetrics.musicColumnWidth == 200)
        #expect(NotchMetrics.claudeRowHeight == 26 && NotchMetrics.claudeVisibleRows == 4)
        #expect(NotchMetrics.closedRadii.top == 6 && NotchMetrics.closedRadii.bottom == 12)
        #expect(NotchMetrics.peekRadii.top == 10 && NotchMetrics.peekRadii.bottom == 20)
        #expect(NotchMetrics.expandedRadii.top == 12 && NotchMetrics.expandedRadii.bottom == 24)
        #expect(NotchMetrics.contentFadeInDelay == 0.06)
    }

    @Test func homeColumnsFitTheExpandedWidth() {
        let inner = NotchMetrics.expandedWidth - 2 * NotchMetrics.contentPadding
        let claudeColumn = inner - NotchMetrics.musicColumnWidth - 21  // hairline + 2 × 10 pt gap
        #expect(claudeColumn >= 270 && claudeColumn <= 300)  // "Claude ≈ 280 pt" (§A.5)
    }

    @Test func islandWingsHoldTheirContent() {
        let dots = CGFloat(NotchMetrics.claudeMaxDots) * NotchMetrics.claudeDotDiameter
            + CGFloat(NotchMetrics.claudeMaxDots - 1) * NotchMetrics.claudeDotSpacing
        #expect(dots <= NotchMetrics.islandWingWidth)
        #expect(NotchMetrics.islandArtworkSize <= NotchMetrics.islandWingWidth)
        #expect(NotchMetrics.islandVisualizerSize.width <= NotchMetrics.islandWingWidth)
        #expect(NotchMetrics.warningDotDiameter <= NotchMetrics.warningWingWidth)
    }

    @Test(arguments: [ClosedNotchMode.invisible, .island])
    func closedWithoutContentIsTheBareNotch(mode: ClosedNotchMode) {
        let wings = NotchMetrics.closedWings(mode: mode, hasIslandContent: false, showsUsageWarning: false)
        #expect(wings.leading == 0 && wings.trailing == 0)
        #expect(NotchMetrics.closedWidthExtra(mode: mode, hasIslandContent: false, showsUsageWarning: false) == 0)
    }

    @Test func islandWithContentHasBothWings() {
        for warning in [false, true] {
            let wings = NotchMetrics.closedWings(mode: .island, hasIslandContent: true, showsUsageWarning: warning)
            #expect(wings.leading == NotchMetrics.islandWingWidth)
            #expect(wings.trailing == NotchMetrics.islandWingWidth)
        }
        #expect(
            NotchMetrics.closedWidthExtra(mode: .island, hasIslandContent: true, showsUsageWarning: false)
                == 2 * NotchMetrics.islandWingWidth)
    }

    @Test(arguments: [ClosedNotchMode.invisible, .island])
    func usageWarningAloneAddsOnlyARightWing(mode: ClosedNotchMode) {
        let wings = NotchMetrics.closedWings(mode: mode, hasIslandContent: false, showsUsageWarning: true)
        #expect(wings.leading == 0)
        #expect(wings.trailing == NotchMetrics.warningWingWidth)
        #expect(
            NotchMetrics.closedWidthExtra(mode: mode, hasIslandContent: false, showsUsageWarning: true)
                == NotchMetrics.warningWingWidth)
    }

    @Test func invisibleModeIgnoresIslandContent() {
        let wings = NotchMetrics.closedWings(mode: .invisible, hasIslandContent: true, showsUsageWarning: false)
        #expect(wings.leading == 0 && wings.trailing == 0)
    }

    @Test func glassGradientStopsFollowTheNotchHeight() {
        let expanded = NotchMetrics.glassGradientStops(notchHeight: 32, shapeHeight: 32 + 156)
        #expect(abs(expanded.solidEnd - 32.0 / 188.0) < 0.0001)
        #expect(expanded.clearAt == NotchMetrics.glassClearLocation)

        // Short peek: the fade keeps at least `glassMinimumFade` below the black band.
        let peek = NotchMetrics.glassGradientStops(notchHeight: 38, shapeHeight: 38 + 64)
        #expect(peek.solidEnd < peek.clearAt)
        #expect(peek.clearAt - peek.solidEnd >= NotchMetrics.glassMinimumFade - 0.0001)
    }

    @Test(arguments: [
        (CGFloat(0), CGFloat(0)), (32, 0), (500, 100), (-5, 100), (32, -1), (CGFloat.nan, 100), (32, .infinity),
    ])
    func glassGradientStopsAreAlwaysValid(notchHeight: CGFloat, shapeHeight: CGFloat) {
        let stops = NotchMetrics.glassGradientStops(notchHeight: notchHeight, shapeHeight: shapeHeight)
        #expect(stops.solidEnd >= 0)
        #expect(stops.solidEnd < stops.clearAt)
        #expect(stops.clearAt <= 1)
    }
}

@Suite("NotchPresentation (foundation)")
struct FoundationNotchPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func presentationHelpers() {
        let request = PopupRequest.claudeNeedsInput(sessionID: "s1", hostAppBundleID: nil, now: now)
        #expect(NotchPresentation.closed.isClosed)
        #expect(!NotchPresentation.closed.isExpanded)
        #expect(NotchPresentation.expanded(.shelf).isExpanded)
        #expect(NotchPresentation.peek(request).peekRequest == request)
        #expect(NotchPresentation.expanded(.home).peekRequest == nil)
    }

    @Test func sessionPopupsShareOneIdSoTheyReplaceEachOther() {
        let done = PopupRequest.claudeDone(sessionID: "s1", hostAppBundleID: "com.apple.Terminal",
            autoDismissAfter: 4, now: now)
        let question = PopupRequest.claudeNeedsInput(sessionID: "s1", hostAppBundleID: nil, now: now)
        #expect(done.id == question.id)
        #expect(done.id == PopupRequest.claudeSessionID("s1"))
        #expect(done.priority == .info && done.autoDismissAfter == 4)
        #expect(question.priority == .critical && question.autoDismissAfter == nil)
        #expect(done.payload == .claudeSession(sessionID: "s1"))
    }

    @Test func permissionPopupsAreCriticalAndDistinctFromSessionPopups() {
        let card = PopupRequest.claudePermission(requestID: "r1", hostAppBundleID: nil, now: now)
        #expect(card.priority == .critical)
        #expect(card.payload == .claudePermission(requestID: "r1"))
        #expect(card.id == PopupRequest.claudePermissionID("r1"))
        #expect(card.id != PopupRequest.claudeSessionID("r1"))
    }

    @Test func priorityOrder() {
        #expect(PopupPriority.info < .critical)
        #expect([PopupPriority.critical, .info].sorted() == [.info, .critical])
    }

    @Test func tabsAreStableForPersistence() {
        #expect(NotchTab.allCases.map(\.rawValue) == ["home", "shelf"])
    }
}

@Suite("Contract types (foundation)")
struct FoundationContractTypesTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(_ id: String = "spotify:track:4uLU6hMCjMI75M1A2tKUQC", duration: Double = 200) -> TrackInfo {
        TrackInfo(id: id, title: "Song", artist: "Artist", album: "Album", durationSeconds: duration,
            artworkURL: nil)
    }

    @Test func trackKinds() {
        #expect(track().openURL == "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        #expect(track("spotify:episode:abc").isEpisode)
        #expect(track("spotify:episode:abc").openURL == "https://open.spotify.com/episode/abc")
        #expect(track("spotify:ad:xyz").isAd)
        #expect(track("spotify:ad:xyz").openURL == nil)
        #expect(track("spotify:local:Artist:Album:Title:123").isLocal)
        #expect(track("spotify:local:Artist:Album:Title:123").openURL == nil)
    }

    @Test func positionExtrapolatesOnlyWhilePlaying() {
        let playing = PlaybackSnapshot(track: track(), state: .playing, positionSeconds: 10, positionTimestamp: start)
        #expect(playing.position(at: start.addingTimeInterval(5)) == 15)
        #expect(playing.position(at: start.addingTimeInterval(-5)) == 10)  // clock skew never rewinds
        #expect(playing.position(at: start.addingTimeInterval(1_000)) == 200)  // clamped to the duration
        #expect(playing.progress(at: start.addingTimeInterval(90)) == 0.5)

        let paused = PlaybackSnapshot(track: track(), state: .paused, positionSeconds: 10, positionTimestamp: start)
        #expect(paused.position(at: start.addingTimeInterval(60)) == 10)
        #expect(!paused.isPlaying && playing.isPlaying)

        let noTrack = PlaybackSnapshot(track: nil, state: .stopped, positionSeconds: 0, positionTimestamp: start)
        #expect(noTrack.progress(at: start) == 0)
    }

    @Test func timeFormatting() {
        #expect(PlaybackSnapshot.formatTime(0) == "0:00")
        #expect(PlaybackSnapshot.formatTime(62.9) == "1:02")
        #expect(PlaybackSnapshot.formatTime(3_723) == "1:02:03")
        #expect(PlaybackSnapshot.formatTime(-1) == "0:00")
        #expect(PlaybackSnapshot.formatTime(.nan) == "0:00")
        #expect(PlaybackSnapshot.formatTime(.infinity) == "0:00")
    }

    @Test func snapshotCodableRoundTrip() throws {
        let snapshot = PlaybackSnapshot(
            track: track(), state: .playing, positionSeconds: 3, positionTimestamp: start, shuffling: true,
            repeating: false, volume: 42)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(PlaybackSnapshot.self, from: data) == snapshot)
    }

    @Test func shelfItemStoredPath() throws {
        let file = ShelfItem(
            kind: .file, displayName: "Report.pdf", storedRelativePath: "abc/Report.pdf", addedAt: start)
        #expect(file.storedPath(inShelfDirectory: "/S") == "/S/abc/Report.pdf")
        let text = ShelfItem(kind: .text, displayName: "hello", text: "hello", addedAt: start)
        #expect(text.storedPath(inShelfDirectory: "/S") == nil)
        #expect(!text.isPinned && text.addedDate == start)
        let decoded = try JSONDecoder().decode(ShelfItem.self, from: JSONEncoder().encode(file))
        #expect(decoded == file)
    }

    @Test func clipboardPreviewText() {
        let multiline = ClipboardEntry(content: .text("  first line\nsecond line  "), capturedAt: start)
        #expect(multiline.previewText == "first line second line")
        let long = ClipboardEntry(content: .text(String(repeating: "a", count: 300)), capturedAt: start)
        #expect(long.previewText.count == 200)
        #expect(long.previewText.hasSuffix("…"))
        #expect(ClipboardEntry(content: .files(["/a/b.txt"]), capturedAt: start).previewText == "b.txt")
        #expect(ClipboardEntry(content: .files(["/a/b.txt", "/c"]), capturedAt: start).previewText == "2 files")
        #expect(
            ClipboardEntry(content: .image(relativePath: "images/x.png", pixelWidth: 10, pixelHeight: 20),
                capturedAt: start).previewText == "Image 10×20")
        #expect(ClipboardEntry(content: .link("https://x.y"), capturedAt: start).previewText == "https://x.y")
    }

    @Test func clipboardHashIsStableAndDistinguishesKinds() {
        #expect(ClipboardEntry.hash(of: .text("abc")) == ClipboardEntry.hash(of: .text("abc")))
        #expect(ClipboardEntry.hash(of: .text("abc")) != ClipboardEntry.hash(of: .link("abc")))
        #expect(ClipboardEntry.hash(of: .files(["a", "b"])) != ClipboardEntry.hash(of: .files(["ab"])))
        // FNV-1a 64 reference values: the persisted hash must never change between releases.
        #expect(ClipboardEntry.hash(of: .text("")) == "8c80607b56a69fb")
        #expect(ClipboardEntry.hash(of: .text("héllo")) == "e38ac883e7a56a2e")
        let entry = ClipboardEntry(content: .text("x"), capturedAt: start)
        #expect(entry.contentHash == ClipboardEntry.hash(of: .text("x")))
        let custom = ClipboardEntry(content: .text("x"), capturedAt: start, contentHash: "pixels")
        #expect(custom.contentHash == "pixels")
    }

    @Test func clipboardEntryCodableRoundTrip() throws {
        let entry = ClipboardEntry(
            content: .image(relativePath: "images/1.png", pixelWidth: 3, pixelHeight: 4),
            sourceAppBundleID: "com.apple.Safari", sourceAppName: "Safari", capturedAt: start, pinned: true)
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
        #expect(decoded.isPinned)
    }
}
