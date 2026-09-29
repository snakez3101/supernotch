import Dispatch
import Foundation

// Owner: media. Runs blocking Automation (TCC) calls off the caller's thread and races each one against a
// timeout. `AEDeterminePermissionToAutomateTarget` is known to hang without ever showing the system prompt
// (Apple DTS, developer.apple.com/forums/thread/666528), and a real Apple Event blocks while the prompt is up.
// Neither may freeze the UI, leave a button dead or block the AppleScript queue.

/// Result of one blocking permission call.
public enum MediaPermissionCallResult: Sendable, Equatable {
    /// The raw `OSStatus` / Apple Event error number the call returned.
    case status(Int32)
    /// No answer before the timeout. The call may still finish later.
    case timedOut
}

/// Thread-safe "first one wins" flag: the call and its timeout both try to claim it, only one succeeds.
public final class MediaFirstClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    public init() {}

    /// True for the first caller only.
    public func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// One private serial queue for one kind of blocking call.
///
/// * At most ONE call is in flight. A caller that arrives meanwhile joins it instead of queueing another call
///   behind it, so a hung call can never pile up work (or a second system prompt).
/// * Every caller gets the call's status or `.timedOut`, whichever comes first. A status that arrives after the
///   caller's timeout goes to its `late` handler (e.g. the user answered the dialog after we stopped waiting).
public final class MediaBlockingCallRunner: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Completions waiting for the call in flight; nil while idle. Guarded by `lock`.
    private var waiters: [@Sendable (Int32) -> Void]?

    public init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    /// True while a call is in flight (possibly hung).
    public var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiters != nil
    }

    /// Runs `work` (or joins the call in flight) and returns its status, or `.timedOut` after `timeout` seconds.
    public func run(
        timeout: TimeInterval, work: @escaping @Sendable () -> Int32, late: (@Sendable (Int32) -> Void)? = nil
    ) async -> MediaPermissionCallResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<MediaPermissionCallResult, Never>) in
            let claim = MediaFirstClaim()
            start(work) { status in
                if claim.claim() {
                    continuation.resume(returning: .status(status))
                } else {
                    late?(status)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
                if claim.claim() { continuation.resume(returning: .timedOut) }
            }
        }
    }

    /// Starts `work` unless a call is already in flight; `completion` receives the status of the call it joined.
    public func start(_ work: @escaping @Sendable () -> Int32, completion: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        if waiters != nil {
            waiters?.append(completion)
            lock.unlock()
            return
        }
        waiters = [completion]
        lock.unlock()
        queue.async { [self] in
            let status = work()
            lock.lock()
            let completions = waiters ?? []
            waiters = nil
            lock.unlock()
            for completion in completions { completion(status) }
        }
    }
}
