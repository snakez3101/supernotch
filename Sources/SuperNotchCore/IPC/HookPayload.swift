import Foundation

// CONTRACT FILE (SPEC §D.5). Owner: claude-core. Typed, tolerant view over a raw hook stdin payload.
// Field names follow https://code.claude.com/docs/en/hooks (see docs/ in the research scratchpad).

public struct HookPayload: Sendable, Hashable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }

    private func string(_ key: String) -> String? { raw[key]?.stringValue }

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
    public static let agentNeedsInput = "agent_needs_input"
    public static let agentCompleted = "agent_completed"

    /// Types that mean "the session needs the user".
    public static let needsInput: Set<String> = [
        permissionPrompt, elicitationDialog, elicitationURLDialog, agentNeedsInput,
    ]
}
