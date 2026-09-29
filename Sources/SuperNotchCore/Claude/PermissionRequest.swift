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
    /// Raw `permission_suggestions`; non-empty ⇒ "Always allow" is offered.
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

    public var canAlwaysAllow: Bool { !suggestions.isEmpty }

    /// Decision for the "Always allow" button: echo the suggestions, preferring allow-rules
    /// (SPEC §D.5). Falls back to plain allow when there are none.
    public var alwaysAllowDecision: PermissionDecision {
        let allowRules = suggestions.filter { $0["behavior"]?.stringValue == "allow" }
        let chosen = allowRules.isEmpty ? suggestions : allowRules
        return chosen.isEmpty ? .allow : .allowAlways(updatedPermissions: chosen)
    }
}

/// One-line summaries for the permission card. Owner: claude-core (may refine wording).
public enum PermissionSummary {
    public static func make(toolName: String, input: JSONValue) -> (summary: String, detail: String?) {
        func clip(_ text: String, _ limit: Int = 160) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
            return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
        }
        switch toolName {
        case "Bash", "PowerShell":
            return (clip(input["command"]?.stringValue ?? toolName), input["description"]?.stringValue.map { clip($0) })
        case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit":
            let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue ?? ""
            return ("\(toolName) \(clip(path))", nil)
        case "WebFetch":
            return ("Fetch \(clip(input["url"]?.stringValue ?? ""))", nil)
        case "WebSearch":
            return ("Search “\(clip(input["query"]?.stringValue ?? ""))”", nil)
        case "ExitPlanMode":
            return ("Approve plan", input["plan"]?.stringValue.map { clip($0) })
        default:
            let compact = input.serialized()
            return (toolName, compact == "{}" ? nil : clip(compact))
        }
    }
}
