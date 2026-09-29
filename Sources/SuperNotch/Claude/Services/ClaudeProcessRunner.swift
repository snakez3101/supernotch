// Owner: claude-app. Background process spawning for `claude agents --json`, `claude --version` and the
// Haiku title generator (SPEC §E.3/§E.4, §F.4 #12). Never runs on the main thread.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

nonisolated enum ClaudeProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var timedOut: Bool

        var succeeded: Bool { !timedOut && status == 0 }
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Runs `executable` with a hard timeout. Returns nil when the process could not be launched.
    /// stdin is /dev/null, stderr is discarded, stdout is drained continuously (no full-pipe deadlock).
    static func run(
        executable: String, arguments: [String], environment: [String: String],
        currentDirectory: String? = nil, timeout: TimeInterval, maxOutputBytes: Int = 8 * 1024 * 1024
    ) async -> Output? {
        await withCheckedContinuation { continuation in
            start(
                executable: executable, arguments: arguments, environment: environment,
                currentDirectory: currentDirectory, timeout: timeout, maxOutputBytes: maxOutputBytes
            ) { output in
                continuation.resume(returning: output)
            }
        }
    }

    /// Blocking variant for code that already runs on a background queue.
    static func runSync(
        executable: String, arguments: [String], environment: [String: String],
        currentDirectory: String? = nil, timeout: TimeInterval, maxOutputBytes: Int = 1024 * 1024
    ) -> Output? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OutputBox()
        start(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory, timeout: timeout, maxOutputBytes: maxOutputBytes
        ) { output in
            box.set(output)
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()
    }

    /// Callback-based core. `completion` is called exactly once, on a background queue.
    static func start(
        executable: String, arguments: [String], environment: [String: String],
        currentDirectory: String?, timeout: TimeInterval, maxOutputBytes: Int,
        completion: @escaping @Sendable (Output?) -> Void
    ) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            completion(nil)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let reader = pipe.fileHandleForReading
        let state = RunState(reader: reader, limit: maxOutputBytes, completion: completion)

        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                state.markEOF()
            } else {
                state.append(chunk)
            }
        }
        process.terminationHandler = { finished in
            state.markTerminated(status: finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            try? reader.close()
            completion(nil)
            return
        }
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard !state.isFinished, !state.isTerminated else { return }
            state.markTimedOut()
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                guard !state.isFinished, !state.isTerminated else { return }
                kill(pid, SIGKILL)
                state.markTerminated(status: -1)
            }
        }
    }

    // MARK: - State

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Output?
        func set(_ output: Output?) {
            lock.lock()
            value = output
            lock.unlock()
        }
        func get() -> Output? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private let reader: FileHandle
        private let limit: Int
        private let completion: @Sendable (Output?) -> Void
        private var data = Data()
        private var eof = false
        private var terminated = false
        private var status: Int32 = -1
        private var timedOut = false
        private var finished = false

        init(reader: FileHandle, limit: Int, completion: @escaping @Sendable (Output?) -> Void) {
            self.reader = reader
            self.limit = limit
            self.completion = completion
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        var isTerminated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return terminated
        }

        func append(_ chunk: Data) {
            lock.lock()
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
            lock.unlock()
        }

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        func markEOF() {
            lock.lock()
            eof = true
            let ready = terminated
            lock.unlock()
            if ready { finish() }
        }

        func markTerminated(status: Int32) {
            lock.lock()
            if !terminated {
                terminated = true
                self.status = status
            }
            let ready = eof
            lock.unlock()
            if ready {
                finish()
            } else {
                // A grandchild may keep the pipe open: do not wait for EOF forever.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [self] in finish() }
            }
        }

        private func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let output = Output(status: status, stdout: data, timedOut: timedOut)
            lock.unlock()
            reader.readabilityHandler = nil
            try? reader.close()
            completion(output)
        }
    }
}

/// Finds the `claude` CLI and builds the environment for the processes SuperNotch spawns.
/// SuperNotch is launched by launchd and does not see the user's shell PATH, so the login shell is asked
/// once (cached) and well-known install locations are added.
nonisolated final class ClaudeCLIEnvironment: @unchecked Sendable {
    static let shared = ClaudeCLIEnvironment()

    private let lock = NSLock()
    private var cachedPATH: String?
    private var cachedExecutable: String?
    private var cachedVersions: [String: ClaudeVersion] = [:]

    /// Keys stripped from our environment before spawning `claude` (in case SuperNotch itself was started
    /// from inside a Claude Code session).
    private static let strippedKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_HOST_SESSION_ID",
        "CLAUDE_CODE_SSE_PORT",
    ]

    /// Environment for internal `claude` invocations: the user's PATH, the internal marker (our own hook
    /// then hides the session, SPEC §E.2) and the config dir when it is not the default.
    func environment(homeDirectory: String, configDirectory: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Self.strippedKeys { environment[key] = nil }
        environment["PATH"] = searchPath(homeDirectory: homeDirectory)
        environment["HOME"] = homeDirectory
        environment[IPCConfig.internalMarkerEnvironmentKey] = "1"
        if let configDirectory, configDirectory != homeDirectory + "/.claude" {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
        }
        return environment
    }

    /// Absolute path of `claude`. `hint` is a path reported by the hook (preferred when usable).
    /// Blocking on first use (asks the login shell); call off the main thread.
    func claudeExecutable(homeDirectory: String, hint: String?) -> String? {
        let fileManager = FileManager.default
        if let hint, hint.hasPrefix("/"), !hint.hasSuffix(".js"), fileManager.isExecutableFile(atPath: hint) {
            return hint
        }
        lock.lock()
        let cached = cachedExecutable
        lock.unlock()
        if let cached, fileManager.isExecutableFile(atPath: cached) { return cached }

        let directories = searchPath(homeDirectory: homeDirectory).split(separator: ":").map(String.init)
        let found = directories.lazy.map { $0 + "/claude" }.first { fileManager.isExecutableFile(atPath: $0) }
        lock.lock()
        cachedExecutable = found
        lock.unlock()
        return found
    }

    /// `claude --version`, cached per executable. Nil when unknown (installer then uses base events only).
    func claudeVersion(executable: String, homeDirectory: String) -> ClaudeVersion? {
        lock.lock()
        let cached = cachedVersions[executable]
        lock.unlock()
        if let cached { return cached }
        guard
            let output = ClaudeProcessRunner.runSync(
                executable: executable, arguments: ["--version"],
                environment: environment(homeDirectory: homeDirectory, configDirectory: nil), timeout: 5),
            output.succeeded, let version = ClaudeVersion(output.text)
        else { return nil }
        lock.lock()
        cachedVersions[executable] = version
        lock.unlock()
        return version
    }

    /// Forget cached lookups (e.g. after the user installed Claude Code while SuperNotch was running).
    func invalidate() {
        lock.lock()
        cachedExecutable = nil
        cachedVersions = [:]
        lock.unlock()
    }

    /// Login-shell PATH plus well-known install directories, de-duplicated.
    func searchPath(homeDirectory: String) -> String {
        lock.lock()
        let cached = cachedPATH
        lock.unlock()
        if let cached { return cached }

        var directories: [String] = []
        if let login = loginShellPATH() { directories += login.split(separator: ":").map(String.init) }
        directories += [
            homeDirectory + "/.local/bin",
            homeDirectory + "/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory + "/.npm-global/bin",
            homeDirectory + "/.bun/bin",
            homeDirectory + "/.volta/bin",
            homeDirectory + "/Library/pnpm",
        ]
        directories += nvmBinDirectories(homeDirectory: homeDirectory)
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        var seen = Set<String>()
        let unique = directories.filter { !$0.isEmpty && seen.insert($0).inserted }
        let path = unique.joined(separator: ":")
        lock.lock()
        cachedPATH = path
        lock.unlock()
        return path
    }

    private func loginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment[IPCConfig.internalMarkerEnvironmentKey] = "1"
        guard
            let output = ClaudeProcessRunner.runSync(
                executable: shell, arguments: ["-l", "-c", "printf '%s' \"$PATH\""], environment: environment,
                timeout: 3, maxOutputBytes: 64 * 1024),
            output.succeeded
        else { return nil }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("/"), !text.contains("\n") else { return nil }
        return text
    }

    private func nvmBinDirectories(homeDirectory: String) -> [String] {
        let root = homeDirectory + "/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return versions.sorted().reversed().map { root + "/" + $0 + "/bin" }
    }
}
