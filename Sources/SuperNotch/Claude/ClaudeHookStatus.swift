// Owner: claude-app. Hook installation status shown in Settings › Claude and onboarding (SPEC §D.4).

import Foundation

nonisolated enum ClaudeHookStatus: Sendable, Hashable {
    /// Not checked yet.
    case unknown
    case notInstalled
    case installed
    /// Some of our entries are missing or point elsewhere (reason for the user).
    case needsRepair(String)
    /// Reading or writing settings.json failed (reason for the user). Nothing was changed.
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    /// Our entries are present in some form (installed or repairable).
    var hasOurEntries: Bool {
        switch self {
        case .installed, .needsRepair: return true
        case .unknown, .notInstalled, .failed: return false
        }
    }

    var title: String {
        switch self {
        case .unknown: return "Checking…"
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .needsRepair: return "Needs repair"
        case .failed: return "Error"
        }
    }

    var detail: String? {
        switch self {
        case .needsRepair(let reason), .failed(let reason): return reason
        case .unknown, .notInstalled, .installed: return nil
        }
    }
}
