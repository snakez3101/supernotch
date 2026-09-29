import Foundation

// Owner: notch-shell. Signatures FROZEN (SPEC §D.2). Pure hover dwell/grace state machine; the app feeds it
// mouse samples (from NSEvent monitors) and timer fires, and performs the returned action.
//
// Rules (SPEC §A.4):
// * Closed: the pointer must dwell `openDelay` inside the trigger region (the physical notch + slack) → `.open`.
//   Leaving the trigger before the dwell elapses cancels it.
// * Open: once the pointer has been inside the open region (shape rect + leave margin), leaving it for
//   `closeDelay` → `.close`. Coming back inside during the grace cancels the close.
// * An open that did not start under the pointer (hotkey, auto popup, click elsewhere) is "unarmed": it never
//   closes by hover until the pointer has entered the open region once. `reset(isOpen:pointerInside:)`.
// * A close that happens while the pointer is still over the notch (Esc, hotkey, click on a control) does not
//   re-open by dwell until the pointer has left the trigger once.

public struct HoverIntent: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case none
        /// Schedule a check at this time (dwell or grace timer). The caller calls `timerFired(now:)` then.
        case schedule(at: Date)
        case open
        case close
    }

    public var openDelay: TimeInterval
    public var closeDelay: TimeInterval
    /// Updated by the owner whenever the notch opens/closes for any reason.
    public var isOpen: Bool = false

    private(set) public var enteredAt: Date?
    private(set) public var leftAt: Date?
    /// While open: true once the pointer has been inside the open region (hover-leave may close).
    private(set) public var isArmedForClose: Bool = true
    /// While closed: false after a close under the pointer, until the pointer leaves the trigger.
    private(set) public var isArmedForOpen: Bool = true

    public init(openDelay: TimeInterval, closeDelay: TimeInterval) {
        self.openDelay = max(openDelay, 0)
        self.closeDelay = max(closeDelay, 0)
    }

    /// - Parameters:
    ///   - inTrigger: pointer is inside the trigger region (closed: physical notch hover rect).
    ///   - inOpenRegion: pointer is inside the open shape (+ leave margin). Ignored while closed.
    public mutating func mouseMoved(inTrigger: Bool, inOpenRegion: Bool, now: Date) -> Action {
        if isOpen {
            enteredAt = nil
            if inOpenRegion || inTrigger {
                isArmedForClose = true
                leftAt = nil
                return .none
            }
            guard isArmedForClose else { return .none }
            if leftAt == nil {
                leftAt = now
                return closeDelay <= 0 ? close() : .schedule(at: now.addingTimeInterval(closeDelay))
            }
            return .none
        }
        leftAt = nil
        if inTrigger {
            guard isArmedForOpen else { return .none }
            if enteredAt == nil {
                enteredAt = now
                return openDelay <= 0 ? open() : .schedule(at: now.addingTimeInterval(openDelay))
            }
            return .none
        }
        isArmedForOpen = true
        enteredAt = nil
        return .none
    }

    /// Call when a scheduled time is reached.
    public mutating func timerFired(now: Date) -> Action {
        if isOpen {
            guard let leftAt, isArmedForClose else { return .none }
            if now.timeIntervalSince(leftAt) >= closeDelay - 0.001 {
                return close()
            }
            return .schedule(at: leftAt.addingTimeInterval(closeDelay))
        }
        guard let enteredAt else { return .none }
        if now.timeIntervalSince(enteredAt) >= openDelay - 0.001 {
            return open()
        }
        return .schedule(at: enteredAt.addingTimeInterval(openDelay))
    }

    /// Reset after an externally caused open/close. An open reset this way is armed (hover-leave closes it).
    public mutating func reset(isOpen: Bool) {
        reset(isOpen: isOpen, pointerInside: true)
    }

    /// Reset after an externally caused open/close.
    /// - Parameter pointerInside: whether the pointer is over the notch right now.
    ///   * open: false for opens that did not happen under the pointer (hotkey, auto popup); they only close by
    ///     hover after the pointer has visited the open region once;
    ///   * closed: true when the pointer is still over the trigger; dwelling there does not re-open until the
    ///     pointer has left once.
    public mutating func reset(isOpen: Bool, pointerInside: Bool) {
        self.isOpen = isOpen
        isArmedForClose = isOpen ? pointerInside : true
        isArmedForOpen = isOpen ? true : !pointerInside
        enteredAt = nil
        leftAt = nil
    }

    /// The next time a timer is needed (dwell or grace), if any.
    public var pendingDeadline: Date? {
        if isOpen {
            guard isArmedForClose, let leftAt else { return nil }
            return leftAt.addingTimeInterval(closeDelay)
        }
        guard isArmedForOpen else { return nil }
        return enteredAt.map { $0.addingTimeInterval(openDelay) }
    }

    private mutating func open() -> Action {
        enteredAt = nil
        leftAt = nil
        return .open
    }

    private mutating func close() -> Action {
        enteredAt = nil
        leftAt = nil
        return .close
    }
}
