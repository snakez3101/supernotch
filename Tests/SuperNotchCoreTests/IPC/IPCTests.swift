// Owner: claude-core. Seed tests by the foundation (SPEC §D.7).
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("IPC")
struct IPCTests {
    @Test func envelopeRoundTripsThroughNDJSON() throws {
        let envelope = makeEnvelope(.permissionRequest, extra: [("tool_name", "Bash"), ("tool_input", ["command": "a\nb"])])
        let line = try NDJSON.encodeLine(envelope)
        #expect(line.filter { $0 == 0x0A }.count == 1)
        let decoded = try NDJSON.decodeLine(HookEnvelope.self, from: line)
        #expect(decoded.id == envelope.id)
        #expect(decoded.hook.toolInput?["command"]?.stringValue == "a\nb")
        #expect(decoded.expectsReply)
    }

    @Test func lineBufferSplitsChunks() throws {
        var buffer = NDJSONLineBuffer(maxLineBytes: 64)
        #expect(try buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
        #expect(try buffer.append(Data(":2}\n".utf8)).count == 1)
        #expect(throws: NDJSONLineBuffer.Failure.self) { try buffer.append(Data(repeating: 0x41, count: 100)) }
    }

    @Test func decisionStdout() throws {
        #expect(PermissionDecision.allow.hookStdout
            == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        let deny = PermissionDecision.deny(message: "nope")
        let reply = HookReply(id: "x", decision: deny)
        let decoded = try NDJSON.decodeLine(HookReply.self, from: try NDJSON.encodeLine(reply))
        #expect(decoded.decision == deny)
        #expect(try NDJSON.decodeLine(HookReply.self, from: Data(#"{"v":1,"id":"x","decision":null}"#.utf8)).decision == nil)
    }

    @Test func orderPreservingJSON() throws {
        let text = #"{"z":1,"a":{"y":[1,2.5,"s"],"b":null},"m":true}"#
        #expect(try JSONValue.parse(text).serialized() == text)
        #expect(throws: JSONParseError.self) { try JSONValue.parse(#"{"a":1,}"#) }
    }
}
