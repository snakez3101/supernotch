import Foundation

// CONTRACT FILE (SPEC §D.1). Owner: claude-core.
// Source: statusLine JSON `rate_limits.five_hour|seven_day.{used_percentage,resets_at}` (statusline.md).
// Only present for Pro/Max subscribers and only after the first API response of a session.

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

    /// Parses a statusLine stdin payload. Nil when `rate_limits` is absent or empty.
    public static func fromStatusLine(_ json: JSONValue, now: Date) -> UsageLimits? {
        guard let limits = json["rate_limits"] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let entry = limits[key], let used = entry["used_percentage"]?.doubleValue else { return nil }
            let resets = entry["resets_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(usedPercentage: used, resetsAt: resets)
        }
        let result = UsageLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"), updatedAt: now)
        return result.fiveHour == nil && result.sevenDay == nil ? nil : result
    }

    /// Drops windows whose reset time has passed (Claude Code does the same).
    public func pruned(now: Date) -> UsageLimits {
        func keep(_ window: UsageWindow?) -> UsageWindow? {
            guard let window else { return nil }
            if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
            return window
        }
        return UsageLimits(fiveHour: keep(fiveHour), sevenDay: keep(sevenDay), updatedAt: updatedAt)
    }

    /// True when any window is at or above `threshold` (0…1, default 0.8 ⇒ the closed-notch warning).
    public func isWarning(threshold: Double) -> Bool {
        [fiveHour, sevenDay].contains { ($0?.fraction ?? 0) >= threshold }
    }
}
