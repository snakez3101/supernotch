import Foundation

// Owner: claude-core. Signatures FROZEN (SPEC §D.6); baseline implementation by the foundation, harden + test.
// Pure logic that edits the parsed ~/.claude/settings.json. The app (claude-app HookInstaller) does the IO:
// backup, re-read, atomic write, manifest write.

/// POSIX shell single-quoting (Claude Code runs hook commands through a shell).
public enum ShellQuote {
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What to install.
public struct HookInstallSpec: Sendable, Hashable {
    /// Full command string for hook entries, e.g. `'/Users/me/…/supernotch-hook' hook`.
    public var hookCommand: String
    /// Full statusLine command (`'…/supernotch-hook' statusline`), nil ⇒ do not install / remove the bridge.
    public var statusLineCommand: String?
    public var events: [HookEventName]
    /// Substring identifying our entries (also matches entries from older install paths of the same layout).
    public var marker: String

    public static let defaultMarker = "SuperNotch/bin/supernotch-hook"

    public init(hookCommand: String, statusLineCommand: String?, events: [HookEventName],
        marker: String = HookInstallSpec.defaultMarker)
    {
        self.hookCommand = hookCommand
        self.statusLineCommand = statusLineCommand
        self.events = events
        self.marker = marker
    }

    /// Standard spec. `claudeVersion == nil` (unknown) ⇒ base events only.
    public static func make(hookBinaryPath: String, claudeVersion: ClaudeVersion?, wrapStatusLine: Bool)
        -> HookInstallSpec
    {
        var events = HookEventName.baseEvents
        if let version = claudeVersion, let gate = ClaudeVersion(HookEventName.extendedEventsMinimumVersion),
            version >= gate
        {
            events += HookEventName.extendedEvents
        }
        let binary = ShellQuote.quote(hookBinaryPath)
        return HookInstallSpec(
            hookCommand: binary + " hook", statusLineCommand: wrapStatusLine ? binary + " statusline" : nil,
            events: events)
    }

    public func timeout(for event: HookEventName) -> Int {
        event.isBlocking ? IPCConfig.permissionHookTimeout : IPCConfig.defaultHookTimeout
    }
}

/// Written next to the app data (SuperNotchPaths.hookManifest) after each install.
public struct HookManifest: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var installedAt: Date
    public var appVersion: String
    public var settingsFile: String
    public var hookCommand: String
    public var events: [String]
    /// We created the top-level "hooks" object (remove it on uninstall if it ends up empty).
    public var createdHooksObject: Bool
    /// Event arrays we created (remove on uninstall if they end up empty).
    public var createdEventKeys: [String]
    /// The user's statusLine object before we wrapped it (nil = there was none).
    public var originalStatusLine: JSONValue?
    public var statusLineInstalled: Bool

    public init(
        formatVersion: Int = 1, installedAt: Date, appVersion: String, settingsFile: String, hookCommand: String,
        events: [String], createdHooksObject: Bool, createdEventKeys: [String], originalStatusLine: JSONValue?,
        statusLineInstalled: Bool
    ) {
        self.formatVersion = formatVersion
        self.installedAt = installedAt
        self.appVersion = appVersion
        self.settingsFile = settingsFile
        self.hookCommand = hookCommand
        self.events = events
        self.createdHooksObject = createdHooksObject
        self.createdEventKeys = createdEventKeys
        self.originalStatusLine = originalStatusLine
        self.statusLineInstalled = statusLineInstalled
    }

    /// The statusLine command the bridge should run after forwarding (nil if none or not a command).
    public var originalStatusLineCommand: String? {
        guard originalStatusLine?["type"]?.stringValue ?? "command" == "command" else { return nil }
        return originalStatusLine?["command"]?.stringValue
    }
}

public enum HookInstallState: Sendable, Hashable {
    case notInstalled
    case installed
    /// Some of our entries exist but not all (or with another command/path): run install again.
    case needsRepair(missing: [HookEventName])
}

public struct HookSettingsError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct HookMergeResult: Sendable, Hashable {
    public var settings: JSONValue
    public var manifest: HookManifest
    /// False when the input already had exactly these entries.
    public var changed: Bool
}

public enum HookSettingsMerger {
    /// Installs (or re-installs) our entries. `settings == nil` means the file does not exist.
    /// Throws when the document is not an object or `hooks`/an event entry has an unexpected type
    /// (we never "fix" a user's file).
    public static func install(
        spec: HookInstallSpec, into settings: JSONValue?, previousManifest: HookManifest?, settingsFile: String,
        appVersion: String, now: Date
    ) throws -> HookMergeResult {
        let original = settings ?? .object(JSONObject())
        guard case .object(var root) = original else { throw HookSettingsError("settings.json is not a JSON object") }

        // 1. Strip our old entries (keeps user entries and key order).
        root = try removeOurEntries(from: root, marker: spec.marker, dropEmpty: nil)

        // 2. Ensure "hooks" object.
        var createdHooks = previousManifest?.createdHooksObject ?? false
        var hooks: JSONObject
        switch root["hooks"] {
        case nil:
            hooks = JSONObject()
            createdHooks = true
        case .object(let existing)?:
            hooks = existing
        default:
            throw HookSettingsError("\"hooks\" in settings.json is not an object")
        }

        // 3. Append one matcher group per event.
        var createdKeys = Set(previousManifest?.createdEventKeys ?? [])
        for event in spec.events {
            var groups: [JSONValue]
            switch hooks[event.rawValue] {
            case nil:
                groups = []
                createdKeys.insert(event.rawValue)
            case .array(let existing)?:
                groups = existing
            default:
                throw HookSettingsError("\"hooks.\(event.rawValue)\" is not an array")
            }
            var entry = JSONObject()
            entry["type"] = "command"
            entry["command"] = .string(spec.hookCommand)
            entry["timeout"] = .number(Double(spec.timeout(for: event)))
            var group = JSONObject()
            if event.supportsMatcher { group["matcher"] = "*" }
            group["hooks"] = .array([.object(entry)])
            groups.append(.object(group))
            hooks[event.rawValue] = .array(groups)
        }
        // Drop arrays we created earlier for events that are no longer installed, if now empty.
        for key in previousManifest?.createdEventKeys ?? [] where !spec.events.map(\.rawValue).contains(key) {
            if hooks[key]?.arrayValue?.isEmpty == true {
                hooks[key] = nil
                createdKeys.remove(key)
            }
        }
        root["hooks"] = .object(hooks)

        // 4. statusLine bridge.
        var originalStatusLine = previousManifest?.originalStatusLine
        let current = root["statusLine"]
        let currentIsOurs = current.map { isOurs($0, marker: spec.marker) } ?? false
        if let statusCommand = spec.statusLineCommand {
            if !currentIsOurs { originalStatusLine = current }
            var bridge = JSONObject()
            bridge["type"] = "command"
            bridge["command"] = .string(statusCommand)
            if let padding = originalStatusLine?["padding"] { bridge["padding"] = padding }
            root["statusLine"] = .object(bridge)
        } else if currentIsOurs {
            root["statusLine"] = originalStatusLine
            originalStatusLine = nil
        } else {
            originalStatusLine = nil
        }

        let manifest = HookManifest(
            installedAt: now, appVersion: appVersion, settingsFile: settingsFile, hookCommand: spec.hookCommand,
            events: spec.events.map(\.rawValue), createdHooksObject: createdHooks,
            createdEventKeys: spec.events.map(\.rawValue).filter { createdKeys.contains($0) },
            originalStatusLine: originalStatusLine, statusLineInstalled: spec.statusLineCommand != nil)
        let result = JSONValue.object(root)
        return HookMergeResult(settings: result, manifest: manifest, changed: result.serialized() != original.serialized())
    }

    /// Removes all our entries; restores the original statusLine; drops containers we created that became empty.
    public static func uninstall(from settings: JSONValue, manifest: HookManifest?, marker: String =
        HookInstallSpec.defaultMarker) throws -> JSONValue
    {
        guard case .object(var root) = settings else { throw HookSettingsError("settings.json is not a JSON object") }
        root = try removeOurEntries(from: root, marker: marker, dropEmpty: manifest.map { Set($0.createdEventKeys) } ?? [])
        if case .object(let hooks)? = root["hooks"], hooks.isEmpty, manifest?.createdHooksObject ?? false {
            root["hooks"] = nil
        }
        if let status = root["statusLine"], isOurs(status, marker: marker) {
            root["statusLine"] = manifest?.originalStatusLine
        }
        return .object(root)
    }

    public static func state(of settings: JSONValue?, spec: HookInstallSpec) -> HookInstallState {
        let hooks = settings?["hooks"]?.objectValue ?? JSONObject()
        var missing: [HookEventName] = []
        var anyOurs = false
        for event in spec.events {
            let groups = hooks[event.rawValue]?.arrayValue ?? []
            let commands = groups.flatMap { $0["hooks"]?.arrayValue ?? [] }.compactMap { $0["command"]?.stringValue }
            if commands.contains(where: { $0.contains(spec.marker) }) { anyOurs = true }
            if !commands.contains(spec.hookCommand) { missing.append(event) }
        }
        let statusLineMismatch =
            spec.statusLineCommand.map { settings?["statusLine"]?["command"]?.stringValue != $0 } ?? false
        if missing.isEmpty && !statusLineMismatch { return .installed }
        if !anyOurs && missing.count == spec.events.count { return .notInstalled }
        return .needsRepair(missing: missing)
    }

    // MARK: - Helpers

    /// True for a hook entry / statusLine object whose command contains `marker`.
    public static func isOurs(_ value: JSONValue, marker: String) -> Bool {
        value["command"]?.stringValue?.contains(marker) ?? false
    }

    /// - Parameter dropEmpty: event keys whose arrays are removed when they become empty (nil ⇒ none).
    static func removeOurEntries(from root: JSONObject, marker: String, dropEmpty: Set<String>?) throws -> JSONObject {
        var root = root
        guard let hooksValue = root["hooks"] else { return root }
        guard case .object(var hooks) = hooksValue else {
            throw HookSettingsError("\"hooks\" in settings.json is not an object")
        }
        for key in hooks.keys {
            guard case .array(let groups)? = hooks[key] else { continue }  // unknown shape: leave untouched
            var newGroups: [JSONValue] = []
            for group in groups {
                guard case .object(var groupObject) = group, case .array(let entries)? = groupObject["hooks"] else {
                    newGroups.append(group)
                    continue
                }
                let kept = entries.filter { !isOurs($0, marker: marker) }
                if kept.count == entries.count {
                    newGroups.append(group)
                } else if !kept.isEmpty {
                    groupObject["hooks"] = .array(kept)
                    newGroups.append(.object(groupObject))
                }
            }
            if newGroups.isEmpty, let dropEmpty, dropEmpty.contains(key) {
                hooks[key] = nil
            } else {
                hooks[key] = .array(newGroups)
            }
        }
        root["hooks"] = .object(hooks)
        return root
    }
}
