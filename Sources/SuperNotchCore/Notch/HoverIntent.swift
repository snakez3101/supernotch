import Foundation

// Owner: notch-shell. Signatures FROZEN (SPEC §D.2). Pure hover dwell/grace state machine; the app feeds it
// mouse samples (from NSEvent monitors) and timer fires, and performs the returned action.

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

    public init(openDelay: TimeInterval, closeDelay: TimeInterval) {
        self.openDelay = openDelay
        self.closeDelay = closeDelay
    }

    /// - Parameters:
    ///   - inTrigger: pointer is inside the trigger region (closed: physical notch hover rect).
    ///   - inOpenRegion: pointer is inside the open shape (+ leave margin). Ignored while closed.
    public mutating func mouseMoved(inTrigger: Bool, inOpenRegion: Bool, now: Date) -> Action {
        if isOpen {
            if inOpenRegion || inTrigger {
                leftAt = nil
                return .none
            }
            if leftAt == nil {
                leftAt = now
                return closeDelay <= 0 ? .close : .schedule(at: now.addingTimeInterval(closeDelay))
            }
            return .none
        }
        if inTrigger {
            if enteredAt == nil {
                enteredAt = now
                return openDelay <= 0 ? .open : .schedule(at: now.addingTimeInterval(openDelay))
            }
            return .none
        }
        enteredAt = nil
        return .none
    }

    /// Call when a scheduled time is reached.
    public mutating func timerFired(now: Date) -> Action {
        if isOpen {
            guard let leftAt else { return .none }
            if now.timeIntervalSince(leftAt) >= closeDelay - 0.001 {
                self.leftAt = nil
                return .close
            }
            return .schedule(at: leftAt.addingTimeInterval(closeDelay))
        }
        guard let enteredAt else { return .none }
        if now.timeIntervalSince(enteredAt) >= openDelay - 0.001 {
            self.enteredAt = nil
            return .open
        }
        return .schedule(at: enteredAt.addingTimeInterval(openDelay))
    }

    /// Reset after an externally caused open/close.
    public mutating func reset(isOpen: Bool) {
        self.isOpen = isOpen
        enteredAt = nil
        leftAt = nil
    }
}
