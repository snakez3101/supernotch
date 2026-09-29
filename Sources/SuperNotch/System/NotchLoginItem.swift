// Owner: notch-shell (SPEC §A.10 General, §A.11 Done step).
//
// Launch at login.
// 1. `SMAppService.mainApp.register()` (no helper app). `.enabled` is done; `.requiresApproval` shows a hint and
//    a button to System Settings › General › Login Items.
// 2. `.notRegistered` / `.notFound` or a thrown error (common for ad-hoc-signed builds): fallback to a per-user
//    LaunchAgent `~/Library/LaunchAgents/io.github.snakez3101.supernotch.plist` that starts this executable at the
//    next login (written atomically, never bootstrapped now: that would start a second instance).
// Turning it off unregisters the login item, deletes the plist and runs `launchctl bootout` (best effort).
// The toggle shows the real state (`NotchLoginState.resolve`, Core): the login item's status, or the LaunchAgent
// file starting this very executable. `AppSettings.launchAtLogin` only mirrors it. Every step is logged, and
// every failure is returned as a message for the UI. Nothing is changed while `SUPERNOTCH_SMOKE_TEST=1`.
import Foundation
import ServiceManagement
import SuperNotchCore
import os

enum NotchLoginItem {
    /// State plus the small secondary text shown under the toggle (an error, or how launch at login works).
    struct Outcome: Equatable {
        var state: NotchLoginState
        var message: String?
    }

    nonisolated private enum Failure: LocalizedError, Sendable {
        case notInAppBundle
        case noExecutable

        var errorDescription: String? {
            switch self {
            case .notInAppBundle: return "SuperNotch is not running from SuperNotch.app"
            case .noExecutable: return "the app's executable was not found"
            }
        }
    }

    static let agentLabel = NotchLoginAgent.defaultLabel

    static var agentPlistPath: String {
        NotchLoginAgent.plistPath(homeDirectory: NSHomeDirectory(), label: agentLabel)
    }

    private static var isSmokeTest: Bool {
        ProcessInfo.processInfo.environment[SmokeTest.environmentFlag] == "1"
    }

    /// True when this process was started by our LaunchAgent at login.
    static var wasLaunchedByLaunchAgent: Bool {
        CommandLine.arguments.contains(NotchLoginAgent.launchedAtLoginArgument)
    }

    // MARK: - State

    static var serviceStatus: NotchLoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notRegistered
        }
    }

    static var agentFileState: NotchLoginAgentFileState {
        let data = FileManager.default.contents(atPath: agentPlistPath)
        guard let executablePath = Bundle.main.executablePath else {
            return data == nil ? .missing : .stale(program: nil)
        }
        return NotchLoginAgent.fileState(plistData: data, executablePath: executablePath)
    }

    /// The real state right now, with a note worth showing (e.g. a LaunchAgent for another copy).
    static func currentOutcome() -> Outcome {
        let service = serviceStatus
        let agent = agentFileState
        let state = NotchLoginState.resolve(service: service, agentFile: agent)
        return Outcome(state: state, message: note(for: state, agent: agent))
    }

    private static func note(for state: NotchLoginState, agent: NotchLoginAgentFileState) -> String? {
        switch state {
        case .enabled(.launchAgent):
            return "Starts at login through a LaunchAgent in ~/Library/LaunchAgents."
        case .enabled(.loginItem), .requiresApproval:
            return nil
        case .disabled:
            if case .stale(let program) = agent {
                let target = program.map { " (\($0))" } ?? ""
                return "A login entry for another copy of SuperNotch exists\(target). "
                    + "Turn this on to start this copy instead."
            }
            return nil
        }
    }

    // MARK: - Changes

    /// Turns launch at login on or off and returns the real state afterwards (with an error message on failure).
    static func setEnabled(_ enabled: Bool) -> Outcome {
        guard !isSmokeTest else {
            Log.system.info("Launch at login: smoke test, nothing changed")
            return currentOutcome()
        }
        return enabled ? enable() : disable()
    }

    private static func enable() -> Outcome {
        Log.system.info("Launch at login: registering the login item (SMAppService.mainApp)")
        var registerError: String?
        do {
            try SMAppService.mainApp.register()
        } catch {
            registerError = error.localizedDescription
            let detail = describe(error)
            Log.system.error("Launch at login: register() failed: \(detail, privacy: .public)")
        }
        let status = serviceStatus
        let statusName = status.rawValue
        Log.system.info("Launch at login: login item status after register(): \(statusName, privacy: .public)")

        switch NotchLoginRegisterStep.after(status: status) {
        case .done:
            // Never let the login item and the LaunchAgent both start SuperNotch.
            removeAgentFileIfPresent(bootOut: false)
            return currentOutcome()
        case .needsApproval:
            Log.system.info("Launch at login: waiting for approval in System Settings › Login Items")
            return currentOutcome()
        case .useLaunchAgent:
            let reason = registerError ?? "status \(status.rawValue)"
            Log.system.info("Launch at login: falling back to a LaunchAgent (\(reason, privacy: .public))")
            do {
                try writeAgentFile()
            } catch {
                let detail = describe(error)
                Log.system.error("Launch at login: writing the LaunchAgent failed: \(detail, privacy: .public)")
                var outcome = currentOutcome()
                outcome.message = "Could not turn on launch at login: \(error.localizedDescription)"
                return outcome
            }
            var outcome = currentOutcome()
            if outcome.state == .enabled(.launchAgent) {
                outcome.message =
                    "The system login item is not available (\(reason)), so SuperNotch uses a LaunchAgent in "
                    + "~/Library/LaunchAgents. It starts at your next login."
            } else {
                Log.system.error("Launch at login: the LaunchAgent was written but does not read back as current")
                outcome.message = "Could not turn on launch at login: the LaunchAgent could not be verified."
            }
            return outcome
        }
    }

    private static func disable() -> Outcome {
        var problems: [String] = []
        let status = serviceStatus
        if status == .enabled || status == .requiresApproval {
            let statusName = status.rawValue
            Log.system.info("Launch at login: unregistering the login item (status \(statusName, privacy: .public))")
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                let detail = describe(error)
                Log.system.error("Launch at login: unregister() failed: \(detail, privacy: .public)")
                problems.append(error.localizedDescription)
            }
        } else {
            let statusName = status.rawValue
            Log.system.info("Launch at login: login item not registered (\(statusName, privacy: .public))")
        }
        if let problem = removeAgentFileIfPresent(bootOut: true) {
            problems.append(problem)
        }
        var outcome = currentOutcome()
        if !problems.isEmpty {
            outcome.message = "Could not turn off launch at login: \(problems.joined(separator: "; "))"
        } else {
            Log.system.info("Launch at login: off")
        }
        return outcome
    }

    /// At launch: if the login item is enabled, a LaunchAgent left from the fallback would start a second copy.
    static func reconcileAtLaunch() {
        guard !isSmokeTest, FileManager.default.fileExists(atPath: agentPlistPath) else { return }
        guard serviceStatus == .enabled else { return }
        Log.system.info("Launch at login: the login item is enabled; removing the redundant LaunchAgent")
        removeAgentFileIfPresent(bootOut: false)
    }

    /// System Settings › General › Login Items.
    static func openSystemSettings() {
        Log.system.info("Launch at login: opening System Settings › Login Items")
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - LaunchAgent file

    private static func writeAgentFile() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw Failure.notInAppBundle }
        guard let executablePath = Bundle.main.executablePath else { throw Failure.noExecutable }
        let data = try NotchLoginAgent.plistData(
            label: agentLabel, executablePath: executablePath, bundleIdentifier: Bundle.main.bundleIdentifier)
        let url = URL(fileURLWithPath: agentPlistPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try data.write(to: url, options: .atomic)
        do {
            // launchd ignores agents that are group- or world-writable.
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: url.path)
        } catch {
            let detail = describe(error)
            Log.system.error("Launch at login: chmod 644 failed: \(detail, privacy: .public)")
        }
        Log.system.info("Launch at login: LaunchAgent written for \(executablePath, privacy: .private)")
    }

    /// Deletes the plist (if any) and optionally unloads the job. Returns a user-facing problem, or nil.
    @discardableResult
    private static func removeAgentFileIfPresent(bootOut: Bool) -> String? {
        let path = agentPlistPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            try FileManager.default.removeItem(atPath: path)
            Log.system.info("Launch at login: LaunchAgent removed")
        } catch {
            let detail = describe(error)
            Log.system.error("Launch at login: removing the LaunchAgent failed: \(detail, privacy: .public)")
            return "the LaunchAgent could not be removed (\(error.localizedDescription))"
        }
        if bootOut { bootOutAgent() }
        return nil
    }

    /// `launchctl bootout gui/<uid>/<label>`, best effort and asynchronous. Skipped when this process was started
    /// by that job: booting it out would quit SuperNotch. Without the plist the job is gone at the next login anyway.
    private static func bootOutAgent() {
        guard !wasLaunchedByLaunchAgent else {
            Log.system.info("Launch at login: started by the LaunchAgent, so it is not booted out now")
            return
        }
        let target = NotchLoginAgent.bootoutTarget(uid: UInt32(getuid()), label: agentLabel)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", target]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            // 0: unloaded; 3 / 113: it was not loaded (normal: the plist is only loaded at login).
            let code = finished.terminationStatus
            Log.system.info(
                "Launch at login: launchctl bootout \(target, privacy: .public) exited \(code, privacy: .public)")
        }
        do {
            try process.run()
        } catch {
            let detail = describe(error)
            Log.system.error("Launch at login: launchctl could not run: \(detail, privacy: .public)")
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }
}
