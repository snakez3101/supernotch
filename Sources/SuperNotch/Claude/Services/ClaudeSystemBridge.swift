// Owner: claude-app. The few AppKit facts the Claude model needs, kept in one file so the model itself
// stays Foundation-only: frontmost app, running apps, wake / app-quit notifications.

import AppKit
import Foundation

enum ClaudeSystemBridge {
    static func frontmostApplicationBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func isApplicationRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Observes system wake and app terminations (NSWorkspace notification center) for the Claude model.
final class ClaudeWorkspaceObserver {
    private let onWake: () -> Void
    private let onApplicationTerminated: (String) -> Void
    private var tokens: [NSObjectProtocol] = []

    init(onWake: @escaping () -> Void, onApplicationTerminated: @escaping (String) -> Void) {
        self.onWake = onWake
        self.onApplicationTerminated = onApplicationTerminated
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onWake()
                }
            })
        tokens.append(
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
                [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleID = app?.bundleIdentifier else { return }
                MainActor.assumeIsolated {
                    self?.onApplicationTerminated(bundleID)
                }
            })
    }

    func invalidate() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }
}
