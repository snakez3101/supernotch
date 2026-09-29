// Owner: notch-shell.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("HoverIntent")
struct HoverIntentTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func dwellThenOpen() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        #expect(intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0) == .schedule(at: t0 + 0.15))
        #expect(intent.pendingDeadline == t0 + 0.15)
        // Further samples inside the trigger do not restart the dwell.
        #expect(intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0 + 0.1) == .none)
        #expect(intent.timerFired(now: t0 + 0.15) == .open)
        #expect(intent.pendingDeadline == nil)
    }

    @Test func earlyTimerReschedules() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        _ = intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0)
        #expect(intent.timerFired(now: t0 + 0.05) == .schedule(at: t0 + 0.15))
    }

    @Test func leavingBeforeDwellCancels() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        _ = intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0)
        _ = intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0 + 0.05)
        #expect(intent.timerFired(now: t0 + 0.15) == .none)
    }

    @Test func reenteringRestartsTheDwell() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        _ = intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0)
        _ = intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0 + 0.05)
        #expect(intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0 + 0.1) == .schedule(at: t0 + 0.1 + 0.15))
        // The stale timer from the first entry just reschedules.
        #expect(intent.timerFired(now: t0 + 0.15) == .schedule(at: t0 + 0.1 + 0.15))
        #expect(intent.timerFired(now: t0 + 0.25) == .open)
    }

    @Test func passingOverTheMenuBarNeverOpens() {
        // Moving through the open region while closed does nothing: only the physical notch triggers.
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        #expect(intent.mouseMoved(inTrigger: false, inOpenRegion: true, now: t0) == .none)
        #expect(intent.timerFired(now: t0 + 1) == .none)
    }

    @Test func zeroDelayOpensImmediately() {
        var intent = HoverIntent(openDelay: 0, closeDelay: 0)
        #expect(intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0) == .open)
        intent.reset(isOpen: true)
        #expect(intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0 + 1) == .close)
    }

    @Test func graceBeforeClose() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        intent.reset(isOpen: true)
        #expect(intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0) == .schedule(at: t0 + 0.35))
        _ = intent.mouseMoved(inTrigger: false, inOpenRegion: true, now: t0 + 0.1)
        #expect(intent.timerFired(now: t0 + 0.35) == .none)
    }

    @Test func leavingForTheGraceCloses() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        intent.reset(isOpen: true)
        _ = intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0)
        #expect(intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0 + 0.2) == .none)
        #expect(intent.timerFired(now: t0 + 0.2) == .schedule(at: t0 + 0.35))
        #expect(intent.timerFired(now: t0 + 0.35) == .close)
        #expect(intent.leftAt == nil)
    }

    @Test func triggerRegionKeepsItOpen() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        intent.reset(isOpen: true)
        #expect(intent.mouseMoved(inTrigger: true, inOpenRegion: false, now: t0) == .none)
        #expect(intent.timerFired(now: t0 + 1) == .none)
    }

    @Test func unarmedOpenWaitsForTheFirstVisit() {
        // Hotkey / auto popup: the pointer is elsewhere, so hover-leave must not close it.
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        intent.reset(isOpen: true, pointerInside: false)
        #expect(!intent.isArmedForClose)
        #expect(intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0) == .none)
        #expect(intent.timerFired(now: t0 + 1) == .none)
        // Visiting the open region arms it; leaving then starts the grace.
        #expect(intent.mouseMoved(inTrigger: false, inOpenRegion: true, now: t0 + 2) == .none)
        #expect(intent.isArmedForClose)
        #expect(intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0 + 3) == .schedule(at: t0 + 3 + 0.35))
        #expect(intent.timerFired(now: t0 + 3.35) == .close)
    }

    @Test func closingResetsDwellState() {
        var intent = HoverIntent(openDelay: 0.15, closeDelay: 0.35)
        intent.reset(isOpen: true)
        _ = intent.mouseMoved(inTrigger: false, inOpenRegion: false, now: t0)
        intent.reset(isOpen: false)
        #expect(intent.leftAt == nil)
        #expect(intent.isArmedForClose)
        #expect(intent.timerFired(now: t0 + 1) == .none)
    }

    @Test func negativeDelaysClamp() {
        let intent = HoverIntent(openDelay: -1, closeDelay: -2)
        #expect(intent.openDelay == 0)
        #expect(intent.closeDelay == 0)
    }
}
