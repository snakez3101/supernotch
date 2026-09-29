import Foundation

// Owner: shelf-clipboard. Signature FROZEN (SPEC §D.3); baseline implementation.

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
        guard let interval = period.interval else { return nil }
        return items.filter { !$0.isPinned }.map { $0.addedDate.addingTimeInterval(interval) }.min()
    }
}
