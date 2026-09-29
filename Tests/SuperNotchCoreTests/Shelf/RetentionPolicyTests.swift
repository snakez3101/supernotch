// Owner: shelf-clipboard. Seed tests by the foundation.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("RetentionPolicy")
struct RetentionPolicyTests {
    let now = Date(timeIntervalSince1970: 10 * 86_400)

    @Test func pinnedNeverExpire() {
        let old = ShelfItem(kind: .text, displayName: "a", text: "a", addedAt: Date(timeIntervalSince1970: 0))
        var pinned = old
        pinned.pinned = true
        #expect(RetentionPolicy.isExpired(old, period: .oneDay, now: now))
        #expect(!RetentionPolicy.isExpired(pinned, period: .oneDay, now: now))
        #expect(!RetentionPolicy.isExpired(old, period: .off, now: now))
    }

    @Test func partitionAndNextExpiry() {
        let fresh = ShelfItem(kind: .text, displayName: "b", addedAt: now - 3_600)
        let old = ShelfItem(kind: .text, displayName: "a", addedAt: now - 2 * 86_400)
        let (kept, expired) = RetentionPolicy.partition([fresh, old], period: .oneDay, now: now)
        #expect(kept == [fresh])
        #expect(expired == [old])
        #expect(RetentionPolicy.nextExpiry([fresh], period: .oneDay) == now - 3_600 + 86_400)
    }
}
