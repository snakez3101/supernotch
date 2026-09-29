import Foundation

// CONTRACT FILE (SPEC §D.1). Owner: claude-core.
// One element of `claude agents --json [--all]` (agent-view.md "List sessions as JSON").
// Every field optional: the list mixes interactive and background sessions and fields appear conditionally.

public struct AgentsListEntry: Codable, Sendable, Hashable {
    public var cwd: String?
    /// "interactive" | "background"
    public var kind: String?
    /// Unix milliseconds.
    public var startedAt: Double?
    /// Short id (background sessions only).
    public var id: String?
    /// Background sessions: "working" | "blocked" | "done" | "failed" | "stopped"
    public var state: String?
    public var pid: Int32?
    /// While the process is alive: "busy" | "waiting" | "idle"
    public var status: String?
    /// When status == "waiting": "permission prompt" | "input needed" | "sandbox request" | "worker request" |
    /// "dialog open"
    public var waitingFor: String?
    /// Full session UUID (matches hook `session_id`).
    public var sessionId: String?
    public var name: String?

    public init(
        cwd: String? = nil, kind: String? = nil, startedAt: Double? = nil, id: String? = nil,
        state: String? = nil, pid: Int32? = nil, status: String? = nil, waitingFor: String? = nil,
        sessionId: String? = nil, name: String? = nil
    ) {
        self.cwd = cwd
        self.kind = kind
        self.startedAt = startedAt
        self.id = id
        self.state = state
        self.pid = pid
        self.status = status
        self.waitingFor = waitingFor
        self.sessionId = sessionId
        self.name = name
    }

    /// Tolerant field-by-field extraction: a mistyped field is dropped, not the whole entry.
    public init?(json: JSONValue) {
        guard case .object = json else { return nil }
        func text(_ key: String) -> String? {
            switch json[key] {
            case .string(let value)?: return value.isEmpty ? nil : value
            case .number(let value)?: return value.rounded() == value ? String(Int64(value)) : String(value)
            default: return nil
            }
        }
        func number(_ key: String) -> Double? {
            switch json[key] {
            case .number(let value)?: return value
            case .string(let value)?: return Double(value)
            default: return nil
            }
        }
        let pid = number("pid").flatMap { $0 > 0 && $0 <= Double(Int32.max) ? Int32($0) : nil }
        self.init(
            cwd: text("cwd"), kind: text("kind"), startedAt: number("startedAt"), id: text("id"),
            state: text("state")?.lowercased(), pid: pid, status: text("status")?.lowercased(),
            waitingFor: text("waitingFor"), sessionId: text("sessionId"), name: text("name"))
    }

    /// Decodes the full stdout of `claude agents --json`. Tolerates unknown fields, skips malformed entries,
    /// accepts a wrapper object (`{"sessions":[…]}`) and ignores text printed around the JSON array.
    /// Throws only when no JSON array can be found at all.
    public static func decodeList(_ data: Data) throws -> [AgentsListEntry] {
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            // Warnings or update notices around the array: try each "[" that starts a line, up to the last "]".
            guard let close = data.lastIndex(of: UInt8(ascii: "]")) else { throw error }
            var found: JSONValue?
            for open in data.indices where open < close && data[open] == UInt8(ascii: "[") {
                let lineStart = open == data.startIndex || data[data.index(before: open)] == 0x0A
                guard lineStart, let parsed = try? JSONValue.parse(data[open...close]) else { continue }
                found = parsed
                break
            }
            guard let found else { throw error }
            value = found
        }
        let array: [JSONValue]
        if let list = value.arrayValue {
            array = list
        } else if let list = value["sessions"]?.arrayValue ?? value["agents"]?.arrayValue {
            array = list
        } else {
            return []
        }
        return array.compactMap(AgentsListEntry.init(json:))
    }

    /// `startedAt` as a date (the field is Unix milliseconds).
    public var startedDate: Date? {
        guard let startedAt, startedAt > 0 else { return nil }
        return Date(timeIntervalSince1970: startedAt > 100_000_000_000 ? startedAt / 1000 : startedAt)
    }

    /// The needs-input kind for `status == "waiting"` / `state == "blocked"`; nil when the wait is not the
    /// session asking the user (e.g. the user opened a dialog themselves).
    public var needsInputKind: NeedsInputKind? {
        let waiting = waitingFor?.lowercased() ?? ""
        if waiting.contains("dialog") { return nil }
        if waiting.contains("permission") || waiting.contains("sandbox") { return .permission }
        if waiting.contains("input") || waiting.contains("question") { return .question }
        return .other
    }
}
