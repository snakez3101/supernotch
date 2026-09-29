// Owner: notch-shell (SPEC §A.10 General, §A.11 Done step).
//
// Launch at login via `SMAppService.mainApp` (no helper app). The system is the source of truth;
// `AppSettings.launchAtLogin` only mirrors the user's wish. Registration works best from /Applications.
import Foundation
import ServiceManagement
import os

enum NotchLoginItem {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user must allow it in System Settings › General › Login Items.
        case requiresApproval
        /// The system cannot find the app (e.g. running unbundled via `swift run`).
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .disabled
        }
    }

    /// Registers or unregisters the app. Returns a user-facing error message on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        // Never touch the real login items from the CI smoke test.
        guard ProcessInfo.processInfo.environment[SmokeTest.environmentFlag] != "1" else { return nil }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.system.info("Launch at login \(enabled ? "enabled" : "disabled", privacy: .public)")
            return nil
        } catch {
            let reason = error.localizedDescription
            Log.system.error("Launch at login change failed: \(reason, privacy: .public)")
            return enabled
                ? "Could not turn on launch at login. Move SuperNotch to /Applications and try again."
                : "Could not turn off launch at login: \(reason)"
        }
    }

    /// System Settings › General › Login Items.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
