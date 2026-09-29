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
    /// When status == "waiting": "permission prompt" | "input needed" | "sandbox request" | ...
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

    /// Decodes the full stdout of `claude agents --json`. Tolerates unknown fields; skips malformed entries.
    public static func decodeList(_ data: Data) throws -> [AgentsListEntry] {
        let value = try JSONValue.parse(data)
        guard let array = value.arrayValue else { return [] }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        return array.compactMap { element in
            guard let bytes = try? encoder.encode(element) else { return nil }
            return try? decoder.decode(AgentsListEntry.self, from: bytes)
        }
    }
}
