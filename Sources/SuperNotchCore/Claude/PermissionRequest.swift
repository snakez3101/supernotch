import Foundation

// CONTRACT FILE (SPEC §D.1). Owner: claude-core.

/// Result of `DangerousCommandClassifier`.
public struct DangerAssessment: Sendable, Hashable {
    public var isDangerous: Bool
    /// Short human reasons, e.g. ["recursive delete", "force push"].
    public var reasons: [String]
    public init(isDangerous: Bool, reasons: [String] = []) {
        self.isDangerous = isDangerous
        self.reasons = reasons
    }
    public static let safe = DangerAssessment(isDangerous: false)
}

/// A pending tool-permission prompt that can be answered from the notch.
public struct PermissionRequest: Sendable, Hashable, Identifiable {
    /// `HookEnvelope.id` of the blocking hook connection. Replies are keyed by this.
    public let id: String
    public let sessionID: String
    public let toolName: String
    public let toolInput: JSONValue
    /// One line for the card, e.g. "rm -rf node_modules" or "Edit Sources/App.swift".
    public let summary: String
    /// Optional second line (Bash `description`, file path, URL…).
    public let detail: String?
    public let danger: DangerAssessment
    /// Raw `permission_suggestions`; a safe subset of them backs "Always allow".
    public let suggestions: [JSONValue]
    public let receivedAt: Date

    public init(
        id: String, sessionID: String, toolName: String, toolInput: JSONValue, summary: String,
        detail: String?, danger: DangerAssessment, suggestions: [JSONValue], receivedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.toolName = toolName
        self.toolInput = toolInput
        self.summary = summary
        self.detail = detail
        self.danger = danger
        self.suggestions = suggestions
        self.receivedAt = receivedAt
    }

    /// Builds a request from a PermissionRequest envelope (nil if it is not one or lacks a session id).
    public init?(envelope: HookEnvelope, now: Date) {
        let hook = envelope.hook
        guard envelope.event == .permissionRequest, let sessionID = hook.sessionID else { return nil }
        let toolName = hook.toolName ?? "Tool"
        let input = hook.toolInput ?? .object(JSONObject())
        let summary = PermissionSummary.make(toolName: toolName, input: input)
        self.init(
            id: envelope.id,
            sessionID: sessionID,
            toolName: toolName,
            toolInput: input,
            summary: summary.summary,
            detail: summary.detail,
            danger: DangerousCommandClassifier.assess(toolName: toolName, input: input),
            suggestions: hook.permissionSuggestions,
            receivedAt: now
        )
    }

    /// "Always allow" is offered only when a safe permission update exists (see `alwaysAllowUpdates`).
    public var canAlwaysAllow: Bool { !alwaysAllowUpdates.isEmpty }

    /// Decision for the "Always allow" button: echo the suggested updates (hooks.md "A hook can echo one of
    /// the permission_suggestions it received as its own updatedPermissions"). Falls back to plain allow.
    public var alwaysAllowDecision: PermissionDecision {
        let updates = alwaysAllowUpdates
        return updates.isEmpty ? .allow : .allowAlways(updatedPermissions: updates)
    }

    /// The `permission_suggestions` we are willing to echo, most specific first:
    /// 1. `addRules` / `replaceRules` entries with `behavior: "allow"` (e.g. "don't ask again for `npm test`");
    /// 2. otherwise `setMode` entries to `acceptEdits` (what the native "allow all edits" option does) and
    ///    `addDirectories` entries.
    /// Never echoed: deny/ask rules, `removeRules`, and modes that switch permission checks off
    /// (`bypassPermissions`, `dontAsk`, `auto`).
    public var alwaysAllowUpdates: [JSONValue] {
        let allowRules = suggestions.filter { entry in
            let type = entry["type"]?.stringValue
            return (type == "addRules" || type == "replaceRules") && entry["behavior"]?.stringValue == "allow"
                && !(entry["rules"]?.arrayValue ?? []).isEmpty
        }
        if !allowRules.isEmpty { return allowRules }
        return suggestions.filter { entry in
            switch entry["type"]?.stringValue {
            case "setMode"?:
                return entry["mode"]?.stringValue == "acceptEdits"
            case "addDirectories"?:
                return !(entry["directories"]?.arrayValue ?? []).isEmpty
            default:
                return false
            }
        }
    }

    /// Whether a tool event (PostToolUse, PostToolUseFailure, PermissionDenied) of the same session belongs to
    /// this request. PermissionRequest carries no `tool_use_id`, so we compare the tool name plus the input,
    /// falling back to the identifying field (command, file path, URL…) because Claude Code may normalise
    /// other input fields between the two events.
    public func matches(toolName otherTool: String?, toolInput otherInput: JSONValue?) -> Bool {
        guard let otherTool, otherTool == toolName else { return false }
        guard let otherInput else { return true }
        if otherInput == toolInput { return true }
        for key in PermissionSummary.identifyingKeys {
            if let mine = toolInput[key], let theirs = otherInput[key] { return mine == theirs }
        }
        return false
    }
}

/// One-line summaries for the permission card. Owner: claude-core.
public enum PermissionSummary {
    /// Input fields that identify a tool call (first present one wins).
    public static let identifyingKeys = [
        "command", "file_path", "notebook_path", "url", "query", "pattern", "path", "plan", "prompt",
    ]

    public static func make(toolName: String, input: JSONValue) -> (summary: String, detail: String?) {
        switch toolName {
        case "Bash", "PowerShell":
            return (clip(input["command"]?.stringValue ?? toolName), input["description"]?.stringValue.map { clip($0) })
        case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit":
            let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue ?? ""
            let verb = toolName == "MultiEdit" ? "Edit" : toolName
            return ("\(verb) \(clip(displayPath(path)))", path.isEmpty ? nil : clip(path))
        case "Glob", "Grep":
            let pattern = input["pattern"]?.stringValue ?? ""
            return ("\(toolName) \(clip(pattern))", input["path"]?.stringValue.map { clip($0) })
        case "WebFetch":
            return ("Fetch \(clip(input["url"]?.stringValue ?? ""))", input["prompt"]?.stringValue.map { clip($0) })
        case "WebSearch":
            return ("Search “\(clip(input["query"]?.stringValue ?? ""))”", nil)
        case "ExitPlanMode":
            return ("Approve plan", input["plan"]?.stringValue.map { clip($0) })
        case "Agent", "Task":
            let type = input["subagent_type"]?.stringValue ?? "agent"
            return ("Run \(type)", (input["description"] ?? input["prompt"])?.stringValue.map { clip($0) })
        default:
            let compact = input.serialized()
            let detail = compact == "{}" ? nil : clip(compact)
            if toolName.hasPrefix("mcp__") {
                // mcp__<server>__<tool> → "server · tool"
                let parts = toolName.dropFirst(5).components(separatedBy: "__")
                if parts.count >= 2 { return ("\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))", detail) }
            }
            return (toolName, detail)
        }
    }

    /// Flattens newlines and cuts to `limit` characters.
    public static func clip(_ text: String, _ limit: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// Last two path components ("Sources/App.swift") so the card stays one line.
    static func displayPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 2 else { return path }
        return parts.suffix(2).joined(separator: "/")
    }
}
