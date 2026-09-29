// Owner: notch-shell (SPEC §A.4, §D.4, §F.4 #5).
//
// Returned by `NotchViewModel.holdOpen(reason:)`. While any token is held the notch never closes by itself
// (hover-leave, click outside); explicit closes (hotkey, Esc, `close()`) still work. Call `release()` when done;
// a token that is simply dropped releases itself on deinit. Safe to release from any thread.
import Foundation

nonisolated final class NotchHoldToken: @unchecked Sendable {
    /// Why the notch is held (logging only).
    let reason: String

    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?

    init(reason: String, onRelease: @escaping @Sendable () -> Void) {
        self.reason = reason
        self.onRelease = onRelease
    }

    /// True until `release()` ran (or the token was deallocated).
    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onRelease != nil
    }

    /// Releases the hold. Idempotent.
    func release() {
        lock.lock()
        let action = onRelease
        onRelease = nil
        lock.unlock()
        action?()
    }

    deinit {
        release()
    }
}
