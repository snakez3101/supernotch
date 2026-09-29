// Owner: notch-shell. Seed tests by the foundation.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("NotchGeometry")
struct NotchGeometryTests {
    // 14" MacBook Pro default scaled resolution: 1512 × 982, notch ≈ 185 × 32.
    let mbp14 = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32, auxiliaryTopLeftWidth: 663.5,
        auxiliaryTopRightWidth: 663.5)

    @Test func notchRect() throws {
        let geometry = try #require(mbp14)
        #expect(geometry.notchRect == CGRect(x: 663.5, y: 950, width: 185, height: 32))
        #expect(geometry.panelFrame.maxY == 982)
        #expect(geometry.panelFrame.midX == 756)
    }

    @Test func noNotch() {
        #expect(NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
            auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil) == nil)
    }

    @Test func sizesStayCompactAndFitPanel() throws {
        let geometry = try #require(mbp14)
        let expanded = geometry.size(for: .expanded(.home))
        #expect(expanded.width <= NotchMetrics.panelSize.width - 24)
        #expect(expanded.height <= NotchMetrics.panelSize.height - 24)
        let request = PopupRequest.claudePermission(requestID: "r", hostAppBundleID: nil, now: Date())
        #expect(geometry.size(for: .peek(request)).height == 32 + NotchMetrics.permissionPeekExtraHeight)
        #expect(geometry.size(for: .closed, closedWidthExtra: 72).width == geometry.notchSize.width + 72)
    }
}

@Suite("HoverIntent")
struct HoverIntentTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func dwellThenOpen() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        #expect(intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0) == .schedule(at: t0 + 0.15))
        #expect(intent.timerFired(now: t0 + 0.15) == .open)
    }

    @Test func leavingBeforeDwellCancels() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        _ = intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0)
        _ = intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0 + 0.05)
        #expect(intent.timerFired(now: t0 + 0.15) == .none)
    }

    @Test func graceBeforeClose() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        intent.reset(isOpen: true)
        #expect(intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0) == .schedule(at: t0 + 0.35))
        _ = intent.mouseMoved(inTrigger: false, inOpenRegion: true, now: t0 + 0.1)
        #expect(intent.timerFired(now: t0 + 0.35) == .none)
    }
}

@Suite("PopupPolicy")
struct PopupPolicyTests {
    let now = Date(timeIntervalSince1970: 0)

    @Test func redAlwaysPopsEvenInFullscreen() {
        let red = PopupRequest.claudeNeedsInput(sessionID: "s", hostAppBundleID: "com.apple.Terminal", now: now)
        let context = PopupContext(isFullscreen: true, frontmostAppBundleID: "com.apple.Terminal")
        #expect(PopupPolicy.decide(red, context: context) == .show)
    }

    @Test func greenIsFocusAwareAndHiddenInFullscreen() {
        let green = PopupRequest.claudeDone(sessionID: "s", hostAppBundleID: "com.apple.Terminal", autoDismissAfter: 4,
            now: now)
        #expect(PopupPolicy.decide(green, context: PopupContext(frontmostAppBundleID: "com.apple.Terminal")) == .suppress)
        #expect(PopupPolicy.decide(green, context: PopupContext(frontmostAppBundleID: "com.apple.Safari")) == .show)
        #expect(PopupPolicy.decide(green, context: PopupContext(isFullscreen: true)) == .suppress)
    }

    @Test func criticalFirst() {
        let green = PopupRequest.claudeDone(sessionID: "a", hostAppBundleID: nil, autoDismissAfter: 4, now: now)
        let red = PopupRequest.claudePermission(requestID: "r", hostAppBundleID: nil, now: now + 5)
        #expect(PopupPolicy.next(from: [green, red]) == red)
    }
}
