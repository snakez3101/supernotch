import Foundation

// CONTRACT FILE (SPEC §D.1, §D.9). Owner: claude-core.
// Source: statusLine JSON `rate_limits.five_hour|seven_day.{used_percentage,resets_at}` (statusline.md):
//   "rate_limits": { "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
//                    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 } }
// Only present for Pro/Max subscribers and only after the first API response of a session. Each window may be
// absent on its own; Claude Code drops a window once its `resets_at` has passed.
//
// Several sessions report at different times, and an idle session's status line still carries the numbers
// of its last API response. `merged(with:)` therefore never lets an older report lower a newer one.

public struct UsageWindow: Sendable, Hashable, Codable {
    /// 0…100 (may exceed 100 for spend limits).
    public var usedPercentage: Double
    public var resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    /// 0…1 for progress bars.
    public var fraction: Double { min(max(usedPercentage / 100, 0), 1) }

    /// Reset times within this tolerance belong to the same window (rounding differences between reports).
    public static let sameWindowTolerance: TimeInterval = 120

    /// Combines two reports of the same limit. A later `resetsAt` means a new window (take it); an earlier one
    /// is a stale report (ignore it); within one window usage only grows (take the maximum).
    public func merged(with incoming: UsageWindow) -> UsageWindow {
        guard let mine = resetsAt, let theirs = incoming.resetsAt else { return incoming }
        if theirs.timeIntervalSince(mine) > Self.sameWindowTolerance { return incoming }
        if mine.timeIntervalSince(theirs) > Self.sameWindowTolerance { return self }
        return UsageWindow(usedPercentage: max(usedPercentage, incoming.usedPercentage), resetsAt: max(mine, theirs))
    }
}

public struct UsageLimits: Sendable, Hashable, Codable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    /// When the statusLine payload was received.
    public var updatedAt: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, updatedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAt = updatedAt
    }

    /// Parses a statusLine stdin payload. Nil when `rate_limits` is absent or has no usable window.
    /// Tolerates numbers sent as strings, millisecond timestamps and ISO 8601 reset times.
    public static func fromStatusLine(_ json: JSONValue, now: Date) -> UsageLimits? {
        guard let limits = json["rate_limits"], case .object = limits else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let entry = limits[key], let used = number(entry["used_percentage"]), used.isFinite else {
                return nil
            }
            return UsageWindow(usedPercentage: max(used, 0), resetsAt: date(entry["resets_at"]))
        }
        let result = UsageLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"), updatedAt: now)
        return result.isEmpty ? nil : result
    }

    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

    /// Drops windows whose reset time has passed (Claude Code does the same).
    public func pruned(now: Date) -> UsageLimits {
        func keep(_ window: UsageWindow?) -> UsageWindow? {
            guard let window else { return nil }
            if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
            return window
        }
        return UsageLimits(fiveHour: keep(fiveHour), sevenDay: keep(sevenDay), updatedAt: updatedAt)
    }

    /// Folds a newer report into this one window by window (see `UsageWindow.merged(with:)`). A window the
    /// newer report lacks is kept (another session may not have it yet); `pruned(now:)` expires it.
    public func merged(with incoming: UsageLimits) -> UsageLimits {
        func merge(_ mine: UsageWindow?, _ theirs: UsageWindow?) -> UsageWindow? {
            switch (mine, theirs) {
            case (let mine?, let theirs?): return mine.merged(with: theirs)
            case (nil, let theirs?): return theirs
            case (let mine?, nil): return mine
            case (nil, nil): return nil
            }
        }
        return UsageLimits(
            fiveHour: merge(fiveHour, incoming.fiveHour), sevenDay: merge(sevenDay, incoming.sevenDay),
            updatedAt: max(updatedAt, incoming.updatedAt))
    }

    /// Highest fraction across the windows (0 when none), e.g. for the closed-notch warning dot.
    public var maxFraction: Double { max(fiveHour?.fraction ?? 0, sevenDay?.fraction ?? 0) }

    /// True when any window is at or above `threshold` (0…1, default 0.8 ⇒ the closed-notch warning).
    public func isWarning(threshold: Double) -> Bool {
        [fiveHour, sevenDay].contains { ($0?.fraction ?? 0) >= threshold }
    }

    // MARK: - Tolerant scalars

    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number)?: return number
        case .string(let text)?: return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Unix seconds (documented), Unix milliseconds, or an ISO 8601 string.
    static func date(_ value: JSONValue?) -> Date? {
        if let seconds = number(value), seconds.isFinite, seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let text = value?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
