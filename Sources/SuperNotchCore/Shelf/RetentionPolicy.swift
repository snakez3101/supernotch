import Foundation

// Owner: shelf-clipboard. Signature FROZEN (SPEC §D.3).
// Auto-cleanup rules shared by the shelf and the clipboard history (REQUIREMENTS "same cleanup setting"):
// pinned items never expire, `.off` keeps everything, otherwise an item expires once it is at least
// `period.interval` old (the boundary itself counts as expired).

public enum RetentionPolicy {
    /// Whether `subject` has expired. Pinned items never expire; `.off` keeps everything.
    public static func isExpired<T: RetentionSubject>(_ subject: T, period: RetentionPeriod, now: Date) -> Bool {
        guard !subject.isPinned, let interval = period.interval, interval > 0 else { return false }
        return now.timeIntervalSince(subject.addedDate) >= interval
    }

    /// Splits into (kept, expired), preserving order.
    public static func partition<T: RetentionSubject>(_ items: [T], period: RetentionPeriod, now: Date)
        -> (kept: [T], expired: [T])
    {
        var kept: [T] = []
        var expired: [T] = []
        for item in items {
            if isExpired(item, period: period, now: now) { expired.append(item) } else { kept.append(item) }
        }
        return (kept, expired)
    }

    /// Next time something will expire (to schedule a single cleanup timer), nil if nothing will.
    public static func nextExpiry<T: RetentionSubject>(_ items: [T], period: RetentionPeriod) -> Date? {
        guard let interval = period.interval, interval > 0 else { return nil }
        return items.filter { !$0.isPinned }.map { $0.addedDate.addingTimeInterval(interval) }.min()
    }

    /// Seconds from `now` until the next cleanup should run, nil when nothing will ever expire.
    ///
    /// Already-expired items give `minimumDelay` (so a caller never spins), and the result is capped at
    /// `maximumDelay` so a long sleep or a clock change is corrected by the next wake-up at the latest.
    public static func nextCleanupDelay<T: RetentionSubject>(
        _ items: [T], period: RetentionPeriod, now: Date, minimumDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 6 * 3_600
    ) -> TimeInterval? {
        guard let next = nextExpiry(items, period: period) else { return nil }
        let delay = next.timeIntervalSince(now)
        return min(max(delay, minimumDelay), max(maximumDelay, minimumDelay))
    }
}
