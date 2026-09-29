import Foundation

// CONTRACT FILE (SPEC §D.7). Owner: claude-core. Typed, tolerant view over a raw hook stdin payload.
// Field names follow https://code.claude.com/docs/en/hooks (see docs/ in the research scratchpad).
// Every accessor returns nil / a default for a missing or mistyped field; nothing here throws.

public struct HookPayload: Sendable, Hashable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }

    private func string(_ key: String) -> String? {
        guard let value = raw[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    // Common fields
    public var sessionID: String? { string("session_id") }
    public var transcriptPath: String? { string("transcript_path") }
    public var cwd: String? { string("cwd") }
    public var permissionMode: String? { string("permission_mode") }
    public var hookEventName: HookEventName? { string("hook_event_name").map(HookEventName.init(rawValue:)) }
    public var promptID: String? { string("prompt_id") }
    /// Present only when the hook fires inside a subagent.
    public var agentID: String? { string("agent_id") }
    public var agentType: String? { string("agent_type") }

    // Tool events (PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied)
    public var toolName: String? { string("tool_name") }
    public var toolInput: JSONValue? { raw["tool_input"] }
    /// Absent on PermissionRequest (documented), present on Pre/PostToolUse and PermissionDenied.
    public var toolUseID: String? { string("tool_use_id") }
    public var permissionSuggestions: [JSONValue] { raw["permission_suggestions"]?.arrayValue ?? [] }
    public var denialReason: String? { string("reason") }
    /// PostToolUseFailure: the failure reached Claude Code as an abort rather than a tool error.
    public var isInterrupt: Bool { raw["is_interrupt"]?.boolValue ?? false }

    // UserPromptSubmit
    public var prompt: String? { string("prompt") }

    // SessionStart
    /// "startup" | "resume" | "clear" | "compact" | "fork"
    public var source: String? { string("source") }
    public var sessionTitle: String? { string("session_title") }
    public var model: String? { string("model") }

    // SessionEnd
    /// "clear" | "resume" | "logout" | "prompt_input_exit" | "other"
    public var endReason: String? { string("reason") }

    // Notification
    public var notificationType: String? { string("notification_type") }
    public var message: String? { string("message") }
    public var title: String? { string("title") }

    // Stop / SubagentStop / StopFailure
    public var lastAssistantMessage: String? { string("last_assistant_message") }
    public var stopHookActive: Bool { raw["stop_hook_active"]?.boolValue ?? false }
    public var backgroundTaskCount: Int { raw["background_tasks"]?.arrayValue?.count ?? 0 }
    /// `background_tasks` of Stop/SubagentStop; nil when Claude Code did not send the array (older versions,
    /// task registry unreachable). An empty array means nothing is in flight.
    public var backgroundTasks: [JSONValue]? { raw["background_tasks"]?.arrayValue }
    /// True when `background_tasks` lists at least one running subagent.
    public var hasBackgroundSubagents: Bool {
        backgroundTasks?.contains { $0["type"]?.stringValue == "subagent" } ?? false
    }
    /// SubagentStop: the subagent's own transcript.
    public var agentTranscriptPath: String? { string("agent_transcript_path") }
    /// StopFailure error type, e.g. "rate_limit".
    public var error: String? { string("error") }
    public var errorDetails: String? { string("error_details") }
}

/// Notification types we care about (hooks.md "Notification").
public enum NotificationType {
    public static let permissionPrompt = "permission_prompt"
    public static let idlePrompt = "idle_prompt"
    public static let elicitationDialog = "elicitation_dialog"
    public static let elicitationURLDialog = "elicitation_url_dialog"
    public static let elicitationComplete = "elicitation_complete"
    public static let elicitationResponse = "elicitation_response"
    public static let agentNeedsInput = "agent_needs_input"
    public static let agentCompleted = "agent_completed"
    public static let quotaAutoResumeFired = "quota_auto_resume_fired"

    /// Types that mean "the session needs the user".
    public static let needsInput: Set<String> = [
        permissionPrompt, elicitationDialog, elicitationURLDialog, agentNeedsInput,
    ]

    /// Types that mean "a question/elicitation was answered and Claude continues".
    public static let resumesWork: Set<String> = [elicitationComplete, elicitationResponse, quotaAutoResumeFired]

    /// The needs-input kind a notification type maps to (nil for other types).
    public static func needsInputKind(for type: String) -> NeedsInputKind? {
        switch type {
        case permissionPrompt: return .permission
        case elicitationDialog, elicitationURLDialog: return .question
        case agentNeedsInput: return .other
        default: return nil
        }
    }
}

/// Makes hook payloads cheap to ship over the socket (SPEC §D.7 performance budget).
///
/// * `tool_response` is dropped: SuperNotch never reads it and it can hold whole files (Read) or long
///   command output (Bash).
/// * Strings longer than `maxStringBytes` are cut on a character boundary and marked. The cut is
///   deterministic, so a PermissionRequest and the PostToolUse of the same call still compare equal.
public enum HookPayloadCompactor {
    public static let droppedTopLevelKeys: Set<String> = ["tool_response"]
    public static let truncationMarker = "…[truncated]"

    public static func compact(_ payload: JSONValue, maxStringBytes: Int = IPCConfig.maxPayloadStringBytes)
        -> JSONValue
    {
        guard case .object(let object) = payload else { return truncate(payload, limit: maxStringBytes) }
        var result = JSONObject()
        for (key, value) in object.pairs where !droppedTopLevelKeys.contains(key) {
            result[key] = truncate(value, limit: maxStringBytes)
        }
        return .object(result)
    }

    static func truncate(_ value: JSONValue, limit: Int) -> JSONValue {
        switch value {
        case .string(let text):
            guard text.utf8.count > limit else { return value }
            var kept = ""
            var bytes = 0
            for character in text {
                let size = character.utf8.count
                if bytes + size > limit { break }
                kept.append(character)
                bytes += size
            }
            return .string(kept + truncationMarker)
        case .array(let values):
            return .array(values.map { truncate($0, limit: limit) })
        case .object(let object):
            var result = JSONObject()
            for (key, element) in object.pairs { result[key] = truncate(element, limit: limit) }
            return .object(result)
        case .null, .bool, .number:
            return value
        }
    }
}
