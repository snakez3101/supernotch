// Owner: claude-core. Wire format (SPEC §D.7): NDJSON framing, envelopes, replies, decision JSON, JSON parser,
// payload compaction, tolerant decoding.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("IPC")
struct IPCTests {
    @Test func envelopeRoundTripsThroughNDJSON() throws {
        let envelope = makeEnvelope(
            .permissionRequest, extra: [("tool_name", "Bash"), ("tool_input", ["command": "a\nb"])])
        let line = try NDJSON.encodeLine(envelope)
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(line.last == 0x0A)
        let decoded = try NDJSON.decodeLine(HookEnvelope.self, from: line)
        #expect(decoded == envelope)
        #expect(decoded.hook.toolInput?["command"]?.stringValue == "a\nb")
        #expect(decoded.expectsReply)
    }

    @Test func lineBufferSplitsChunks() throws {
        var buffer = NDJSONLineBuffer(maxLineBytes: 64)
        #expect(try buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
        #expect(try buffer.append(Data(":2}\n".utf8)).count == 1)
        #expect(try buffer.append(Data("\n\n".utf8)).isEmpty)
        #expect(try buffer.append(Data("{\"c\":3}".utf8)).isEmpty)
        #expect(buffer.remainder == Data("{\"c\":3}".utf8))
        #expect(throws: NDJSONLineBuffer.Failure.self) { try buffer.append(Data(repeating: 0x41, count: 100)) }
    }

    @Test func decisionStdoutMatchesHooksDocs() throws {
        #expect(
            PermissionDecision.allow.hookStdout
                == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        #expect(
            PermissionDecision.deny(message: "Denied from SuperNotch.").hookStdout
                == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from SuperNotch."}}}"#
        )
        #expect(
            PermissionDecision.allowAlways(updatedPermissions: []).hookStdout == PermissionDecision.allow.hookStdout)
        // Output is one line (Claude Code parses stdout that starts with { and ends with } as JSON).
        #expect(!PermissionDecision.deny(message: "a\nb").hookStdout.contains("\n"))
    }

    @Test func replyRoundTrips() throws {
        let rule: JSONValue = [
            "type": "addRules", "rules": [["toolName": "Bash"]], "behavior": "allow", "destination": "session",
        ]
        for decision in [PermissionDecision.allow, .deny(message: "nope"), .allowAlways(updatedPermissions: [rule])] {
            let reply = HookReply(id: "x", decision: decision)
            let decoded = try NDJSON.decodeLine(HookReply.self, from: try NDJSON.encodeLine(reply))
            #expect(decoded.decision == decision)
            #expect(decoded.id == "x")
        }
        #expect(
            try NDJSON.decodeLine(HookReply.self, from: Data(#"{"v":1,"id":"x","decision":null}"#.utf8)).decision == nil
        )
        #expect(try NDJSON.decodeLine(HookReply.self, from: Data(#"{"v":1,"id":"x"}"#.utf8)).decision == nil)
        #expect(
            try NDJSON.decodeLine(
                HookReply.self, from: Data("{\"v\":1,\"id\":\"x\",\"decision\":{\"behavior\":\"deny\"}}\r\n".utf8)
            ).decision
                == .deny(message: PermissionDecision.defaultDenyMessage))
        #expect(throws: (any Error).self) {
            try NDJSON.decodeLine(HookReply.self, from: Data(#"{"v":1,"id":"x","decision":{"behavior":"ask"}}"#.utf8))
        }
        // The hook's order-preserving parser.
        let line = Data(
            #"{"v":1,"id":"x","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":[],"behavior":"allow","destination":"session"}]}}"#
                .utf8)
        let parsed = try #require(HookReply.parse(line: line))
        #expect(parsed.id == "x")
        #expect(
            parsed.decision?.hookStdout.contains(
                #"[{"type":"addRules","rules":[],"behavior":"allow","destination":"session"}]"#) == true)
        #expect(HookReply.parse(line: Data(#"{"v":1,"id":"x","decision":{"behavior":"ask"}}"#.utf8))?.decision == nil)
        #expect(HookReply.parse(line: Data(#"{"v":1,"id":"x","decision":null}"#.utf8))?.decision == nil)
        #expect(HookReply.parse(line: Data("[]".utf8)) == nil)
        #expect(HookReply.parse(line: Data(#"{"decision":{"behavior":"allow"}}"#.utf8)) == nil)
    }

    @Test func orderPreservingJSON() throws {
        let text = #"{"z":1,"a":{"y":[1,2.5,"s"],"b":null},"m":true}"#
        #expect(try JSONValue.parse(text).serialized() == text)
        #expect(throws: JSONParseError.self) { try JSONValue.parse(#"{"a":1,}"#) }
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{} x") }
        #expect(throws: JSONParseError.self) { try JSONValue.parse(String(repeating: "[", count: 600)) }
        #expect(try JSONValue.parse("\u{FEFF}{\"a\":\"\\u00e9\\ud83d\\ude00\\n\"}")["a"]?.stringValue == "é😀\n")
        #expect(try JSONValue.parse(#"{"n":-1.5e3}"#)["n"]?.doubleValue == -1500)
        #expect(JSONValue.string("\u{01}\"\\").serialized() == #""\u0001\"\\""#)
    }

    @Test func compactorDropsToolResponseAndTruncatesDeterministically() {
        let big = String(repeating: "é", count: 20_000)  // 40 000 bytes
        let payload: JSONValue = [
            "session_id": "s", "tool_name": "Write", "tool_input": ["file_path": "/a", "content": .string(big)],
            "tool_response": ["filePath": "/a", "content": .string(big)],
        ]
        let compact = HookPayloadCompactor.compact(payload)
        #expect(compact["tool_response"] == nil)
        let content = compact["tool_input"]?["content"]?.stringValue ?? ""
        #expect(content.hasSuffix(HookPayloadCompactor.truncationMarker))
        #expect(
            content.utf8.count <= IPCConfig.maxPayloadStringBytes + HookPayloadCompactor.truncationMarker.utf8.count)
        #expect(HookPayloadCompactor.compact(payload) == compact)
        #expect(compact.objectValue?.keys == ["session_id", "tool_name", "tool_input"])
        let small: JSONValue = ["a": ["b", 1, true, nil]]
        #expect(HookPayloadCompactor.compact(small) == small)
    }

    @Test func contextDecodingIsFieldTolerant() throws {
        let json =
            #"{"hookVersion":"0.0.1","claudePID":"not a number","tty":"/dev/ttys001","isPrintMode":1,"future":{"x":1},"processChain":[{"pid":2,"name":"zsh"}]}"#
        let context = try JSONDecoder().decode(HookContext.self, from: Data(json.utf8))
        #expect(context.claudePID == nil)
        #expect(context.tty == "/dev/ttys001")
        #expect(!context.isPrintMode)
        #expect(context.processChain == [HookProcessEntry(pid: 2, name: "zsh")])
        #expect(try JSONDecoder().decode(HookContext.self, from: Data("{}".utf8)) == HookContext(hookVersion: "0"))
        // An envelope from an older hook (no newer context keys) still decodes.
        let old =
            #"{"v":1,"id":"e1","sentAt":1,"event":"Stop","expectsReply":false,"context":{"hookVersion":"0.1.0"},"payload":{"session_id":"s"}}"#
        #expect(try NDJSON.decodeLine(HookEnvelope.self, from: Data(old.utf8)).hook.sessionID == "s")
    }

    @Test func payloadAccessors() {
        let hook = HookPayload([
            "session_id": "", "tool_name": "Bash", "background_tasks": [["type": "shell"], ["type": "subagent"]],
            "stop_hook_active": true, "is_interrupt": true, "notification_type": "idle_prompt",
        ])
        #expect(hook.sessionID == nil)  // empty strings are missing values
        #expect(hook.backgroundTaskCount == 2)
        #expect(hook.hasBackgroundSubagents)
        #expect(hook.stopHookActive)
        #expect(hook.isInterrupt)
        #expect(HookPayload(["background_tasks": []]).backgroundTasks == [])
        #expect(HookPayload([:]).backgroundTasks == nil)
        #expect(NotificationType.needsInputKind(for: "permission_prompt") == .permission)
        #expect(NotificationType.needsInputKind(for: "elicitation_url_dialog") == .question)
        #expect(NotificationType.needsInputKind(for: "agent_needs_input") == nil)
        #expect(!NotificationType.needsInput.contains(NotificationType.agentNeedsInput))
    }

    @Test func syntheticEnvelopes() {
        guard case .hook(let envelope) = SessionEvent.sessionEnded(sessionID: "s", now: Date(timeIntervalSince1970: 5))
        else {
            Issue.record("expected a hook event")
            return
        }
        #expect(envelope.event == .sessionEnd)
        #expect(!envelope.expectsReply)
        #expect(envelope.id.hasPrefix(SessionStore.syntheticPrefix))
        #expect(envelope.hook.sessionID == "s")
        #expect(envelope.sentDate == Date(timeIntervalSince1970: 5))
    }

    @Test func eventNames() throws {
        #expect(HookEventName("SomethingNew").rawValue == "SomethingNew")
        #expect(try JSONDecoder().decode(HookEventName.self, from: Data(#""Stop""#.utf8)) == .stop)
        #expect(HookEventName.permissionRequest.isBlocking)
        #expect(!HookEventName.stop.supportsMatcher)
        #expect(HookEventName.baseEvents.allSatisfy { !HookEventName.extendedEvents.contains($0) })
        #expect(HookEventName.statusLine.minimumVersion == nil)
    }
}
