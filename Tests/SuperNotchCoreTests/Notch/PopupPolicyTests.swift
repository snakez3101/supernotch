// Owner: notch-shell.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("PopupPolicy")
struct PopupPolicyTests {
    let now = Date(timeIntervalSince1970: 0)

    @Test func redAlwaysPopsEvenInFullscreen() {
        let red = PopupRequest.claudeNeedsInput(sessionID: "s", hostAppBundleID: "com.apple.Terminal", now: now)
        let context = PopupContext(isFullscreen: true, frontmostAppBundleID: "com.apple.Terminal")
        #expect(PopupPolicy.decide(red, context: context) == .show)
        let permission = PopupRequest.claudePermission(requestID: "r", hostAppBundleID: nil, now: now)
        #expect(PopupPolicy.decide(permission, context: context) == .show)
    }

    @Test func greenIsFocusAwareAndHiddenInFullscreen() {
        let green = PopupRequest.claudeDone(
            sessionID: "s", hostAppBundleID: "com.apple.Terminal", autoDismissAfter: 4, now: now)
        #expect(
            PopupPolicy.decide(green, context: PopupContext(frontmostAppBundleID: "com.apple.Terminal")) == .suppress)
        #expect(PopupPolicy.decide(green, context: PopupContext(frontmostAppBundleID: "com.apple.Safari")) == .show)
        #expect(PopupPolicy.decide(green, context: PopupContext(isFullscreen: true)) == .suppress)
    }

    @Test func greenInFullscreenShowsWhenHidingIsOff() {
        let green = PopupRequest.claudeDone(sessionID: "s", hostAppBundleID: nil, autoDismissAfter: 4, now: now)
        #expect(PopupPolicy.decide(green, context: PopupContext(isFullscreen: true, hideInFullscreen: false)) == .show)
    }

    @Test func greenFocusAwarenessCanBeTurnedOff() {
        let green = PopupRequest.claudeDone(sessionID: "s", hostAppBundleID: "com.apple.Terminal", autoDismissAfter: 4,
            now: now)
        let context = PopupContext(frontmostAppBundleID: "com.apple.Terminal", skipDoneWhenHostFrontmost: false)
        #expect(PopupPolicy.decide(green, context: context) == .show)
    }

    @Test func expandedQueuesRedAndDropsGreen() {
        let context = PopupContext(isExpanded: true)
        let red = PopupRequest.claudePermission(requestID: "r", hostAppBundleID: nil, now: now)
        let green = PopupRequest.claudeDone(sessionID: "s", hostAppBundleID: nil, autoDismissAfter: 4, now: now)
        #expect(PopupPolicy.decide(red, context: context) == .queue)
        #expect(PopupPolicy.decide(green, context: context) == .suppress)
    }

    @Test func settingsAndMissingNotchSuppress() {
        let red = PopupRequest.claudePermission(requestID: "r", hostAppBundleID: nil, now: now)
        let green = PopupRequest.claudeDone(sessionID: "s", hostAppBundleID: nil, autoDismissAfter: 4, now: now)
        #expect(PopupPolicy.decide(red, context: PopupContext(isNotchAvailable: false)) == .suppress)
        #expect(PopupPolicy.decide(red, context: PopupContext(popupsForNeedsInput: false)) == .suppress)
        #expect(PopupPolicy.decide(green, context: PopupContext(popupsForDone: false)) == .suppress)
    }

    @Test func contextFromSettings() {
        var settings = AppSettings()
        settings.popupOnDone = false
        settings.hideInFullscreen = false
        let context = PopupContext(
            settings: settings, isFullscreen: true, isExpanded: false, isNotchAvailable: true,
            frontmostAppBundleID: "x")
        #expect(!context.popupsForDone)
        #expect(!context.hideInFullscreen)
        #expect(context.popupsForNeedsInput)
    }

    @Test func criticalFirst() {
        let green = PopupRequest.claudeDone(sessionID: "a", hostAppBundleID: nil, autoDismissAfter: 4, now: now)
        let red = PopupRequest.claudePermission(requestID: "r", hostAppBundleID: nil, now: now + 5)
        #expect(PopupPolicy.next(from: [green, red]) == red)
    }

    @Test func oldestFirstWithinPriority() {
        let first = PopupRequest.claudePermission(requestID: "1", hostAppBundleID: nil, now: now)
        let second = PopupRequest.claudePermission(requestID: "2", hostAppBundleID: nil, now: now + 1)
        #expect(PopupPolicy.next(from: [second, first]) == first)
        #expect(PopupPolicy.next(from: []) == nil)
    }
}

@Suite("NotchPopupQueue")
struct NotchPopupQueueTests {
    let t0 = Date(timeIntervalSince1970: 1000)
    let idle = PopupContext()

    func permission(_ id: String, at time: Date) -> PopupRequest {
        PopupRequest.claudePermission(requestID: id, hostAppBundleID: nil, now: time)
    }

    func done(_ session: String, at time: Date, host: String? = nil) -> PopupRequest {
        PopupRequest.claudeDone(sessionID: session, hostAppBundleID: host, autoDismissAfter: 4, now: time)
    }

    @Test func criticalShowsImmediately() {
        var queue = NotchPopupQueue()
        let red = permission("r", at: t0)
        #expect(queue.present(red, context: idle, now: t0) == .show(red))
        #expect(queue.current == red)
    }

    @Test func greenIsDebouncedThenShown() {
        var queue = NotchPopupQueue()
        let green = done("s", at: t0)
        #expect(queue.present(green, context: idle, now: t0) == .none)
        #expect(queue.nextDeadline() == t0 + 0.8)
        #expect(queue.tick(context: idle, now: t0 + 0.8) == .show(green))
    }

    @Test func greenFlippingBackToYellowNeverPops() {
        var queue = NotchPopupQueue()
        let green = done("s", at: t0)
        _ = queue.present(green, context: idle, now: t0)
        #expect(queue.withdraw(id: green.id, context: idle, now: t0 + 0.5) == .none)
        #expect(queue.tick(context: idle, now: t0 + 0.8) == .none)
        #expect(queue.isEmpty)
    }

    @Test func greenAutoDismissesAndPausesUnderThePointer() {
        var queue = NotchPopupQueue(debounce: 0)
        let green = done("s", at: t0)
        #expect(queue.present(green, context: idle, now: t0) == .show(green))
        #expect(queue.nextDeadline() == t0 + 4)
        queue.setAutoDismissPaused(true, now: t0 + 1)
        #expect(queue.tick(context: idle, now: t0 + 5) == .none)
        #expect(queue.current == green)
        // Leaving restarts the clock.
        queue.setAutoDismissPaused(false, now: t0 + 6)
        #expect(queue.nextDeadline() == t0 + 10)
        #expect(queue.tick(context: idle, now: t0 + 10) == .hide)
    }

    @Test func sameIDReplaces() {
        var queue = NotchPopupQueue(debounce: 0)
        let question = PopupRequest.claudeNeedsInput(sessionID: "s", hostAppBundleID: nil, now: t0)
        _ = queue.present(question, context: idle, now: t0)
        let doneNow = done("s", at: t0 + 1)
        #expect(queue.present(doneNow, context: idle, now: t0 + 1) == .show(doneNow))
        #expect(queue.current == doneNow)
        #expect(queue.queued.isEmpty)
        // Identical re-present is a no-op.
        #expect(queue.present(doneNow, context: idle, now: t0 + 2) == .none)
    }

    @Test func replacementThatIsNowSuppressedHides() {
        var queue = NotchPopupQueue(debounce: 0)
        let question = PopupRequest.claudeNeedsInput(sessionID: "s", hostAppBundleID: "com.apple.Terminal", now: t0)
        _ = queue.present(question, context: idle, now: t0)
        let context = PopupContext(frontmostAppBundleID: "com.apple.Terminal")
        #expect(queue.present(done("s", at: t0 + 1, host: "com.apple.Terminal"), context: context, now: t0 + 1) == .hide)
        #expect(queue.current == nil)
    }

    @Test func severalPermissionsQueueOldestFirst() {
        var queue = NotchPopupQueue()
        let first = permission("1", at: t0)
        let second = permission("2", at: t0 + 1)
        let third = permission("3", at: t0 + 2)
        _ = queue.present(first, context: idle, now: t0)
        #expect(queue.present(third, context: idle, now: t0 + 2) == .none)
        #expect(queue.present(second, context: idle, now: t0 + 2) == .none)
        #expect(queue.position(of: first.id) == NotchPopupPosition(index: 1, total: 3))
        #expect(queue.position(of: third.id) == NotchPopupPosition(index: 3, total: 3))
        #expect(queue.withdraw(id: first.id, context: idle, now: t0 + 3) == .show(second))
        #expect(queue.position(of: second.id) == NotchPopupPosition(index: 1, total: 2))
        #expect(queue.withdraw(id: second.id, context: idle, now: t0 + 4) == .show(third))
        #expect(queue.withdraw(id: third.id, context: idle, now: t0 + 5) == .hide)
    }

    @Test func redPreemptsGreen() {
        var queue = NotchPopupQueue(debounce: 0)
        let green = done("a", at: t0)
        _ = queue.present(green, context: idle, now: t0)
        let red = permission("r", at: t0 + 1)
        #expect(queue.present(red, context: idle, now: t0 + 1) == .show(red))
        // The green notice is dropped, not re-shown after the red one.
        #expect(queue.withdraw(id: red.id, context: idle, now: t0 + 2) == .hide)
    }

    @Test func greenWaitsBehindRed() {
        var queue = NotchPopupQueue(debounce: 0)
        let red = permission("r", at: t0)
        _ = queue.present(red, context: idle, now: t0)
        let green = done("a", at: t0 + 1)
        #expect(queue.present(green, context: idle, now: t0 + 1) == .none)
        #expect(queue.withdraw(id: red.id, context: idle, now: t0 + 2) == .show(green))
    }

    @Test func expandedQueuesRedAndShowsItAfterCollapse() {
        var queue = NotchPopupQueue(debounce: 0)
        let expanded = PopupContext(isExpanded: true)
        let red = permission("r", at: t0)
        #expect(queue.present(red, context: expanded, now: t0) == .none)
        #expect(queue.present(done("s", at: t0), context: expanded, now: t0) == .none)
        #expect(queue.queued == [red])
        #expect(queue.reevaluate(context: idle, now: t0 + 5) == .show(red))
    }

    @Test func expandingOverAPeekRequeuesRedAndDropsGreen() {
        var queue = NotchPopupQueue(debounce: 0)
        let red = permission("r", at: t0)
        _ = queue.present(red, context: idle, now: t0)
        queue.requeueCurrent()
        #expect(queue.current == nil)
        #expect(queue.queued == [red])
        #expect(queue.reevaluate(context: idle, now: t0 + 1) == .show(red))

        let green = done("s", at: t0 + 2)
        _ = queue.withdraw(id: red.id, context: idle, now: t0 + 2)
        _ = queue.present(green, context: idle, now: t0 + 2)
        queue.requeueCurrent()
        #expect(queue.isEmpty)
    }

    @Test func fullscreenDropsGreenButKeepsRed() {
        var queue = NotchPopupQueue(debounce: 0)
        let red = permission("r", at: t0)
        let green = done("s", at: t0)
        _ = queue.present(red, context: idle, now: t0)
        _ = queue.present(green, context: idle, now: t0)
        let fullscreen = PopupContext(isFullscreen: true)
        #expect(queue.reevaluate(context: fullscreen, now: t0 + 1) == .none)
        // The waiting green is suppressed when it would come up in fullscreen.
        #expect(queue.withdraw(id: red.id, context: fullscreen, now: t0 + 2) == .hide)
        #expect(queue.isEmpty)
    }

    @Test func permissionCardsExpire() {
        var queue = NotchPopupQueue()
        let red = permission("r", at: t0)
        _ = queue.present(red, context: idle, now: t0)
        #expect(queue.nextDeadline() == t0 + NotchPopupQueue.permissionTimeout)
        #expect(queue.tick(context: idle, now: t0 + 289) == .none)
        #expect(queue.tick(context: idle, now: t0 + 290) == .hide)
    }

    @Test func queuedGreenGoesStale() {
        var queue = NotchPopupQueue(debounce: 0)
        let red = PopupRequest.claudeNeedsInput(sessionID: "q", hostAppBundleID: nil, now: t0)
        _ = queue.present(red, context: idle, now: t0)
        _ = queue.present(done("s", at: t0), context: idle, now: t0)
        #expect(queue.withdraw(id: red.id, context: idle, now: t0 + 61) == .hide)
        #expect(queue.isEmpty)
    }

    @Test func dismissCurrentAdvances() {
        var queue = NotchPopupQueue(debounce: 0)
        let question = PopupRequest.claudeNeedsInput(sessionID: "q", hostAppBundleID: nil, now: t0)
        let red = permission("r", at: t0 + 1)
        _ = queue.present(question, context: idle, now: t0)
        _ = queue.present(red, context: idle, now: t0 + 1)
        #expect(queue.dismissCurrent(context: idle, now: t0 + 2) == .show(red))
        #expect(queue.dismissCurrent(context: idle, now: t0 + 3) == .hide)
        #expect(queue.dismissCurrent(context: idle, now: t0 + 4) == .none)
    }

    @Test func removeAllClears() {
        var queue = NotchPopupQueue()
        _ = queue.present(permission("r", at: t0), context: idle, now: t0)
        _ = queue.present(done("s", at: t0), context: idle, now: t0)
        queue.removeAll()
        #expect(queue.isEmpty)
        #expect(queue.nextDeadline() == nil)
    }
}
