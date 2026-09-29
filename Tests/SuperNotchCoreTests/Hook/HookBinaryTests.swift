// Owner: claude-core. Runs the built `supernotch-hook` binary end to end (SPEC §D.7, §G.1 "hook fail-open").
// The binary sits next to the test resource bundle in the build products folder; tests are skipped if it was
// not built.
import Foundation
import Testing

@testable import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum HookBinary {
    static let url: URL? = {
        let candidate = Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("supernotch-hook")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }()

    struct Result {
        var status: Int32
        var stdout: String
        var seconds: TimeInterval
    }

    static func run(_ arguments: [String], stdin: String, environment: [String: String]) throws -> Result {
        let executable: URL = try #require(url)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self),
            seconds: Date().timeIntervalSince(started))
    }

    /// A private scratch folder with a short path (sun_path is 104 bytes on macOS).
    static func scratch() throws -> String {
        let path = "/tmp/snh-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Clean environment: the test runner itself may run inside Claude Code (CLAUDE_CODE_REMOTE etc.).
    static func environment(home: String, socket: String, extra: [String: String] = [:]) -> [String: String] {
        var environment = ["HOME": home, "PATH": "/usr/bin:/bin", IPCConfig.socketPathEnvironmentKey: socket]
        environment[IPCConfig.replyTimeoutEnvironmentKey] = "2"
        for (key, value) in extra { environment[key] = value }
        return environment
    }
}

/// One-connection Unix socket server playing the app's side of the protocol.
final class TestHookServer: @unchecked Sendable {
    enum Reply: Sendable {
        case none  // keep the connection open until the hook gives up
        case close  // close without answering (EOF)
        case line(String)  // raw reply line
        case decision(PermissionDecision?)  // proper HookReply for the received envelope
    }

    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var envelope: HookEnvelope?
    private let finished = DispatchSemaphore(value: 0)

    init(path: String) throws {
        self.path = path
        unlink(path)
        #if canImport(Darwin)
            let type = SOCK_STREAM
        #else
            let type = Int32(SOCK_STREAM.rawValue)
        #endif
        listener = socket(AF_UNIX, type, 0)
        try #require(listener >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 4) == 0)
        chmod(path, 0o600)
    }

    deinit {
        _ = closeDescriptor(listener)
        unlink(path)
    }

    /// Accepts one connection in the background, records the envelope and answers with `reply`.
    func serveOnce(_ reply: Reply, acceptTimeoutMilliseconds: Int32 = 8_000) {
        DispatchQueue.global().async { [self] in
            defer { finished.signal() }
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, acceptTimeoutMilliseconds) > 0 else { return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { _ = closeDescriptor(client) }
            var buffer = NDJSONLineBuffer()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            var line: Data?
            while line == nil {
                let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
                guard count > 0 else { return }
                line = (try? buffer.append(Data(chunk[0..<count])))?.first
            }
            guard let line, let envelope = try? NDJSON.decodeLine(HookEnvelope.self, from: line) else { return }
            lock.withLock { self.envelope = envelope }
            let text: String?
            switch reply {
            case .none:
                // Wait for the hook to hang up (EOF) so we can check it gave up on its own.
                while chunk.withUnsafeMutableBytes({ recv(client, $0.baseAddress, $0.count, 0) }) > 0 {}
                text = nil
            case .close:
                text = nil
            case .line(let raw):
                text = raw
            case .decision(let decision):
                text = (try? NDJSON.encodeLine(HookReply(id: envelope.id, decision: decision))).map {
                    String(decoding: $0, as: UTF8.self)
                }
            }
            if let text {
                let bytes = Array(text.utf8)
                _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            }
        }
    }

    /// The envelope received by `serveOnce` (waits up to 10 s for the server thread to finish).
    func received() -> HookEnvelope? {
        _ = finished.wait(timeout: .now() + 10)
        return lock.withLock { envelope }
    }

    private func closeDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
            return Darwin.close(fd)
        #else
            return Glibc.close(fd)
        #endif
    }
}

@Suite("supernotch-hook binary", .enabled(if: HookBinary.url != nil, "supernotch-hook was not built"))
struct HookBinaryTests {
    static let permissionPayload =
        #"{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"permission_suggestions":[]}"#

    @Test func failsOpenWithoutTheApp() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let result = try HookBinary.run(
            ["hook"], stdin: Self.permissionPayload,
            environment: HookBinary.environment(home: home, socket: home + "/missing.sock"))
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.seconds < 3)
    }

    @Test func failsOpenOnGarbageAndEmptyInput() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = try TestHookServer(path: home + "/h.sock")
        for input in ["", "not json", "[1,2]", #"{"hook_event_name":"Stop"}"#] {
            let result = try HookBinary.run(
                ["hook"], stdin: input, environment: HookBinary.environment(home: home, socket: server.path))
            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
        }
    }

    @Test(arguments: [
        PermissionDecision.allow, .deny(message: "Blocked from the notch"),
        .allowAlways(updatedPermissions: [
            [
                "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "rm -rf build"]], "behavior": "allow",
                "destination": "localSettings",
            ]
        ]),
    ])
    func printsTheAppsDecision(_ decision: PermissionDecision) throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = try TestHookServer(path: home + "/h.sock")
        server.serveOnce(.decision(decision))
        let payload = Self.permissionPayload.replacingOccurrences(
            of: #""permission_suggestions":[]"#, with: #""tool_response":{"stdout":"huge"},"permission_suggestions":[]"#
        )
        let result = try HookBinary.run(
            ["hook"], stdin: payload, environment: HookBinary.environment(home: home, socket: server.path))
        #expect(result.status == 0)
        #expect(result.stdout == decision.hookStdout)
        let envelope = try #require(server.received())
        #expect(envelope.event == .permissionRequest)
        #expect(envelope.expectsReply)
        #expect(envelope.hook.sessionID == "s1")
        #expect(envelope.payload["tool_response"] == nil)
        #expect(envelope.context.hookVersion != "0")
    }

    @Test(arguments: ["null", "close", "wrongID", "garbage"])
    func passthroughPrintsNothing(_ mode: String) throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = try TestHookServer(path: home + "/h.sock")
        switch mode {
        case "null": server.serveOnce(.decision(nil))
        case "close": server.serveOnce(.close)
        case "wrongID": server.serveOnce(.line(#"{"v":1,"id":"other","decision":{"behavior":"allow"}}"# + "\n"))
        default: server.serveOnce(.line("{nonsense\n"))
        }
        let result = try HookBinary.run(
            ["hook"], stdin: Self.permissionPayload,
            environment: HookBinary.environment(home: home, socket: server.path))
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(server.received() != nil)
    }

    @Test func givesUpAfterTheReplyTimeout() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = try TestHookServer(path: home + "/h.sock")
        server.serveOnce(.none)
        let result = try HookBinary.run(
            ["hook"], stdin: Self.permissionPayload,
            environment: HookBinary.environment(
                home: home, socket: server.path, extra: [IPCConfig.replyTimeoutEnvironmentKey: "0.5"]))
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.seconds >= 0.4)
        #expect(result.seconds < 5)
    }

    @Test func nonBlockingEventsAndQuestionsDoNotWait() throws {
        for payload in [
            #"{"session_id":"s1","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"t1"}"#,
            #"{"session_id":"s1","cwd":"/tmp","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#,
        ] {
            let home = try HookBinary.scratch()
            defer { try? FileManager.default.removeItem(atPath: home) }
            let server = try TestHookServer(path: home + "/h.sock")
            server.serveOnce(.none)
            let result = try HookBinary.run(
                ["hook"], stdin: payload,
                environment: HookBinary.environment(
                    home: home, socket: server.path, extra: [IPCConfig.replyTimeoutEnvironmentKey: "5"]))
            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
            #expect(result.seconds < 3)
            let envelope = try #require(server.received())
            #expect(!envelope.expectsReply)
        }
    }

    @Test(arguments: [(IPCConfig.internalMarkerEnvironmentKey, "1"), ("CLAUDE_CODE_REMOTE", "true")])
    func ourOwnAndRemoteSessionsAreNotReported(_ key: String, _ value: String) throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = try TestHookServer(path: home + "/h.sock")
        server.serveOnce(.decision(.allow), acceptTimeoutMilliseconds: 1_500)
        let result = try HookBinary.run(
            ["hook"], stdin: Self.permissionPayload,
            environment: HookBinary.environment(home: home, socket: server.path, extra: [key: value]))
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        // Nothing connected: the server gives up after its own accept timeout.
        #expect(server.received() == nil)
    }

    @Test func statusLineForwardsAndRunsTheWrappedCommand() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = try TestHookServer(path: home + "/h.sock")
        server.serveOnce(.close)
        let json = String(decoding: try ClaudeFixtures.data("statusline", "json"), as: UTF8.self)
        let result = try HookBinary.run(
            ["statusline", IPCConfig.statusLineWrapArgument, "cat; printf ' [%s]' \"$COLUMNS\""], stdin: json,
            environment: HookBinary.environment(home: home, socket: server.path, extra: ["COLUMNS": "120"]))
        #expect(result.status == 0)
        #expect(result.stdout == json + " [120]")
        let envelope = try #require(server.received())
        #expect(envelope.event == .statusLine)
        #expect(!envelope.expectsReply)
        #expect(UsageLimits.fromStatusLine(envelope.payload, now: Date())?.fiveHour?.usedPercentage == 82.5)
    }

    @Test func statusLineWithoutOriginalPrintsADefaultLine() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let json = String(decoding: try ClaudeFixtures.data("statusline", "json"), as: UTF8.self)
        let result = try HookBinary.run(
            ["statusline"], stdin: json, environment: HookBinary.environment(home: home, socket: home + "/none.sock"))
        #expect(result.status == 0)
        #expect(result.stdout == "Opus 5 · 42% context\n")
        // Never wraps itself (Open Island #671).
        let looped = try HookBinary.run(
            ["statusline", "--wrap", "'/x/SuperNotch/bin/supernotch-hook' statusline"], stdin: json,
            environment: HookBinary.environment(home: home, socket: home + "/none.sock"))
        #expect(looped.stdout == "Opus 5 · 42% context\n")
    }

    @Test func statusLineHandlesLargeInput() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let big = #"{"pad":""# + String(repeating: "x", count: 300_000) + #""}"#
        let result = try HookBinary.run(
            ["statusline", "--wrap", "wc -c | tr -d ' '"], stdin: big,
            environment: HookBinary.environment(home: home, socket: home + "/none.sock"))
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == String(big.utf8.count))
    }

    @Test func version() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let result = try HookBinary.run(
            ["--version"], stdin: "", environment: HookBinary.environment(home: home, socket: ""))
        #expect(result.status == 0)
        #expect(result.stdout.hasPrefix("0."))
    }
}
