// Owner: claude-core. Seed tests by the foundation; extend with one fixture per known bug (SPEC §G.1).
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
        let effects = store.apply(.hook(makeEnvelope(.userPromptSubmit, extra: [("prompt", "fix the login bug")])), now: t0)
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
            .hook(makeEnvelope(.permissionRequest, extra: [("tool_name", "Bash")], context: context, id: "r2")), now: t0)
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
            "rate_limits": ["five_hour": ["used_percentage": 82, "resets_at": 2_000_000], "seven_day": ["used_percentage": 12]]
        ]
        let envelope = HookEnvelope(
            id: "u", sentAt: 0, event: .statusLine, expectsReply: false, context: HookContext(), payload: payload)
        #expect(store.apply(.hook(envelope), now: t0) == [.usageUpdated])
        #expect(store.usage?.isWarning(threshold: 0.8) == true)
    }
}
