import Foundation

// CONTRACT FILE (SPEC §D.5). Owner: claude-core.

/// The user's answer to a PermissionRequest, as sent app → hook and printed by the hook to stdout.
public enum PermissionDecision: Sendable, Hashable {
    /// Allow once.
    case allow
    /// Allow and apply permission updates (normally echoed from `permission_suggestions`), i.e. "Always allow".
    case allowAlways(updatedPermissions: [JSONValue])
    /// Deny; `message` is shown to Claude.
    case deny(message: String)

    public static let defaultDenyMessage = "Denied from SuperNotch."

    /// `hookSpecificOutput` object Claude Code expects on stdout for PermissionRequest (hooks.md
    /// "PermissionRequest decision control").
    public var hookOutput: JSONValue {
        var decision = JSONObject()
        switch self {
        case .allow:
            decision["behavior"] = "allow"
        case .allowAlways(let updates):
            decision["behavior"] = "allow"
            if !updates.isEmpty { decision["updatedPermissions"] = .array(updates) }
        case .deny(let message):
            decision["behavior"] = "deny"
            decision["message"] = .string(message)
        }
        var specific = JSONObject()
        specific["hookEventName"] = .string(HookEventName.permissionRequest.rawValue)
        specific["decision"] = .object(decision)
        var root = JSONObject()
        root["hookSpecificOutput"] = .object(specific)
        return .object(root)
    }

    /// Exactly what `supernotch-hook` writes to stdout (single line, no trailing newline).
    public var hookStdout: String { hookOutput.serialized() }
}

extension PermissionDecision: Codable {
    private enum CodingKeys: String, CodingKey { case behavior, updatedPermissions, message }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let behavior = try c.decode(String.self, forKey: .behavior)
        switch behavior {
        case "allow":
            if let updates = try c.decodeIfPresent([JSONValue].self, forKey: .updatedPermissions) {
                self = .allowAlways(updatedPermissions: updates)
            } else {
                self = .allow
            }
        case "deny":
            self = .deny(message: try c.decodeIfPresent(String.self, forKey: .message) ?? Self.defaultDenyMessage)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .behavior, in: c, debugDescription: "unknown behavior \(behavior)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allow:
            try c.encode("allow", forKey: .behavior)
        case .allowAlways(let updates):
            try c.encode("allow", forKey: .behavior)
            try c.encode(updates, forKey: .updatedPermissions)
        case .deny(let message):
            try c.encode("deny", forKey: .behavior)
            try c.encode(message, forKey: .message)
        }
    }
}
