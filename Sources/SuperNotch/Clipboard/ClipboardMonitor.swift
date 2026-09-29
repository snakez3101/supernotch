// Owner: shelf-clipboard (SPEC §F.1: the only always-on timer in the app).
//
// Polls `NSPasteboard.general.changeCount` (a cheap counter; no content is read here) and calls `onChange`
// when it moved. Cadence: 0.5 s (tolerance 0.2 s) while copies are happening, 1 s after a minute without any
// change. Paused while the Mac or its displays sleep and while the user session is switched out.
import AppKit

final class ClipboardMonitor {
    /// The pasteboard changed (not by us). The model reads and filters the new contents.
    var onChange: (() -> Void)?

    private static let activeInterval: TimeInterval = 0.5
    private static let idleInterval: TimeInterval = 1.0
    private static let idleAfter: TimeInterval = 60

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var lastChangeCount: Int
    private var lastChangeAt = Date()
    private var pauseReasons: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Whatever was on the clipboard before we started is not "copied while running".
        lastChangeCount = pasteboard.changeCount
        lastChangeAt = Date()
        observeSystem()
        reschedule()
        Log.clipboard.debug("Clipboard monitor started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        currentInterval = 0
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        pauseReasons.removeAll()
        Log.clipboard.debug("Clipboard monitor stopped")
    }

    /// We wrote to the pasteboard ourselves: do not report that change.
    func noteOwnWrite(changeCount: Int) {
        lastChangeCount = changeCount
    }

    /// Checks right away (e.g. when the history panel opens).
    func pollNow() {
        poll()
    }

    // MARK: Private

    private func poll() {
        guard isRunning, pauseReasons.isEmpty else { return }
        let count = pasteboard.changeCount
        if count != lastChangeCount {
            lastChangeCount = count
            lastChangeAt = Date()
            if currentInterval != Self.activeInterval { reschedule() }
            onChange?()
        } else if currentInterval == Self.activeInterval, Date().timeIntervalSince(lastChangeAt) > Self.idleAfter {
            reschedule()
        }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isRunning, pauseReasons.isEmpty else {
            currentInterval = 0
            return
        }
        let idle = Date().timeIntervalSince(lastChangeAt) > Self.idleAfter
        let interval = idle ? Self.idleInterval : Self.activeInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = idle ? 0.3 : 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        currentInterval = interval
    }

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(pause: Notification.Name, resume: Notification.Name, reason: String)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "screens"),
            (
                NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                "session"
            ),
        ]
        for pair in pairs {
            let reason = pair.reason
            observers.append(
                center.addObserver(forName: pair.pause, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pause(reason) }
                })
            observers.append(
                center.addObserver(forName: pair.resume, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resume(reason) }
                })
        }
    }

    private func pause(_ reason: String) {
        guard pauseReasons.insert(reason).inserted else { return }
        timer?.invalidate()
        timer = nil
        currentInterval = 0
        Log.clipboard.debug("Clipboard monitor paused (\(reason, privacy: .public))")
    }

    private func resume(_ reason: String) {
        guard pauseReasons.remove(reason) != nil, pauseReasons.isEmpty, isRunning else { return }
        reschedule()
        poll()
    }
}
