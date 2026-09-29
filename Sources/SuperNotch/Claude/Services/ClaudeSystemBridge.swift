// Owner: claude-app. The few AppKit facts the Claude model needs, kept in one file so the model itself
// stays Foundation-only: frontmost app, running apps, sleep / wake / screen lock, app-quit notifications.

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

/// Observes sleep/wake, screen lock and app terminations for the Claude model.
/// `onPauseChange(true)` while the Mac sleeps or the screen is locked, `false` when both are over.
final class ClaudeWorkspaceObserver {
    private let onPauseChange: (Bool) -> Void
    private let onApplicationTerminated: (String) -> Void
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var isAsleep = false
    private var isLocked = false

    init(onPauseChange: @escaping (Bool) -> Void, onApplicationTerminated: @escaping (String) -> Void) {
        self.onPauseChange = onPauseChange
        self.onApplicationTerminated = onApplicationTerminated

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(true) }
            })
        workspaceTokens.append(
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(false) }
            })
        workspaceTokens.append(
            workspace.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleID = app?.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.onApplicationTerminated(bundleID) }
            })

        let distributed = DistributedNotificationCenter.default()
        distributedTokens.append(
            distributed.addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setLocked(true) }
            })
        distributedTokens.append(
            distributed.addObserver(
                forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setLocked(false) }
            })
    }

    func invalidate() {
        let workspace = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { workspace.removeObserver(token) }
        workspaceTokens = []
        let distributed = DistributedNotificationCenter.default()
        for token in distributedTokens { distributed.removeObserver(token) }
        distributedTokens = []
    }

    private func setAsleep(_ value: Bool) {
        let before = isAsleep || isLocked
        isAsleep = value
        report(before: before)
    }

    private func setLocked(_ value: Bool) {
        let before = isAsleep || isLocked
        isLocked = value
        report(before: before)
    }

    private func report(before: Bool) {
        let now = isAsleep || isLocked
        if now != before { onPauseChange(now) }
    }
}
