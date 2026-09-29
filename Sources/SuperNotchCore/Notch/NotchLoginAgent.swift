import Foundation

// Owner: notch-shell (SPEC §A.10 General, §A.11 Done step). Pure parts of "Launch at login", tested on Linux.
//
// The app first tries `SMAppService.mainApp`. Ad-hoc-signed builds often cannot register it (the call throws, or
// the status stays `.notRegistered` / `.notFound`), so the fallback is a per-user LaunchAgent
// `~/Library/LaunchAgents/<label>.plist` that starts this executable at the next login. It is never bootstrapped
// right away (that would start a second instance now). This file builds and reads that plist, turns the system
// status plus the file into the one state the UI shows, and decides which of two running copies keeps running.

/// Mirror of `SMAppService.Status` (ServiceManagement only exists on macOS).
public enum NotchLoginServiceStatus: String, Sendable, Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

/// How SuperNotch gets started at login.
public enum NotchLoginMechanism: Sendable, Equatable {
    /// `SMAppService.mainApp` (System Settings › General › Login Items).
    case loginItem
    /// The per-user LaunchAgent plist written by the fallback.
    case launchAgent
}

/// What the per-user LaunchAgent file means for the running copy of the app.
public enum NotchLoginAgentFileState: Sendable, Equatable {
    case missing
    /// The file starts exactly this executable.
    case current
    /// The file exists but starts another path (a moved or old copy), or cannot be read.
    case stale(program: String?)
}

/// The launch-at-login state the toggle shows.
public enum NotchLoginState: Sendable, Equatable {
    case enabled(NotchLoginMechanism)
    /// Registered as a login item, but the user still has to allow it in System Settings › Login Items.
    case requiresApproval
    case disabled

    /// Whether the toggle is on. A registration that waits for approval counts as on (with a hint).
    public var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .disabled: return false
        }
    }

    /// The system login item wins; a LaunchAgent that starts this copy counts as enabled too.
    public static func resolve(service: NotchLoginServiceStatus, agentFile: NotchLoginAgentFileState) -> Self {
        if service == .enabled { return .enabled(.loginItem) }
        if agentFile == .current { return .enabled(.launchAgent) }
        if service == .requiresApproval { return .requiresApproval }
        return .disabled
    }
}

/// What to do after `SMAppService.mainApp.register()` returned or threw, judged by the status read afterwards
/// (`register()` may throw and still leave the item enabled or waiting for approval).
public enum NotchLoginRegisterStep: Sendable, Equatable {
    case done
    case needsApproval
    case useLaunchAgent

    public static func after(status: NotchLoginServiceStatus) -> Self {
        switch status {
        case .enabled: return .done
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .useLaunchAgent
        }
    }
}

/// The per-user LaunchAgent used when `SMAppService` is not available.
public enum NotchLoginAgent {
    public static let defaultLabel = "io.github.snakez3101.supernotch"
    /// Passed by the LaunchAgent, so a copy started at login quits silently if SuperNotch already runs.
    public static let launchedAtLoginArgument = "--launched-at-login"

    /// `<home>/Library/LaunchAgents/<label>.plist`.
    public static func plistPath(homeDirectory: String, label: String = defaultLabel) -> String {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist", isDirectory: false)
            .path
    }

    /// The app's own executable (not `/usr/bin/open`: `open` on a running app would send a reopen event, which
    /// opens Settings), plus the login marker.
    public static func programArguments(executablePath: String) -> [String] {
        [normalizedPath(executablePath), launchedAtLoginArgument]
    }

    /// The plist dictionary. `bundleIdentifier` attributes the item to the app in System Settings › Login Items.
    public static func propertyList(
        label: String = defaultLabel, executablePath: String, bundleIdentifier: String?
    ) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments(executablePath: executablePath),
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            plist["AssociatedBundleIdentifiers"] = [bundleIdentifier]
        }
        return plist
    }

    /// XML plist data, ready to be written atomically.
    public static func plistData(
        label: String = defaultLabel, executablePath: String, bundleIdentifier: String?
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: propertyList(
                label: label, executablePath: executablePath, bundleIdentifier: bundleIdentifier),
            format: .xml, options: 0)
    }

    /// The program a LaunchAgent plist starts: `ProgramArguments[0]`, else `Program`. Nil if unreadable.
    public static func program(inPlist data: Data) -> String? {
        guard
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let plist = object as? [String: Any]
        else { return nil }
        if let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first, !first.isEmpty {
            return first
        }
        if let program = plist["Program"] as? String, !program.isEmpty {
            return program
        }
        return nil
    }

    /// Compares the file's program with this executable (`data == nil` means there is no file).
    public static func fileState(plistData data: Data?, executablePath: String) -> NotchLoginAgentFileState {
        guard let data else { return .missing }
        guard let program = program(inPlist: data) else { return .stale(program: nil) }
        return normalizedPath(program) == normalizedPath(executablePath) ? .current : .stale(program: program)
    }

    /// `launchctl bootout` target for the per-user GUI domain: `gui/<uid>/<label>`.
    public static func bootoutTarget(uid: UInt32, label: String = defaultLabel) -> String {
        "gui/\(uid)/\(label)"
    }

    /// Standardized absolute path (no `.`/`..`, no trailing slash).
    public static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Single instance: which copy keeps running when SuperNotch is started twice (e.g. at login).
public enum NotchInstanceGuard {
    public struct Instance: Sendable, Equatable {
        public var pid: Int32
        /// Nil when unknown (processes not started through LaunchServices have none).
        public var launchDate: Date?

        public init(pid: Int32, launchDate: Date?) {
            self.pid = pid
            self.launchDate = launchDate
        }
    }

    /// True when `current` must quit because an older copy runs. The oldest copy wins: the earlier launch date,
    /// or the lower pid when a date is missing or equal. Two copies that start at the same moment therefore
    /// never both quit.
    public static func shouldYield(current: Instance, others: [Instance]) -> Bool {
        others.contains { other in
            guard other.pid != current.pid else { return false }
            if let otherDate = other.launchDate, let ownDate = current.launchDate, otherDate != ownDate {
                return otherDate < ownDate
            }
            return other.pid < current.pid
        }
    }
}
