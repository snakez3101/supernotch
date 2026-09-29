// Owner: claude-core. Runs the built `supernotch-hook` binary end to end (SPEC §D.7, §G.1 "hook fail-open").
// The binary sits next to the test resource bundle in the build products folder; tests are skipped if it was
// not built.
//
// The harness only uses blocking system calls on threads it owns (posix_spawn + poll/read/waitpid, and a plain
// `Thread` for the socket server), never Foundation's `Process`/run loop or a GCD queue. swift-testing runs the
// tests on the Swift concurrency pool (one thread per CPU, 3 on the macOS runner); while those threads sit in a
// blocking test, work queued on GCD or delivered through a run loop can wait for many seconds. On macOS that
// delayed the test server past the hook's reply timeout, so every socket test failed and the whole run stalled.
// Every hook runs with SUPERNOTCH_HOOK_DEBUG=1: its stderr (why it failed open) and the server's own log are part
// of each failure message.
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

    struct Result: CustomStringConvertible {
        /// Exit status, or the signal number when `signal` is set (like `Process.terminationStatus`).
        var status: Int32
        var signal: Int32?
        var stdout: String
        var stderr: String
        var seconds: TimeInterval
        var killedByWatchdog = false

        var description: String {
            var text = signal.map { "hook killed by signal \($0)" } ?? "hook exited with \(status)"
            text += String(format: " after %.2f s", seconds)
            if killedByWatchdog { text += " (killed by the test watchdog)" }
            text += "; stdout: " + (stdout.isEmpty ? "<empty>" : String(reflecting: String(stdout.prefix(300))))
            text += "\nhook stderr:\n" + (stderr.isEmpty ? "<empty>" : stderr)
            return text
        }
    }

    struct SpawnError: Error, CustomStringConvertible {
        var step: String
        var code: Int32
        var description: String { "\(step) failed: errno \(code) (\(String(cString: strerror(code))))" }
    }

    /// A hook still running after this long is killed: a hang must fail its test, not stall the whole run.
    static let watchdogSeconds: TimeInterval = 30

    /// Serializes pipe creation + spawn, so no child ever inherits another test's pipe ends (Linux has no
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, and Glibc's `pipe2` is not visible from Swift).
    private static let spawnLock = NSLock()

    /// Writing stdin to a hook that already exited must fail with EPIPE, not kill the test process.
    private static let ignoreSIGPIPE: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

    static func run(_ arguments: [String], stdin: String, environment: [String: String]) throws -> Result {
        let executable: URL = try #require(url)
        _ = ignoreSIGPIPE
        let errorPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("snh-stderr-" + UUID().uuidString).path
        defer { unlink(errorPath) }

        let started = Date()
        let (child, input, output) = try spawn(
            executable.path, arguments: [executable.path] + arguments,
            environment: environment.map { "\($0.key)=\($0.value)" }, stderrPath: errorPath)

        // Feed stdin from its own thread: a big input must not block us while the hook writes its output.
        let bytes = Array(stdin.utf8)
        let fed = DispatchSemaphore(value: 0)
        let feeder = Thread {
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Sys.write(input, $0.baseAddress, $0.count) }
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    break  // EPIPE: the hook stopped reading (e.g. `--version`)
                }
            }
            _ = Sys.close(input)
            fed.signal()
        }
        feeder.start()

        // Read stdout to EOF; after the watchdog fires, give the killed process tree a few seconds to let go.
        var collected: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var killed = false
        while true {
            let elapsed = Date().timeIntervalSince(started)
            if !killed && elapsed > watchdogSeconds {
                kill(child, SIGKILL)
                killed = true
            }
            if killed && elapsed > watchdogSeconds + 5 { break }
            var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 && errno != EINTR { break }
            if ready <= 0 { continue }
            let count = chunk.withUnsafeMutableBytes { Sys.read(output, $0.baseAddress, $0.count) }
            if count > 0 {
                collected.append(contentsOf: chunk[0..<count])
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                break  // EOF
            }
        }
        _ = Sys.close(output)

        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        let seconds = Date().timeIntervalSince(started)
        _ = fed.wait(timeout: .now() + 5)

        // waitpid status: low 7 bits = terminating signal (0 = exited normally), bits 8-15 = exit code.
        let terminatingSignal = status & 0x7f
        let stderr = (try? String(contentsOfFile: errorPath, encoding: .utf8)) ?? ""
        return Result(
            status: terminatingSignal == 0 ? (status >> 8) & 0xff : terminatingSignal,
            signal: terminatingSignal == 0 ? nil : terminatingSignal,
            stdout: String(decoding: collected, as: UTF8.self), stderr: stderr, seconds: seconds,
            killedByWatchdog: killed)
    }

    /// Starts `path` with a stdin pipe, a stdout pipe and stderr redirected to `stderrPath`, with default signal
    /// dispositions (as under Claude Code). Returns the pid and our ends of the pipes.
    private static func spawn(_ path: String, arguments: [String], environment: [String], stderrPath: String) throws
        -> (pid: pid_t, stdinWrite: Int32, stdoutRead: Int32)
    {
        spawnLock.lock()
        defer { spawnLock.unlock() }
        let input = try makePipe()
        let output = try makePipe()
        #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
        #else
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input.read, 0)
        posix_spawn_file_actions_adddup2(&actions, output.write, 1)
        posix_spawn_file_actions_addopen(&actions, 2, stderrPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var flags = Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF)
        #if canImport(Darwin)
            flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)  // only 0, 1 and 2 reach the child
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var pid: pid_t = 0
        let result: Int32 =
            withCStrings(arguments) { argv -> Int32 in
                withCStrings(environment) { envp in posix_spawn(&pid, path, &actions, &attributes, argv, envp) }
                    ?? EINVAL
            } ?? EINVAL
        _ = Sys.close(input.read)
        _ = Sys.close(output.write)
        guard result == 0 else {
            _ = Sys.close(input.write)
            _ = Sys.close(output.read)
            throw SpawnError(step: "posix_spawn \(path)", code: result)
        }
        return (pid, input.write, output.read)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SpawnError(step: "pipe", code: errno) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    /// NULL-terminated C string array valid for the duration of `body`.
    private static func withCStrings<Value>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Value
    ) -> Value? {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeBufferPointer { buffer in buffer.baseAddress.map(body) }
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
        environment[IPCConfig.hookDebugEnvironmentKey] = "1"  // stderr says why the hook failed open
        for (key, value) in extra { environment[key] = value }
        return environment
    }
}

/// libc calls whose names clash with members or need a module prefix.
enum Sys {
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
            return Darwin.close(fd)
        #else
            return Glibc.close(fd)
        #endif
    }

    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
            return Darwin.read(fd, buffer, count)
        #else
            return Glibc.read(fd, buffer, count)
        #endif
    }

    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
            return Darwin.write(fd, buffer, count)
        #else
            return Glibc.write(fd, buffer, count)
        #endif
    }
}

/// One-connection Unix socket server playing the app's side of the protocol, on its own thread.
final class TestHookServer: @unchecked Sendable, CustomStringConvertible {
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
    private var log: [String] = []
    private let created = Date()
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
        #if canImport(Darwin)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        try #require(bound == 0, "bind(\(path)) failed: errno \(errno)")
        try #require(listen(listener, 4) == 0)
        chmod(path, 0o600)
    }

    deinit {
        _ = Sys.close(listener)
        unlink(path)
    }

    /// What the server thread did, with timestamps (part of every failure message).
    var description: String {
        lock.withLock { "server log: " + (log.isEmpty ? "<nothing yet>" : log.joined(separator: "; ")) }
    }

    private func note(_ event: String) {
        let stamp = String(format: "%.3f s ", Date().timeIntervalSince(created))
        lock.withLock { log.append(stamp + event) }
    }

    /// Accepts one connection on a dedicated thread, records the envelope and answers with `reply`.
    func serveOnce(_ reply: Reply, acceptTimeoutMilliseconds: Int32 = 8_000) {
        let thread = Thread { [self] in
            serve(reply, acceptTimeoutMilliseconds: acceptTimeoutMilliseconds)
            finished.signal()
        }
        thread.start()
    }

    /// The envelope received by `serveOnce` (waits up to 10 s for the server thread to finish).
    func received() -> HookEnvelope? {
        if finished.wait(timeout: .now() + 10) == .timedOut { note("still busy after 10 s") }
        return lock.withLock { envelope }
    }

    private func serve(_ reply: Reply, acceptTimeoutMilliseconds: Int32) {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        var ready = poll(&descriptor, 1, acceptTimeoutMilliseconds)
        while ready < 0 && errno == EINTR { ready = poll(&descriptor, 1, acceptTimeoutMilliseconds) }
        guard ready > 0 else {
            note("no connection within \(acceptTimeoutMilliseconds) ms")
            return
        }
        let client = accept(listener, nil, nil)
        guard client >= 0 else {
            note("accept failed: errno \(errno)")
            return
        }
        defer { _ = Sys.close(client) }
        note("accepted a connection")
        #if canImport(Darwin)
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let sendFlags: Int32 = 0
        #else
            let sendFlags = Int32(MSG_NOSIGNAL)
        #endif
        var buffer = NDJSONLineBuffer()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var line: Data?
        var total = 0
        while line == nil {
            let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                note("connection ended after \(total) bytes without a complete line")
                return
            }
            total += count
            do {
                line = try buffer.append(Data(chunk[0..<count])).first
            } catch {
                note("line buffer: \(error)")
                return
            }
        }
        guard let line else { return }
        let envelope: HookEnvelope
        do {
            envelope = try NDJSON.decodeLine(HookEnvelope.self, from: line)
        } catch {
            note("cannot decode the envelope (\(line.count) bytes): \(error)")
            return
        }
        lock.withLock { self.envelope = envelope }
        note("received \(envelope.event) \(envelope.id) (expectsReply: \(envelope.expectsReply))")
        let text: String?
        switch reply {
        case .none:
            // Wait for the hook to hang up (EOF) so we can check it gave up on its own.
            while true {
                let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
                if count > 0 || (count < 0 && errno == EINTR) { continue }
                break
            }
            note("the hook hung up")
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
            let sent = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, sendFlags) }
            note(sent == bytes.count ? "replied (\(sent) bytes)" : "reply failed: \(sent), errno \(errno)")
        }
    }
}

// Serialized: the timing expectations (fail open in < 3 s, reply timeouts) should measure the hook, not a 3-CPU
// runner juggling several hook processes at once.
@Suite(
    "supernotch-hook binary", .serialized, .enabled(if: HookBinary.url != nil, "supernotch-hook was not built"))
struct HookBinaryTests {
    static let permissionPayload =
        #"{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"permission_suggestions":[]}"#

    @Test func failsOpenWithoutTheApp() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let result = try HookBinary.run(
            ["hook"], stdin: Self.permissionPayload,
            environment: HookBinary.environment(home: home, socket: home + "/missing.sock"))
        #expect(result.status == 0, "\(result)")
        #expect(result.stdout.isEmpty, "\(result)")
        #expect(result.seconds < 3, "\(result)")
    }

    @Test func failsOpenOnGarbageAndEmptyInput() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = try TestHookServer(path: home + "/h.sock")
        for input in ["", "not json", "[1,2]", #"{"hook_event_name":"Stop"}"#] {
            let result = try HookBinary.run(
                ["hook"], stdin: input, environment: HookBinary.environment(home: home, socket: server.path))
            #expect(result.status == 0, "\(result)\n\(server)")
            #expect(result.stdout.isEmpty, "\(result)\n\(server)")
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
        #expect(result.status == 0, "\(result)\n\(server)")
        #expect(result.stdout == decision.hookStdout, "\(result)\n\(server)")
        let envelope = try #require(server.received(), "\(result)\n\(server)")
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
        #expect(result.status == 0, "\(result)\n\(server)")
        #expect(result.stdout.isEmpty, "\(result)\n\(server)")
        #expect(server.received() != nil, "\(result)\n\(server)")
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
        #expect(result.status == 0, "\(result)\n\(server)")
        #expect(result.stdout.isEmpty, "\(result)\n\(server)")
        #expect(result.seconds >= 0.4, "\(result)\n\(server)")
        #expect(result.seconds < 5, "\(result)\n\(server)")
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
            #expect(result.status == 0, "\(result)\n\(server)")
            #expect(result.stdout.isEmpty, "\(result)\n\(server)")
            #expect(result.seconds < 3, "\(result)\n\(server)")
            let envelope = try #require(server.received(), "\(result)\n\(server)")
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
        #expect(result.status == 0, "\(result)\n\(server)")
        #expect(result.stdout.isEmpty, "\(result)\n\(server)")
        // Nothing connected: the server gives up after its own accept timeout.
        #expect(server.received() == nil, "\(result)\n\(server)")
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
        #expect(result.status == 0, "\(result)\n\(server)")
        #expect(result.stdout == json + " [120]", "\(result)\n\(server)")
        let envelope = try #require(server.received(), "\(result)\n\(server)")
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
        #expect(result.status == 0, "\(result)")
        #expect(result.stdout == "Opus 5 · 42% context\n", "\(result)")
        // Never wraps itself (Open Island #671).
        let looped = try HookBinary.run(
            ["statusline", "--wrap", "'/x/SuperNotch/bin/supernotch-hook' statusline"], stdin: json,
            environment: HookBinary.environment(home: home, socket: home + "/none.sock"))
        #expect(looped.stdout == "Opus 5 · 42% context\n", "\(looped)")
    }

    @Test func statusLineHandlesLargeInput() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let big = #"{"pad":""# + String(repeating: "x", count: 300_000) + #""}"#
        let result = try HookBinary.run(
            ["statusline", "--wrap", "wc -c | tr -d ' '"], stdin: big,
            environment: HookBinary.environment(home: home, socket: home + "/none.sock"))
        #expect(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == String(big.utf8.count), "\(result)")
    }

    /// The wrapped command's exit status and stdout must reach Claude Code unchanged, for small input (exec path) and
    /// for input larger than the pipe buffer (spawn-and-feed path).
    @Test(arguments: [0, 1, 7, 64], [10, 300_000])
    func statusLinePassesThroughTheWrappedExitStatus(_ code: Int32, _ size: Int) throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let input = #"{"pad":""# + String(repeating: "x", count: size) + #""}"#
        let result = try HookBinary.run(
            ["statusline", "--wrap", "wc -c | tr -d ' '; printf 'done'; exit \(code)"], stdin: input,
            environment: HookBinary.environment(home: home, socket: home + "/none.sock"))
        #expect(result.status == code, "\(result)")
        #expect(result.stdout == "\(input.utf8.count)\ndone", "\(result)")
    }

    @Test func statusLineReportsASignalKilledCommandLikeAShell() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let big = #"{"pad":""# + String(repeating: "x", count: 300_000) + #""}"#
        let result = try HookBinary.run(
            ["statusline", "--wrap", "cat >/dev/null; kill -TERM $$"], stdin: big,
            environment: HookBinary.environment(home: home, socket: home + "/none.sock"))
        #expect(result.status == 128 + SIGTERM, "\(result)")
    }

    /// The wrapped command starts with the default SIGPIPE action, as it would under Claude Code: the hook ignores
    /// SIGPIPE for its own writes, and an ignored signal would otherwise stay ignored across exec.
    @Test(arguments: [10, 300_000])
    func statusLineRunsTheWrappedCommandWithTheDefaultSIGPIPE(_ size: Int) throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let input = #"{"pad":""# + String(repeating: "x", count: size) + #""}"#
        let result = try HookBinary.run(
            ["statusline", "--wrap", "cat >/dev/null; kill -PIPE $$; printf 'SIGPIPE was ignored'"], stdin: input,
            environment: HookBinary.environment(home: home, socket: home + "/none.sock"))
        #expect(result.stdout.isEmpty, "\(result)")
        if size < 1_000 {
            #expect(result.signal == SIGPIPE, "\(result)")  // exec path: the hook process became the shell
        } else {
            #expect(result.status == 128 + SIGPIPE, "\(result)")  // spawn path: reported like a shell
        }
    }

    @Test func version() throws {
        let home = try HookBinary.scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let result = try HookBinary.run(
            ["--version"], stdin: "", environment: HookBinary.environment(home: home, socket: ""))
        #expect(result.status == 0, "\(result)")
        #expect(result.stdout.hasPrefix("0."), "\(result)")
    }
}
