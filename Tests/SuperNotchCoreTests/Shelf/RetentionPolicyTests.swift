// Owner: shelf-clipboard.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("RetentionPolicy")
struct RetentionPolicyTests {
    let now = Date(timeIntervalSince1970: 10 * 86_400)

    private func item(age: TimeInterval, pinned: Bool = false) -> ShelfItem {
        ShelfItem(kind: .text, displayName: "x", text: "x", addedAt: now - age, pinned: pinned)
    }

    @Test func pinnedNeverExpire() {
        let old = ShelfItem(kind: .text, displayName: "a", text: "a", addedAt: Date(timeIntervalSince1970: 0))
        var pinned = old
        pinned.pinned = true
        #expect(RetentionPolicy.isExpired(old, period: .oneDay, now: now))
        #expect(!RetentionPolicy.isExpired(pinned, period: .oneDay, now: now))
        #expect(!RetentionPolicy.isExpired(pinned, period: .thirtyDays, now: now + 400 * 86_400))
    }

    @Test func offKeepsEverything() {
        let ancient = item(age: 5 * 365 * 86_400)
        #expect(!RetentionPolicy.isExpired(ancient, period: .off, now: now))
        #expect(RetentionPolicy.partition([ancient], period: .off, now: now).expired.isEmpty)
        #expect(RetentionPolicy.nextExpiry([ancient], period: .off) == nil)
        #expect(RetentionPolicy.nextCleanupDelay([ancient], period: .off, now: now) == nil)
    }

    @Test(arguments: [RetentionPeriod.oneDay, .sevenDays, .thirtyDays])
    func boundaries(period: RetentionPeriod) throws {
        let interval = try #require(period.interval)
        #expect(!RetentionPolicy.isExpired(item(age: interval - 1), period: period, now: now))
        #expect(RetentionPolicy.isExpired(item(age: interval), period: period, now: now))
        #expect(RetentionPolicy.isExpired(item(age: interval + 1), period: period, now: now))
    }

    @Test func periodIntervals() {
        #expect(RetentionPeriod.off.interval == nil)
        #expect(RetentionPeriod.oneDay.interval == 86_400)
        #expect(RetentionPeriod.sevenDays.interval == 7.0 * 86_400)
        #expect(RetentionPeriod.thirtyDays.interval == 30.0 * 86_400)
    }

    @Test func partitionAndNextExpiry() {
        let fresh = ShelfItem(kind: .text, displayName: "b", addedAt: now - 3_600)
        let old = ShelfItem(kind: .text, displayName: "a", addedAt: now - 2 * 86_400)
        let (kept, expired) = RetentionPolicy.partition([fresh, old], period: .oneDay, now: now)
        #expect(kept == [fresh])
        #expect(expired == [old])
        #expect(RetentionPolicy.nextExpiry([fresh], period: .oneDay) == now - 3_600 + 86_400)
    }

    @Test func partitionPreservesOrder() {
        let items = [item(age: 10), item(age: 3 * 86_400), item(age: 20), item(age: 4 * 86_400, pinned: true)]
        let (kept, expired) = RetentionPolicy.partition(items, period: .oneDay, now: now)
        #expect(kept.map(\.id) == [items[0].id, items[2].id, items[3].id])
        #expect(expired.map(\.id) == [items[1].id])
    }

    @Test func nextExpiryIgnoresPinned() {
        let pinned = item(age: 20 * 86_400, pinned: true)
        #expect(RetentionPolicy.nextExpiry([pinned], period: .sevenDays) == nil)
        let loose = item(age: 86_400)
        #expect(RetentionPolicy.nextExpiry([pinned, loose], period: .sevenDays) == now + 6 * 86_400)
    }

    @Test func cleanupDelayIsClamped() {
        // Already expired ⇒ minimum delay, far future ⇒ capped.
        #expect(RetentionPolicy.nextCleanupDelay([item(age: 2 * 86_400)], period: .oneDay, now: now) == 1)
        #expect(
            RetentionPolicy.nextCleanupDelay([item(age: 60)], period: .thirtyDays, now: now) == 6.0 * 3_600)
        #expect(
            RetentionPolicy.nextCleanupDelay(
                [item(age: 86_400 - 120)], period: .oneDay, now: now) == 120)
        #expect(RetentionPolicy.nextCleanupDelay([ShelfItem](), period: .oneDay, now: now) == nil)
    }

    @Test func clipboardEntriesUseCapturedAt() {
        let entry = ClipboardEntry(content: .text("a"), capturedAt: now - 2 * 86_400)
        var pinned = entry
        pinned.pinned = true
        #expect(RetentionPolicy.isExpired(entry, period: .oneDay, now: now))
        #expect(!RetentionPolicy.isExpired(pinned, period: .oneDay, now: now))
    }
}
