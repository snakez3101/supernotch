// Owner: claude-core. Baseline implementation by the foundation (SPEC §D.7). Harden + test.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum HookRunner {
    /// Informational (sent as `context.hookVersion`). The app re-copies the hook when the file hash differs,
    /// so this does not gate compatibility; bump it when the wire format changes.
    static let version = "0.1.0"

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var socketPath: String {
        SocketPath.resolve(homeDirectory: NSHomeDirectory(), uid: UInt32(getuid()), environment: environment)
    }

    // MARK: - hook

    static func runHook() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard !input.isEmpty, let payload = try? JSONValue.parse(input) else {
            debugLog("hook: empty or invalid stdin")
            return
        }
        let event = HookEventName(payload["hook_event_name"]?.stringValue ?? "Unknown")
        var context = HookContext(environment: environment, hookVersion: version)
        ProcessProbe.enrich(&context)

        let envelope = HookEnvelope(
            id: UUID().uuidString, sentAt: Date().timeIntervalSince1970, event: event,
            expectsReply: event.isBlocking, context: context, payload: payload)

        // Our own `claude -p` calls and remote sessions never block.
        if envelope.expectsReply && (context.isInternal || context.isRemote) {
            send(envelope, expectReply: false)
            return
        }
        guard let reply = send(envelope, expectReply: envelope.expectsReply), let decision = reply.decision else {
            return
        }
        FileHandle.standardOutput.write(Data(decision.hookStdout.utf8))
    }

    // MARK: - statusline

    static func runStatusLine() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let payload = try? JSONValue.parse(input) {
            var context = HookContext(environment: environment, hookVersion: version)
            ProcessProbe.enrich(&context)
            let envelope = HookEnvelope(
                id: UUID().uuidString, sentAt: Date().timeIntervalSince1970, event: .statusLine, expectsReply: false,
                context: context, payload: payload)
            send(envelope, expectReply: false)
        }
        // Run the user's original statusLine command (if any) with the same stdin.
        let paths = SuperNotchPaths(homeDirectory: NSHomeDirectory())
        guard let data = FileManager.default.contents(atPath: paths.hookManifest),
            let manifest = try? JSONDecoder().decode(HookManifest.self, from: data),
            let command = manifest.originalStatusLineCommand, !command.contains(HookInstallSpec.defaultMarker)
        else { return }
        OriginalStatusLine.run(command: command, stdin: input, timeout: 1.0)
    }

    // MARK: - Socket

    /// Sends one envelope. Returns the reply for blocking requests; nil on any failure (fail open).
    @discardableResult
    static func send(_ envelope: HookEnvelope, expectReply: Bool) -> HookReply? {
        guard let line = try? NDJSON.encodeLine(envelope) else { return nil }
        guard let socket = UnixSocketClient(path: socketPath) else {
            debugLog("connect failed: \(socketPath)")
            return nil
        }
        defer { socket.close() }
        guard socket.writeAll(line, timeout: IPCConfig.writeTimeout) else {
            debugLog("write failed")
            return nil
        }
        guard expectReply else { return nil }
        guard let replyLine = socket.readLine(timeout: IPCConfig.permissionReplyTimeout) else {
            debugLog("no reply for \(envelope.id)")
            return nil
        }
        guard let reply = try? NDJSON.decodeLine(HookReply.self, from: replyLine), reply.id == envelope.id else {
            return nil
        }
        return reply
    }

    // MARK: - Debug log (only with SUPERNOTCH_HOOK_DEBUG=1)

    static func debugLog(_ message: String) {
        guard environment[IPCConfig.hookDebugEnvironmentKey] == "1" else { return }
        let directory = SuperNotchPaths(homeDirectory: NSHomeDirectory()).logsDirectory
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/hook.log"
        let line = "\(Date()) [\(getpid())] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            _ = FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}

/// Runs the user's original statusLine command, forwarding stdin and printing its stdout.
enum OriginalStatusLine {
    static func run(command: String, stdin: Data, timeout: TimeInterval) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env[IPCConfig.internalMarkerEnvironmentKey] = nil
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        input.fileHandleForWriting.write(stdin)
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            return
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        FileHandle.standardOutput.write(data)
    }
}
