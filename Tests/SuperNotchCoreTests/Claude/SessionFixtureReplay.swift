// Owner: claude-core. Replays JSONL event sequences from Fixtures/claude/seq-*.jsonl through SessionStore and
// checks the expectations written next to each step.
//
// Line format (one JSON object per line, `#`-prefixed and blank lines are ignored):
//   "t": seconds since the start of the sequence
//   one action:  "hook": {raw hook payload}   [+ "ctx": preset name | HookContext object, "id", "reply": Bool,
//                                               "pid": claude pid]
//                "answer": requestID, "decision": "allow" | "deny" | "always"
//                "closed": requestID            (hook connection closed)
//                "agents": [agents --json entries]
//                "exited": pid
//                "transcript": sessionID, "signals": {customTitle, aiTitle, summary, interrupted, interruptedAt(t)}
//                "title": sessionID, "text": generated title
//                "statusline": {statusLine payload}
//                "sessionEnded": sessionID      (synthetic removal)
//                "tick": true
//   "expect": {phase: {id: "working" | "needsInput.permission" | … | "absent"}, visible: [ids], pending: [ids],
//              effects: ["kind:args"], noEffects: [...], light: "red" | … | null, title: {id: text},
//              subagents: {id: n}, lastError: {id: text}, preview: {id: text}, host: {id: kind},
//              parked: [ids], stale: {id: bool}, background: {id: bool}, agentType: {requestID: text},
//              usage: {fiveHour: percent | null, sevenDay: percent | null}}
import Foundation
import Testing

@testable import SuperNotchCore

enum ClaudeFixtures {
    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/claude"),
            "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> JSONValue { try JSONValue.parse(try data(name, "json")) }

    static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    static func context(_ value: JSONValue?, pid: Int32?) throws -> HookContext {
        var context: HookContext
        switch value {
        case .object?:
            let bytes = Data((value ?? .null).serialized().utf8)
            context = try JSONDecoder().decode(HookContext.self, from: bytes)
        case .string(let preset)?:
            context = try #require(presets[preset], "unknown ctx preset \(preset)")
        default:
            context = presets["iterm"] ?? HookContext()
        }
        if let pid { context.claudePID = pid }
        return context
    }

    static let presets: [String: HookContext] = [
        "iterm": HookContext(
            hookVersion: "test", claudePID: 4242, claudeStartTime: 1_799_999_000, claudeExecutablePath: "/opt/claude",
            tty: "/dev/ttys004", termProgram: "iTerm.app", iTermSessionID: "w0t1p0:ABC",
            bundleIdentifier: "com.googlecode.iterm2", entrypoint: "cli"),
        "terminal": HookContext(
            hookVersion: "test", claudePID: 4343, tty: "/dev/ttys007", termProgram: "Apple_Terminal", entrypoint: "cli"),
        // Desktop drives the CLI with -p / stream-json: must still be visible.
        "desktop": HookContext(
            hookVersion: "test", claudePID: 5151, bundleIdentifier: "com.anthropic.claudefordesktop",
            entrypoint: "claude-desktop", hostSessionID: "local_1b2c3d", isPrintMode: true),
        "vscode": HookContext(
            hookVersion: "test", claudePID: 6161, bundleIdentifier: "com.microsoft.VSCode", entrypoint: "claude-vscode",
            isPrintMode: true),
        "print": HookContext(hookVersion: "test", claudePID: 7171, entrypoint: "cli", isPrintMode: true),
        "sdk": HookContext(hookVersion: "test", claudePID: 7272, entrypoint: "sdk-ts"),
        "cowork": HookContext(
            hookVersion: "test", claudePID: 7373, bundleIdentifier: "com.anthropic.claudefordesktop",
            entrypoint: "local-agent"),
        "internal": HookContext(
            hookVersion: "test", claudePID: 7474, entrypoint: "cli", isPrintMode: true, isInternal: true),
        "remote": HookContext(hookVersion: "test", isRemote: true),
    ]
}

struct SessionSequenceReplay {
    var store = SessionStore()
    let name: String

    init(name: String, configuration: SessionStoreConfiguration = .init()) {
        self.name = name
        store = SessionStore(configuration: configuration)
    }

    mutating func run() throws {
        let text = String(decoding: try ClaudeFixtures.data(name, "jsonl"), as: UTF8.self)
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let step = try JSONValue.parse(line)
            let now = ClaudeFixtures.origin.addingTimeInterval(step["t"]?.doubleValue ?? 0)
            let event = try Self.event(for: step, now: now)
            let effects = store.apply(event, now: now)
            if let expect = step["expect"] { check(expect, effects: effects, line: lineNumber) }
        }
    }

    static func event(for step: JSONValue, now: Date) throws -> SessionEvent {
        if let payload = step["hook"] {
            let eventName = HookEventName(payload["hook_event_name"]?.stringValue ?? "Unknown")
            let context = try ClaudeFixtures.context(step["ctx"], pid: step["pid"]?.intValue.map { Int32($0) })
            let id = step["id"]?.stringValue ?? UUID().uuidString
            let expectsReply = step["reply"]?.boolValue ?? eventName.isBlocking
            return .hook(
                HookEnvelope(
                    id: id, sentAt: now.timeIntervalSince1970, event: eventName, expectsReply: expectsReply,
                    context: context, payload: payload))
        }
        if let requestID = step["answer"]?.stringValue {
            let decision: PermissionDecision
            switch step["decision"]?.stringValue {
            case "deny": decision = .deny(message: "No")
            case "always": decision = .allowAlways(updatedPermissions: [])
            default: decision = .allow
            }
            return .permissionAnswered(requestID: requestID, decision: decision)
        }
        if let requestID = step["closed"]?.stringValue { return .permissionConnectionClosed(requestID: requestID) }
        if let entries = step["agents"] {
            return .agentsSnapshot(try AgentsListEntry.decodeList(Data(entries.serialized().utf8)))
        }
        if let pid = step["exited"]?.intValue { return .processExited(pid: Int32(pid)) }
        if let sessionID = step["transcript"]?.stringValue {
            let signals = step["signals"]
            return .transcript(
                sessionID: sessionID,
                TranscriptSignals(
                    customTitle: signals?["customTitle"]?.stringValue, aiTitle: signals?["aiTitle"]?.stringValue,
                    summary: signals?["summary"]?.stringValue, interrupted: signals?["interrupted"]?.boolValue ?? false,
                    interruptedAt: signals?["interruptedAt"]?.doubleValue.map {
                        ClaudeFixtures.origin.addingTimeInterval($0)
                    }))
        }
        if let sessionID = step["title"]?.stringValue {
            return .titleGenerated(sessionID: sessionID, title: step["text"]?.stringValue ?? "")
        }
        if let payload = step["statusline"] {
            return .hook(
                HookEnvelope(
                    id: UUID().uuidString, sentAt: now.timeIntervalSince1970, event: .statusLine, expectsReply: false,
                    context: HookContext(), payload: payload))
        }
        if let sessionID = step["sessionEnded"]?.stringValue { return .sessionEnded(sessionID: sessionID, now: now) }
        if step["tick"] != nil { return .tick }
        throw ReplayError(message: "unknown step \(step.serialized())")
    }

    struct ReplayError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    func check(_ expect: JSONValue, effects: [SessionEffect], line: Int) {
        let location = "\(name).jsonl:\(line)"
        let rendered = effects.map(Self.render)
        for (id, value) in expect["phase"]?.objectValue?.pairs ?? [] {
            let actual = store.sessions[id].map { Self.render($0.phase) } ?? "absent"
            #expect(actual == value.stringValue, "\(location) phase of \(id)")
        }
        if let visible = expect["visible"]?.arrayValue {
            #expect(store.visibleSessions.map(\.id) == visible.compactMap(\.stringValue), "\(location) visible")
        }
        if let pending = expect["pending"]?.arrayValue {
            #expect(store.pendingPermissions.map(\.id) == pending.compactMap(\.stringValue), "\(location) pending")
        }
        for effect in (expect["effects"]?.arrayValue ?? []).compactMap(\.stringValue) {
            #expect(rendered.contains(effect), "\(location) expected effect \(effect) in \(rendered)")
        }
        for effect in (expect["noEffects"]?.arrayValue ?? []).compactMap(\.stringValue) {
            #expect(!rendered.contains(effect), "\(location) unexpected effect \(effect) in \(rendered)")
        }
        if let light = expect["light"] {
            #expect(store.aggregateLight.map { "\($0)" } == light.stringValue, "\(location) aggregate light")
        }
        for (id, value) in expect["title"]?.objectValue?.pairs ?? [] {
            #expect(store.sessions[id]?.displayTitle == value.stringValue, "\(location) title of \(id)")
        }
        for (id, value) in expect["subagents"]?.objectValue?.pairs ?? [] {
            #expect(store.sessions[id]?.activeSubagents == value.intValue, "\(location) subagents of \(id)")
        }
        for (id, value) in expect["lastError"]?.objectValue?.pairs ?? [] {
            #expect(store.sessions[id]?.lastError == value.stringValue, "\(location) lastError of \(id)")
        }
        for (id, value) in expect["preview"]?.objectValue?.pairs ?? [] {
            #expect(store.sessions[id]?.lastAssistantPreview == value.stringValue, "\(location) preview of \(id)")
        }
        for (id, value) in expect["host"]?.objectValue?.pairs ?? [] {
            #expect(store.sessions[id]?.host.kind.rawValue == value.stringValue, "\(location) host of \(id)")
        }
        for (id, value) in expect["stale"]?.objectValue?.pairs ?? [] {
            #expect(store.sessions[id]?.isStale == value.boolValue, "\(location) stale of \(id)")
        }
        for (id, value) in expect["background"]?.objectValue?.pairs ?? [] {
            #expect(store.sessions[id]?.hasBackgroundWork == value.boolValue, "\(location) background of \(id)")
        }
        for (id, value) in expect["agentType"]?.objectValue?.pairs ?? [] {
            #expect(store.permissions[id]?.agentType == value.stringValue, "\(location) agentType of \(id)")
        }
        for (key, value) in expect["usage"]?.objectValue?.pairs ?? [] {
            let window = key == "fiveHour" ? store.usage?.fiveHour : store.usage?.sevenDay
            #expect(window?.usedPercentage == value.doubleValue, "\(location) usage \(key)")
        }
        if let parked = expect["parked"]?.arrayValue {
            let actual = store.sessions.keys.filter(store.isParked).sorted()
            #expect(actual == parked.compactMap(\.stringValue).sorted(), "\(location) parked")
        }
    }

    static func render(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .working: return "working"
        case .done: return "done"
        case .needsInput(let kind): return "needsInput.\(kind.rawValue)"
        }
    }

    static func render(_ effect: SessionEffect) -> String {
        switch effect {
        case .sessionAppeared(let id): return "sessionAppeared:\(id)"
        case .sessionRemoved(let id): return "sessionRemoved:\(id)"
        case .phaseChanged(let id, let from, let to): return "phaseChanged:\(id):\(render(from))>\(render(to))"
        case .permissionAdded(let id): return "permissionAdded:\(id)"
        case .permissionRemoved(let id): return "permissionRemoved:\(id)"
        case .replyPassthrough(let id): return "replyPassthrough:\(id)"
        case .titleGenerationNeeded(let id): return "titleGenerationNeeded:\(id)"
        case .transcriptRefreshNeeded(let id): return "transcriptRefreshNeeded:\(id)"
        case .usageUpdated: return "usageUpdated"
        }
    }
}

@Suite("Session sequences (fixtures)")
struct SessionSequenceFixtureTests {
    @Test(arguments: [
        "seq-permission-allow",
        "seq-permission-answered-elsewhere",
        "seq-late-posttooluse-98",
        "seq-interrupt",
        "seq-notifications",
        "seq-askuserquestion",
        "seq-subagents",
        "seq-desktop",
        "seq-visibility",
        "seq-agents",
        "seq-liveness",
        "seq-titles",
        "seq-usage",
    ])
    func replay(_ name: String) throws {
        var replay = SessionSequenceReplay(name: name)
        try replay.run()
    }
}
