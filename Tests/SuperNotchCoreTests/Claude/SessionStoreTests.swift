// Owner: claude-core. Unit tests of the reducer; event sequences live in Fixtures/claude/seq-*.jsonl
// (SessionFixtureReplay.swift).
import Foundation
import Testing

@testable import SuperNotchCore

func makeEnvelope(
    _ event: HookEventName, session: String = "s1", extra: [(String, JSONValue)] = [],
    context: HookContext = HookContext(tty: "/dev/ttys001", termProgram: "iTerm.app"), id: String = UUID().uuidString
) -> HookEnvelope {
    var payload = JSONObject([
        ("session_id", .string(session)), ("cwd", "/Users/me/supernotch"), ("hook_event_name", .string(event.rawValue)),
        ("transcript_path", "/Users/me/.claude/projects/x/s1.jsonl"),
    ])
    for (key, value) in extra { payload[key] = value }
    return HookEnvelope(
        id: id, sentAt: 0, event: event, expectsReply: event.isBlocking, context: context, payload: .object(payload))
}

@Suite("SessionStore")
struct SessionStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func basicLifecycle() {
        var store = SessionStore()
        _ = store.apply(.hook(makeEnvelope(.sessionStart)), now: t0)
        #expect(store.visibleSessions.first?.phase == .idle)
        let effects = store.apply(
            .hook(makeEnvelope(.userPromptSubmit, extra: [("prompt", "fix the login bug")])), now: t0)
        #expect(effects.contains(.phaseChanged(sessionID: "s1", from: .idle, to: .working)))
        #expect(store.aggregateLight == .yellow)
        _ = store.apply(.hook(makeEnvelope(.stop, extra: [("last_assistant_message", "All done.")])), now: t0)
        #expect(store.sessions["s1"]?.phase == .done)
        #expect(store.sessions["s1"]?.lastAssistantPreview == "All done.")
        _ = store.apply(.hook(makeEnvelope(.sessionEnd)), now: t0)
        #expect(store.visibleSessions.isEmpty)
        #expect(store.aggregateLight == nil)
    }

    @Test func latePostToolUseAfterStopDoesNotRevive() {  // Vibe Notch #98
        var store = SessionStore()
        _ = store.apply(.hook(makeEnvelope(.userPromptSubmit, extra: [("prompt", "x")])), now: t0)
        _ = store.apply(.hook(makeEnvelope(.stop)), now: t0)
        _ = store.apply(.hook(makeEnvelope(.postToolUse, extra: [("tool_name", "Bash")])), now: t0)
        #expect(store.sessions["s1"]?.phase == .done)
    }

    @Test func permissionRequestAndResolutionByPostToolUse() {
        var store = SessionStore()
        _ = store.apply(.hook(makeEnvelope(.userPromptSubmit, extra: [("prompt", "x")])), now: t0)
        let input: JSONValue = ["command": "rm -rf build"]
        let request = makeEnvelope(.permissionRequest, extra: [("tool_name", "Bash"), ("tool_input", input)], id: "r1")
        let effects = store.apply(.hook(request), now: t0)
        #expect(effects.contains(.permissionAdded(requestID: "r1")))
        #expect(store.pendingPermissions.first?.danger.isDangerous == true)
        #expect(store.aggregateLight == .red)
        let resolved = store.apply(
            .hook(makeEnvelope(.postToolUse, extra: [("tool_name", "Bash"), ("tool_input", input)])), now: t0)
        #expect(resolved.contains(.replyPassthrough(requestID: "r1")))
        #expect(store.pendingPermissions.isEmpty)
        #expect(store.sessions["s1"]?.phase == .working)
    }

    @Test func internalSessionsAreHiddenAndPassThrough() {
        var store = SessionStore()
        let context = HookContext(isInternal: true)
        let effects = store.apply(
            .hook(makeEnvelope(.permissionRequest, extra: [("tool_name", "Bash")], context: context, id: "r2")), now: t0
        )
        #expect(effects.contains(.replyPassthrough(requestID: "r2")))
        #expect(store.visibleSessions.isEmpty)
    }

    @Test func desktopPrewarmHiddenUntilFirstPrompt() {
        var store = SessionStore()
        let desktop = HookContext(entrypoint: "claude-desktop", hostSessionID: "local_abc")
        _ = store.apply(.hook(makeEnvelope(.sessionStart, context: desktop)), now: t0)
        #expect(store.visibleSessions.isEmpty)
        let effects = store.apply(
            .hook(makeEnvelope(.userPromptSubmit, extra: [("prompt", "hi")], context: desktop)), now: t0)
        #expect(effects.contains(.sessionAppeared(sessionID: "s1")))
        #expect(store.visibleSessions.first?.host.kind == .claudeDesktop)
    }

    @Test func statusLineUpdatesUsage() {
        var store = SessionStore()
        let payload: JSONValue = [
            "rate_limits": [
                "five_hour": ["used_percentage": 82, "resets_at": 2_000_000], "seven_day": ["used_percentage": 12],
            ]
        ]
        let envelope = HookEnvelope(
            id: "u", sentAt: 0, event: .statusLine, expectsReply: false, context: HookContext(), payload: payload)
        #expect(store.apply(.hook(envelope), now: t0) == [.usageUpdated])
        #expect(store.usage?.isWarning(threshold: 0.8) == true)
    }

    @Test func restoringUsageAndSessions() throws {
        var store = SessionStore()
        let reset = t0.addingTimeInterval(3_600)
        store.restoreUsage(
            UsageLimits(fiveHour: UsageWindow(usedPercentage: 70, resetsAt: reset), sevenDay: nil, updatedAt: t0),
            now: t0)
        #expect(store.usage?.fiveHour?.usedPercentage == 70)
        store.restoreUsage(
            UsageLimits(fiveHour: UsageWindow(usedPercentage: 99, resetsAt: t0), sevenDay: nil, updatedAt: t0), now: t0)
        #expect(store.usage?.fiveHour?.usedPercentage == 70)  // an expired window never overrides
        store.restoreUsage(nil, now: t0)
        #expect(store.usage != nil)

        var persisted = Session(
            id: "p1", cwd: "/Users/me/app", pid: 77, phase: .done, pendingPermissionIDs: ["gone"], startedAt: t0)
        persisted.titleCandidates.generated = "Cached title"
        let data = try JSONEncoder().encode([persisted])
        let decoded = try JSONDecoder().decode([Session].self, from: data)
        #expect(decoded.first?.phase == .done)
        let effects = store.restoreSessions(decoded, now: t0)
        #expect(effects == [.sessionAppeared(sessionID: "p1")])
        #expect(store.sessions["p1"]?.pendingPermissionIDs == [])
        #expect(store.restoreSessions(decoded, now: t0).isEmpty)  // already known
        // A restored session behaves like any other: its next prompt makes it yellow, no Haiku call (cached).
        let next = store.apply(
            .hook(makeEnvelope(.userPromptSubmit, session: "p1", extra: [("prompt", "go on")])), now: t0)
        #expect(next.contains(.phaseChanged(sessionID: "p1", from: .done, to: .working)))
        #expect(store.sessions["p1"]?.displayTitle == "Cached title")
    }

    @Test func sessionDecodingIsTolerant() throws {
        let json = #"{"id":"x","startedAt":0,"phase":"needsInput.question","host":{"kind":"martian"},"future":1}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.phase == .needsInput(.question))
        #expect(session.host.kind == .unknown)
        #expect(session.cwd.isEmpty)
        #expect(SessionPhase(storageValue: "needsInput.bogus") == nil)
        for phase in [SessionPhase.idle, .working, .done, .needsInput(.permission), .needsInput(.other)] {
            #expect(SessionPhase(storageValue: phase.storageValue) == phase)
        }
    }

    @Test func answersForUnknownRequestsAreHarmless() {
        var store = SessionStore()
        #expect(store.apply(.permissionAnswered(requestID: "nope", decision: .allow), now: t0).isEmpty)
        #expect(store.apply(.permissionConnectionClosed(requestID: "nope"), now: t0).isEmpty)
        #expect(store.apply(.transcript(sessionID: "nope", TranscriptSignals(interrupted: true)), now: t0).isEmpty)
        #expect(store.apply(.titleGenerated(sessionID: "nope", title: "x"), now: t0).isEmpty)
        #expect(store.apply(.processExited(pid: 1), now: t0).isEmpty)
        #expect(store.apply(.tick, now: t0).isEmpty)
        // A blocking request without a session id is answered with passthrough right away.
        var payload = makeEnvelope(.permissionRequest, id: "r0")
        payload.payload = ["hook_event_name": "PermissionRequest"]
        #expect(store.apply(.hook(payload), now: t0) == [.replyPassthrough(requestID: "r0")])
    }

    @Test func pendingPermissionsOnlyForVisibleSessionsOldestFirst() {
        var store = SessionStore()
        let tool: [(String, JSONValue)] = [("tool_name", "Bash"), ("tool_input", ["command": "make"])]
        _ = store.apply(.hook(makeEnvelope(.permissionRequest, session: "b", extra: tool, id: "r2")), now: t0 + 2)
        _ = store.apply(.hook(makeEnvelope(.permissionRequest, session: "a", extra: tool, id: "r1")), now: t0 + 1)
        let desktop = HookContext(entrypoint: "claude-desktop", hostSessionID: "local_1")
        _ = store.apply(.hook(makeEnvelope(.sessionStart, session: "c", context: desktop)), now: t0)
        #expect(store.pendingPermissions.map(\.id) == ["r1", "r2"])
        #expect(store.aggregateLight == .red)
        #expect(store.visibleSessions.map(\.id) == ["b", "a"])  // same light: most recent phase change first
    }
}
