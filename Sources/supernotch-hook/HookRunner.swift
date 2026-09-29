// Owner: claude-core. The two modes of `supernotch-hook` (SPEC §D.7).
//
// FAIL OPEN: whatever happens (app not running, socket missing, timeout, garbage), exit 0 and print nothing
// unless the app returned a real permission decision. Claude Code then behaves as if the hook did not exist.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum HookRunner {
    /// Informational (sent as `context.hookVersion`). The app re-copies the hook when the file hash differs, so
    /// this does not gate compatibility; bump it when the wire format changes.
    static let version = "0.2.0"

    /// Largest stdin we accept (a Write of a huge file); anything bigger is dropped (fail open).
    static let maxStdinBytes = 64 * 1024 * 1024

    static let environment = ProcessInfo.processInfo.environment

    static var socketPath: String {
        SocketPath.resolve(homeDirectory: NSHomeDirectory(), uid: UInt32(getuid()), environment: environment)
    }

    // MARK: - hook

    static func runHook() {
        let input = StdinReader.readAll(timeout: IPCConfig.stdinReadTimeout, limit: maxStdinBytes)
        var context = HookContext(environment: environment, hookVersion: version)
        // Our own `claude -p` title calls / `claude agents` runs and cloud sessions are none of the app's business.
        if context.isInternal || context.isRemote { return }
        guard !input.isEmpty, let raw = try? JSONValue.parse(input), case .object = raw else {
            debugLog("hook: empty or invalid stdin (\(input.count) bytes)")
            return
        }
        let payload = HookPayloadCompactor.compact(raw)
        guard let sessionID = payload["session_id"]?.stringValue, !sessionID.isEmpty else { return }
        let event = HookEventName(payload["hook_event_name"]?.stringValue ?? "Unknown")
        ProcessProbe.enrich(&context)

        // AskUserQuestion's dialog is the permission prompt itself: never wait (the app only marks the row red).
        let expectsReply =
            context.shouldAwaitPermissionReply(for: event, agentID: payload["agent_id"]?.stringValue)
            && payload["tool_name"]?.stringValue != "AskUserQuestion"
        let envelope = HookEnvelope(
            id: UUID().uuidString, sentAt: Date().timeIntervalSince1970, event: event, expectsReply: expectsReply,
            context: context, payload: payload)
        guard let reply = send(envelope, expectReply: expectsReply) else { return }
        guard let decision = reply.decision else {
            debugLog("hook: passthrough for \(envelope.id)")
            return
        }
        StandardOutput.write(decision.hookStdout)
        debugLog("hook: decision delivered for \(envelope.id)")
    }

    // MARK: - statusline

    /// `supernotch-hook statusline [--wrap '<original command>']`: forwards the statusLine JSON (rate limits) to
    /// the app, then becomes the user's original status line command (exec) with the same stdin, so its output,
    /// timing and cancellation are exactly as without us. Without an original command it prints a minimal line.
    static func runStatusLine(arguments: [String]) {
        let input = StdinReader.readAll(timeout: IPCConfig.stdinReadTimeout, limit: maxStdinBytes)
        let context = HookContext(environment: environment, hookVersion: version)  // no process probe: runs often
        let payload = try? JSONValue.parse(input)
        if !context.isInternal && !context.isRemote, let payload, case .object = payload {
            let envelope = HookEnvelope(
                id: UUID().uuidString, sentAt: Date().timeIntervalSince1970, event: .statusLine, expectsReply: false,
                context: context, payload: HookPayloadCompactor.compact(payload))
            send(envelope, expectReply: false)
        }
        if let original = wrappedCommand(in: arguments) {
            // exec(2) never returns; the large-input path returns the shell's exit status, which we adopt so both
            // paths look the same to Claude Code. nil: nothing could be started, so fail open (exit 0, no output).
            if let status = OriginalStatusLine.exec(command: original, stdin: input) { exit(status) }
            return
        }
        if let payload, let line = defaultStatusLine(payload) { StandardOutput.write(line + "\n") }
    }

    /// The argument after `--wrap` (our installer shell-quotes the user's command into one argument).
    static func wrappedCommand(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: IPCConfig.statusLineWrapArgument), flag + 1 < arguments.count else {
            return nil
        }
        let command = arguments[flag + 1]
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !HookSettingsMerger.isOurCommand(command, marker: HookInstallSpec.defaultMarker)
        else { return nil }
        return command
    }

    /// "Opus 4.7 · 42% context" for users who had no status line of their own.
    static func defaultStatusLine(_ payload: JSONValue) -> String? {
        var parts: [String] = []
        if let model = payload["model"]?["display_name"]?.stringValue ?? payload["model"]?["id"]?.stringValue {
            parts.append(model)
        }
        if let used = payload["context_window"]?["used_percentage"]?.doubleValue, used.isFinite {
            parts.append("\(Int(used.rounded()))% context")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Socket

    /// Sends one envelope. Returns the reply for blocking requests; nil on any failure (fail open).
    @discardableResult
    static func send(_ envelope: HookEnvelope, expectReply: Bool) -> HookReply? {
        guard let line = try? NDJSON.encodeLine(envelope) else { return nil }
        let path = socketPath
        guard let client = UnixSocketClient.connect(path: path, timeout: IPCConfig.connectTimeout) else {
            debugLog("connect failed: \(path)")
            return nil
        }
        defer { client.close() }
        guard client.writeAll(line, timeout: IPCConfig.writeTimeout) else {
            debugLog("write failed")
            return nil
        }
        guard expectReply else { return nil }
        guard let replyLine = client.readLine(timeout: replyTimeout, maxBytes: IPCConfig.maxReplyBytes) else {
            debugLog("no reply for \(envelope.id)")
            return nil
        }
        guard let reply = HookReply.parse(line: replyLine), reply.id == envelope.id else {
            debugLog("invalid reply for \(envelope.id)")
            return nil
        }
        return reply
    }

    /// `IPCConfig.permissionReplyTimeout`, or the test/debug override when it is sane.
    static var replyTimeout: TimeInterval {
        if let raw = environment[IPCConfig.replyTimeoutEnvironmentKey], let value = TimeInterval(raw),
            value >= 0.05, value <= IPCConfig.permissionReplyTimeout
        {
            return value
        }
        return IPCConfig.permissionReplyTimeout
    }

    // MARK: - Debug log (only with SUPERNOTCH_HOOK_DEBUG=1; never logs payload contents)

    static func debugLog(_ message: String) {
        guard environment[IPCConfig.hookDebugEnvironmentKey] == "1" else { return }
        let directory = SuperNotchPaths(homeDirectory: NSHomeDirectory()).logsDirectory
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let descriptor = open(directory + "/hook.log", O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        defer { _ = Glue.close(descriptor) }
        let line = "\(Date().timeIntervalSince1970) [\(getpid())] \(message)\n"
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { Glue.write(descriptor, $0.baseAddress, $0.count) }
    }
}

/// Writes to fd 1 with plain `write(2)` (FileHandle.write raises an exception on EPIPE on Darwin).
enum StandardOutput {
    static func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Glue.write(1, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}

/// Reads fd 0 to EOF with a deadline (Claude Code always closes it; a caller that does not must not hang us).
enum StdinReader {
    static func readAll(timeout: TimeInterval, limit: Int) -> Data {
        if isatty(0) == 1 { return Data() }  // run by hand in a terminal
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while data.count <= limit {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var descriptor = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 60_000)))
            if ready < 0 && errno == EINTR { continue }
            if ready <= 0 { break }
            let count = buffer.withUnsafeMutableBytes { Glue.read(0, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count < 0 && (errno == EINTR || errno == EAGAIN) {
                continue
            } else {
                break
            }
        }
        return data.count > limit ? Data() : data
    }
}

/// Runs the user's original statusLine command with the statusLine JSON on its stdin.
enum OriginalStatusLine {
    /// Replaces this process with `/bin/sh -c <command>` whose stdin is a pipe pre-filled with `stdin`. No
    /// timeout, no orphan, no relaying: Claude Code reads the command's stdout directly and cancels it directly.
    /// For input larger than the pipe buffer it spawns the shell instead and waits for it; the shell's exit status
    /// is then returned (`nil` when exec or spawn failed: fail open).
    static func exec(command: String, stdin: Data) -> Int32? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let readEnd = fds[0]
        let writeEnd = fds[1]
        let flags = fcntl(writeEnd, F_GETFL)
        if flags >= 0 { _ = fcntl(writeEnd, F_SETFL, flags | O_NONBLOCK) }
        let bytes = [UInt8](stdin)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Glue.write(writeEnd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                break  // pipe full (EAGAIN) or error
            }
        }
        let arguments = ["/bin/sh", "-c", command]
        if offset == bytes.count {
            _ = Glue.close(writeEnd)
            guard dup2(readEnd, 0) >= 0 else { return nil }
            _ = Glue.close(readEnd)
            _ = withCStrings(arguments) { argv in execv("/bin/sh", argv) }
            return nil  // exec failed: print nothing (fail open)
        }
        return spawnAndFeed(arguments, readEnd: readEnd, writeEnd: writeEnd, remaining: Array(bytes[offset...]))
    }

    /// Large-input fallback: child gets the pipe as stdin and inherits our stdout (so its output is passed through
    /// untouched); we feed the rest, wait, and return its exit status like a shell would (128 + signal when it was
    /// killed). `nil` when it could not be spawned.
    static func spawnAndFeed(_ arguments: [String], readEnd: Int32, writeEnd: Int32, remaining: [UInt8]) -> Int32? {
        #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t?
        #else
            var actions = posix_spawn_file_actions_t()
        #endif
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            _ = Glue.close(readEnd)
            _ = Glue.close(writeEnd)
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        _ = posix_spawn_file_actions_adddup2(&actions, readEnd, 0)
        _ = posix_spawn_file_actions_addclose(&actions, writeEnd)
        var child: pid_t = 0
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let spawned =
            withCStrings(arguments) { argv in
                withCStrings(environment) { envp in posix_spawn(&child, "/bin/sh", &actions, nil, argv, envp) } ?? -1
            } ?? -1
        _ = Glue.close(readEnd)
        guard spawned == 0 else {
            _ = Glue.close(writeEnd)
            return nil
        }
        let flags = fcntl(writeEnd, F_GETFL)
        if flags >= 0 { _ = fcntl(writeEnd, F_SETFL, flags & ~O_NONBLOCK) }
        var offset = 0
        while offset < remaining.count {
            let written = remaining[offset...].withUnsafeBytes { Glue.write(writeEnd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        _ = Glue.close(writeEnd)
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {
            // retry after a signal
        }
        return exitStatus(fromWaitStatus: status)
    }

    /// The shell convention for a `waitpid` status (the WIFEXITED macros are not importable into Swift).
    static func exitStatus(fromWaitStatus status: Int32) -> Int32 {
        let terminatingSignal = status & 0x7f
        return terminatingSignal == 0 ? (status >> 8) & 0xff : 128 + terminatingSignal
    }

    /// NULL-terminated C string array valid for the duration of `body`.
    static func withCStrings<Result>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result? {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeBufferPointer { buffer in buffer.baseAddress.map(body) }
    }
}
