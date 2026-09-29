import Foundation

// Owner: claude-core. Signatures FROZEN (SPEC §D.6).
// Pure logic that edits the parsed <config>/settings.json. The app (claude-app HookInstaller) does the IO:
// backup (`HookSettingsMerger.backupPath`), re-read, atomic write (`serialize`), manifest write.
//
// Rules: strict parse (invalid JSON ⇒ refuse), keep unknown keys and key order, 2-space pretty print,
// idempotent (install twice ⇒ same bytes), uninstall removes only our entries and only the containers we
// created, the statusLine bridge wraps (and restores) the user's own statusLine and never wraps itself.

/// POSIX shell quoting (Claude Code runs hook and statusLine commands through a shell).
public enum ShellQuote {
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Splits a command line into words the way `sh` would for plain words, single quotes, double quotes and
    /// backslash escapes (no expansion). Used to read our own `--wrap '<command>'` argument back.
    public static func split(_ command: String) -> [String] {
        enum Mode { case plain, single, double }
        var words: [String] = []
        var current = ""
        var inWord = false
        var mode = Mode.plain
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch mode {
            case .plain:
                if character == " " || character == "\t" || character == "\n" {
                    if inWord { words.append(current) }
                    current = ""
                    inWord = false
                } else if character == "'" {
                    mode = .single
                    inWord = true
                } else if character == "\"" {
                    mode = .double
                    inWord = true
                } else if character == "\\" {
                    if index + 1 < characters.count {
                        index += 1
                        if characters[index] != "\n" { current.append(characters[index]) }
                    }
                    inWord = true
                } else {
                    current.append(character)
                    inWord = true
                }
            case .single:
                if character == "'" { mode = .plain } else { current.append(character) }
            case .double:
                if character == "\"" {
                    mode = .plain
                } else if character == "\\", index + 1 < characters.count,
                    ["$", "`", "\"", "\\", "\n"].contains(characters[index + 1])
                {
                    index += 1
                    if characters[index] != "\n" { current.append(characters[index]) }
                } else {
                    current.append(character)
                }
            }
            index += 1
        }
        if inWord { words.append(current) }
        return words
    }
}

/// What to install.
public struct HookInstallSpec: Sendable, Hashable {
    /// Full command string for hook entries, e.g. `'/Users/me/…/supernotch-hook' hook`.
    public var hookCommand: String
    /// Base statusLine command (`'…/supernotch-hook' statusline`), nil ⇒ do not install / remove the bridge.
    /// When the user already has a statusLine, the installed command is
    /// `<statusLineCommand> --wrap '<their command>'` (see `statusLineCommand(wrapping:)`).
    public var statusLineCommand: String?
    public var events: [HookEventName]
    /// Substring identifying our entries (also matches entries from older install paths of the same layout).
    public var marker: String

    public static let defaultMarker = "SuperNotch/bin/supernotch-hook"

    public init(
        hookCommand: String, statusLineCommand: String?, events: [HookEventName],
        marker: String = HookInstallSpec.defaultMarker
    ) {
        self.hookCommand = hookCommand
        self.statusLineCommand = statusLineCommand
        self.events = events
        self.marker = marker
    }

    /// Standard spec. `claudeVersion == nil` (unknown) ⇒ base events only. A known version also drops base
    /// events it predates (before 2.1.101 one unknown event name made Claude Code ignore the whole file).
    public static func make(hookBinaryPath: String, claudeVersion: ClaudeVersion?, wrapStatusLine: Bool)
        -> HookInstallSpec
    {
        var events = HookEventName.baseEvents
        if let version = claudeVersion {
            events = events.filter { event in
                event.minimumVersion.flatMap { ClaudeVersion($0) }.map { version >= $0 } ?? true
            }
            if let gate = ClaudeVersion(HookEventName.extendedEventsMinimumVersion), version >= gate {
                events += HookEventName.extendedEvents
            }
        }
        let binary = ShellQuote.quote(hookBinaryPath)
        return HookInstallSpec(
            hookCommand: binary + " hook", statusLineCommand: wrapStatusLine ? binary + " statusline" : nil,
            events: events)
    }

    public func timeout(for event: HookEventName) -> Int {
        event.isBlocking ? IPCConfig.permissionHookTimeout : IPCConfig.defaultHookTimeout
    }

    /// The `timeout` key we write. None for SessionEnd: Claude Code raises the whole exit budget (default
    /// 1.5 s) to the highest per-hook SessionEnd timeout, and our hook needs a few milliseconds.
    public func writtenTimeout(for event: HookEventName) -> Int? {
        event == .sessionEnd ? nil : timeout(for: event)
    }

    /// The statusLine command to install, wrapping `original` (the user's command) when there is one.
    public func statusLineCommand(wrapping original: String?) -> String? {
        guard let base = statusLineCommand else { return nil }
        guard let original, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !HookSettingsMerger.isOurCommand(original, marker: marker)
        else { return base }
        return base + " " + IPCConfig.statusLineWrapArgument + " " + ShellQuote.quote(original)
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

    /// The statusLine command the bridge should run after forwarding (nil if none, not a command, or ours).
    public var originalStatusLineCommand: String? {
        guard let original = originalStatusLine, original["type"]?.stringValue ?? "command" == "command",
            let command = original["command"]?.stringValue,
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !HookSettingsMerger.isOurCommand(command, marker: HookInstallSpec.defaultMarker)
        else { return nil }
        return command
    }

    // Tolerant decoding: a manifest from another app version must never make the app fail.
    private enum CodingKeys: String, CodingKey {
        case formatVersion, installedAt, appVersion, settingsFile, hookCommand, events, createdHooksObject
        case createdEventKeys, originalStatusLine, statusLineInstalled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            formatVersion: (try? c.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? 1,
            installedAt: (try? c.decodeIfPresent(Date.self, forKey: .installedAt)) ?? Date(timeIntervalSince1970: 0),
            appVersion: (try? c.decodeIfPresent(String.self, forKey: .appVersion)) ?? "",
            settingsFile: (try? c.decodeIfPresent(String.self, forKey: .settingsFile)) ?? "",
            hookCommand: (try? c.decodeIfPresent(String.self, forKey: .hookCommand)) ?? "",
            events: (try? c.decodeIfPresent([String].self, forKey: .events)) ?? [],
            createdHooksObject: (try? c.decodeIfPresent(Bool.self, forKey: .createdHooksObject)) ?? false,
            createdEventKeys: (try? c.decodeIfPresent([String].self, forKey: .createdEventKeys)) ?? [],
            originalStatusLine: (try? c.decodeIfPresent(JSONValue.self, forKey: .originalStatusLine)) ?? nil,
            statusLineInstalled: (try? c.decodeIfPresent(Bool.self, forKey: .statusLineInstalled)) ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(installedAt, forKey: .installedAt)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(settingsFile, forKey: .settingsFile)
        try c.encode(hookCommand, forKey: .hookCommand)
        try c.encode(events, forKey: .events)
        try c.encode(createdHooksObject, forKey: .createdHooksObject)
        try c.encode(createdEventKeys, forKey: .createdEventKeys)
        try c.encodeIfPresent(originalStatusLine, forKey: .originalStatusLine)
        try c.encode(statusLineInstalled, forKey: .statusLineInstalled)
    }
}

public enum HookInstallState: Sendable, Hashable {
    case notInstalled
    case installed
    /// Some of our entries exist but not all, or with another command/path/timeout, duplicated, on events
    /// that should not have them, or the statusLine bridge does not match: run install again.
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
    // MARK: - Parse / serialize (the only accepted way in and out)

    /// Strictly parses the bytes of settings.json. `nil`, empty or whitespace-only data ⇒ nil (treated as `{}`).
    /// Invalid JSON or a non-object document ⇒ throws; the caller must then refuse to write.
    public static func parseSettings(_ data: Data?) throws -> JSONValue? {
        guard let data, data.contains(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) else {
            return nil
        }
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch let error as JSONParseError {
            throw HookSettingsError("settings.json is not valid JSON (\(error.description)). Nothing was changed.")
        }
        guard case .object = value else {
            throw HookSettingsError("settings.json does not contain a JSON object. Nothing was changed.")
        }
        return value
    }

    /// Bytes to write: 2-space pretty JSON plus a trailing newline (how Claude Code writes the file).
    public static func serialize(_ settings: JSONValue) -> Data { settings.serializedData(pretty: true) }

    /// `settings.json.2026-09-29T14-03-11Z.bak` (colons replaced, Finder shows them as slashes). Settings files
    /// outside a `.claude` folder get their folder name as a prefix so backups of several config dirs never
    /// collide (`.claude-work.settings.json.<date>.bak`).
    public static func backupFileName(settingsFile: String, date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let parts = settingsFile.split(separator: "/")
        let base = parts.last.map(String.init) ?? "settings.json"
        let folder = parts.count >= 2 ? String(parts[parts.count - 2]) : ""
        let prefix = folder.isEmpty || folder == ".claude" ? "" : folder + "."
        return prefix + base + "." + stamp + ".bak"
    }

    /// Full backup path inside `directory` (normally `SuperNotchPaths.settingsBackupDirectory`).
    public static func backupPath(directory: String, settingsFile: String, date: Date) -> String {
        var dir = directory
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        return dir + "/" + backupFileName(settingsFile: settingsFile, date: date)
    }

    /// Exactly the JSON we add (for the onboarding preview): our matcher groups per event and the bridge.
    public static func previewEntries(spec: HookInstallSpec, originalStatusLineCommand: String?) -> JSONValue {
        var hooks = JSONObject()
        for event in spec.events { hooks[event.rawValue] = .array([ourGroup(spec: spec, event: event)]) }
        var root = JSONObject()
        root["hooks"] = .object(hooks)
        if let command = spec.statusLineCommand(wrapping: originalStatusLineCommand) {
            root["statusLine"] = .object(JSONObject([("type", "command"), ("command", .string(command))]))
        }
        return .object(root)
    }

    /// `disableAllHooks: true` switches every hook (and the statusLine) off; the installer should say so.
    public static func hooksDisabled(in settings: JSONValue?) -> Bool {
        settings?["disableAllHooks"]?.boolValue ?? false
    }

    // MARK: - Install / uninstall

    /// Installs (or re-installs) our entries. `settings == nil` means the file does not exist.
    /// `previousManifest` is only trusted when it was written for the same `settingsFile`.
    /// Throws when the document is not an object or `hooks`/an event entry has an unexpected type
    /// (we never "fix" a user's file).
    public static func install(
        spec: HookInstallSpec, into settings: JSONValue?, previousManifest: HookManifest?, settingsFile: String,
        appVersion: String, now: Date
    ) throws -> HookMergeResult {
        let original = settings ?? .object(JSONObject())
        guard case .object(let object) = original else {
            throw HookSettingsError("settings.json does not contain a JSON object. Nothing was changed.")
        }
        let manifest = previousManifest.flatMap { $0.settingsFile == settingsFile ? $0 : nil }

        // 1. Strip our old entries (keeps user entries and key order).
        let stripped = try removeOurEntries(from: object, marker: spec.marker)
        var root = stripped.root

        // 2. Ensure the "hooks" object.
        var createdHooks = manifest?.createdHooksObject ?? false
        var hooks: JSONObject
        switch root["hooks"] {
        case nil, .null?:
            hooks = JSONObject()
            createdHooks = true
        case .object(let existing)?:
            hooks = existing
            if manifest == nil, existing.isEmpty, stripped.removedAny { createdHooks = true }
        default:
            throw HookSettingsError("\"hooks\" in settings.json is not an object. Nothing was changed.")
        }

        // 3. Append one matcher group per event.
        var createdKeys = Set(manifest?.createdEventKeys ?? [])
        if manifest == nil { createdKeys.formUnion(stripped.emptiedKeys) }
        for event in spec.events {
            var groups: [JSONValue]
            switch hooks[event.rawValue] {
            case nil, .null?:
                groups = []
                createdKeys.insert(event.rawValue)
            case .array(let existing)?:
                groups = existing
            default:
                throw HookSettingsError("\"hooks.\(event.rawValue)\" is not an array. Nothing was changed.")
            }
            groups.append(ourGroup(spec: spec, event: event))
            hooks[event.rawValue] = .array(groups)
        }
        // Arrays we created for events that are no longer installed disappear once empty.
        let installedKeys = Set(spec.events.map(\.rawValue))
        for key in createdKeys.subtracting(installedKeys) {
            if hooks[key]?.arrayValue?.isEmpty == true { hooks[key] = nil }
            if hooks[key] == nil { createdKeys.remove(key) }
        }
        root["hooks"] = .object(hooks)

        // 4. statusLine bridge.
        let current = root["statusLine"]
        let currentIsOurs = current.map { isOurs($0, marker: spec.marker) } ?? false
        var originalStatusLine: JSONValue?
        if currentIsOurs {
            originalStatusLine = manifest?.originalStatusLine ?? current.flatMap(recoverWrappedStatusLine)
        } else if let current, !current.isNull {
            originalStatusLine = current
        }
        if let status = originalStatusLine, isOurs(status, marker: spec.marker) { originalStatusLine = nil }  // #671

        if spec.statusLineCommand != nil {
            let originalCommand =
                (originalStatusLine?["type"]?.stringValue ?? "command") == "command"
                ? originalStatusLine?["command"]?.stringValue : nil
            var bridge = JSONObject()
            bridge["type"] = "command"
            bridge["command"] = spec.statusLineCommand(wrapping: originalCommand).map(JSONValue.string)
            for (key, value) in originalStatusLine?.objectValue?.pairs ?? [] where key != "type" && key != "command" {
                bridge[key] = value  // padding, refreshInterval, hideVimModeIndicator, …
            }
            root["statusLine"] = .object(bridge)
        } else {
            if currentIsOurs { root["statusLine"] = originalStatusLine }
            originalStatusLine = nil
        }

        let newManifest = HookManifest(
            installedAt: now, appVersion: appVersion, settingsFile: settingsFile, hookCommand: spec.hookCommand,
            events: spec.events.map(\.rawValue), createdHooksObject: createdHooks,
            createdEventKeys: spec.events.map(\.rawValue).filter { createdKeys.contains($0) },
            originalStatusLine: originalStatusLine, statusLineInstalled: spec.statusLineCommand != nil)
        let result = JSONValue.object(root)
        return HookMergeResult(
            settings: result, manifest: newManifest,
            changed: result.serialized(pretty: true) != original.serialized(pretty: true))
    }

    /// Removes all our entries; restores the original statusLine; drops containers we created that became empty.
    /// Pass the manifest written for this settings file (nil if it is lost: arrays and the `hooks` object that
    /// only contained our entries are then removed).
    public static func uninstall(
        from settings: JSONValue, manifest: HookManifest?,
        marker: String =
            HookInstallSpec.defaultMarker
    ) throws -> JSONValue {
        guard case .object(let object) = settings else {
            throw HookSettingsError("settings.json does not contain a JSON object. Nothing was changed.")
        }
        let stripped = try removeOurEntries(from: object, marker: marker)
        var root = stripped.root
        if case .object(var hooks)? = root["hooks"] {
            let dropKeys = manifest.map { Set($0.createdEventKeys) } ?? stripped.emptiedKeys
            for key in dropKeys where hooks[key]?.arrayValue?.isEmpty == true { hooks[key] = nil }
            let createdHooks = manifest?.createdHooksObject ?? stripped.removedAny
            if hooks.isEmpty && createdHooks {
                root["hooks"] = nil
            } else {
                root["hooks"] = .object(hooks)
            }
        }
        if let status = root["statusLine"], isOurs(status, marker: marker) {
            let restored = manifest?.originalStatusLine ?? recoverWrappedStatusLine(status)
            root["statusLine"] = restored.flatMap { isOurs($0, marker: marker) ? nil : $0 }
        }
        return .object(root)
    }

    public static func state(of settings: JSONValue?, spec: HookInstallSpec) -> HookInstallState {
        let hooks = settings?["hooks"]?.objectValue ?? JSONObject()
        var missing: [HookEventName] = []
        var anyOurs = false
        var mismatch = false
        for event in spec.events {
            let ours = entries(in: hooks[event.rawValue]).filter { isOurs($0, marker: spec.marker) }
            if !ours.isEmpty { anyOurs = true }
            if ours.count > 1 { mismatch = true }
            let exact = ours.contains { entry in
                entry["command"]?.stringValue == spec.hookCommand
                    && entry["timeout"]?.intValue == spec.writtenTimeout(for: event)
            }
            if !exact { missing.append(event) }
        }
        let wanted = Set(spec.events.map(\.rawValue))
        for (key, value) in hooks.pairs where !wanted.contains(key) {
            if entries(in: value).contains(where: { isOurs($0, marker: spec.marker) }) {
                anyOurs = true
                mismatch = true
            }
        }
        let status = settings?["statusLine"]
        let statusIsOurs = status.map { isOurs($0, marker: spec.marker) } ?? false
        if statusIsOurs { anyOurs = true }
        if let base = spec.statusLineCommand {
            let command = status?["command"]?.stringValue ?? ""
            if !(statusIsOurs && (command == base || command.hasPrefix(base + " "))) { mismatch = true }
        } else if statusIsOurs {
            mismatch = true
        }
        if missing.isEmpty && !mismatch { return .installed }
        if !anyOurs { return .notInstalled }
        return .needsRepair(missing: missing)
    }

    // MARK: - Helpers

    /// True for a hook entry / statusLine object whose command is ours.
    public static func isOurs(_ value: JSONValue, marker: String) -> Bool {
        guard let command = value["command"]?.stringValue else { return false }
        return isOurCommand(command, marker: marker)
    }

    /// A command runs our hook binary: it contains the install marker, or invokes any `supernotch-hook` binary
    /// with our `hook` / `statusline` verb (dev builds, moved installs). Protects against wrapping ourselves.
    public static func isOurCommand(_ command: String, marker: String) -> Bool {
        if command.contains(marker) { return true }
        let binary = SuperNotchPaths.hookBinaryName
        guard command.contains(binary) else { return false }
        let words = ShellQuote.split(command)
        guard let index = words.firstIndex(where: { $0 == binary || $0.hasSuffix("/" + binary) }),
            index + 1 < words.count
        else { return false }
        return words[index + 1] == "hook" || words[index + 1] == "statusline"
    }

    /// The user's statusLine object reconstructed from our bridge command's `--wrap '<command>'` argument
    /// (used when the manifest is lost). Other keys (padding, …) are carried over from `bridge`.
    public static func recoverWrappedStatusLine(_ bridge: JSONValue) -> JSONValue? {
        guard let command = bridge["command"]?.stringValue else { return nil }
        let words = ShellQuote.split(command)
        guard let flag = words.firstIndex(of: IPCConfig.statusLineWrapArgument), flag + 1 < words.count else {
            return nil
        }
        var object = JSONObject()
        object["type"] = "command"
        object["command"] = .string(words[flag + 1])
        for (key, value) in bridge.objectValue?.pairs ?? [] where key != "type" && key != "command" {
            object[key] = value
        }
        return .object(object)
    }

    static func ourGroup(spec: HookInstallSpec, event: HookEventName) -> JSONValue {
        var entry = JSONObject()
        entry["type"] = "command"
        entry["command"] = .string(spec.hookCommand)
        if let timeout = spec.writtenTimeout(for: event) { entry["timeout"] = .number(Double(timeout)) }
        var group = JSONObject()
        if event.supportsMatcher { group["matcher"] = "*" }
        group["hooks"] = .array([.object(entry)])
        return .object(group)
    }

    /// All hook entries of one event array (`[{matcher, hooks: [entry…]}…]`).
    static func entries(in groups: JSONValue?) -> [JSONValue] {
        (groups?.arrayValue ?? []).flatMap { $0["hooks"]?.arrayValue ?? [] }
    }

    struct Stripped {
        var root: JSONObject
        /// Event keys whose arrays held our entries and are empty now.
        var emptiedKeys: Set<String>
        var removedAny: Bool
    }

    /// Removes our entries from every event array. Groups left without entries are dropped; arrays are kept
    /// (possibly empty) so the caller decides. Unknown shapes are left untouched.
    static func removeOurEntries(from root: JSONObject, marker: String) throws -> Stripped {
        var root = root
        var emptied = Set<String>()
        var removedAny = false
        guard let hooksValue = root["hooks"], !hooksValue.isNull else {
            return Stripped(root: root, emptiedKeys: [], removedAny: false)
        }
        guard case .object(var hooks) = hooksValue else {
            throw HookSettingsError("\"hooks\" in settings.json is not an object. Nothing was changed.")
        }
        for key in hooks.keys {
            guard case .array(let groups)? = hooks[key] else { continue }
            var newGroups: [JSONValue] = []
            var removedHere = false
            for group in groups {
                guard case .object(var groupObject) = group, case .array(let entries)? = groupObject["hooks"] else {
                    newGroups.append(group)
                    continue
                }
                let kept = entries.filter { !isOurs($0, marker: marker) }
                if kept.count == entries.count {
                    newGroups.append(group)
                    continue
                }
                removedHere = true
                if !kept.isEmpty {
                    groupObject["hooks"] = .array(kept)
                    newGroups.append(.object(groupObject))
                }
            }
            if removedHere {
                removedAny = true
                hooks[key] = .array(newGroups)
                if newGroups.isEmpty { emptied.insert(key) }
            }
        }
        root["hooks"] = .object(hooks)
        return Stripped(root: root, emptiedKeys: emptied, removedAny: removedAny)
    }
}
