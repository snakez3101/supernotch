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
/// SuperNotch is launched by launchd (PATH = /usr/bin:/bin:/usr/sbin:/sbin), so `claude` is looked up in
/// well-known install locations, the login shell's PATH, `command -v claude` in the user's shell (once) and
/// finally the CLI bundled with Claude Desktop. Results are cached.
nonisolated final class ClaudeCLIEnvironment: @unchecked Sendable {
    static let shared = ClaudeCLIEnvironment()

    /// What an internal `claude` call is for (decides the extra environment).
    enum Purpose: Sendable {
        /// `claude --version`, `claude agents --json`.
        case query
        /// The Haiku title call: safe mode (no MCP servers, hooks, CLAUDE.md, plugins).
        case title
    }

    private let lock = NSLock()
    private var cachedPATH: String?
    private var cachedExecutable: String?
    private var lastMiss: Date?
    private var cachedVersions: [String: ClaudeVersion] = [:]

    /// Keys stripped from our environment before spawning `claude` (in case SuperNotch itself was started
    /// from inside a Claude Code session).
    private static let strippedKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_HOST_SESSION_ID",
        "CLAUDE_CODE_SSE_PORT",
    ]

    /// Environment for internal `claude` invocations: the user's PATH, the internal marker (our own hook
    /// then hides the session, SPEC §E.2), no non-essential traffic, and the config dir when not the default.
    func environment(homeDirectory: String, configDirectory: String?, purpose: Purpose = .query) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Self.strippedKeys { environment[key] = nil }
        environment["PATH"] = searchPath(homeDirectory: homeDirectory)
        environment["HOME"] = homeDirectory
        environment[IPCConfig.internalMarkerEnvironmentKey] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        if purpose == .title { environment["CLAUDE_CODE_SAFE_MODE"] = "1" }
        if let configDirectory, configDirectory != homeDirectory + "/.claude" {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
        }
        return environment
    }

    /// Absolute path of `claude`, nil when Claude Code is not installed. `hint` is the executable path the
    /// hook reported (used when it really is the claude binary, not `node`). Blocking on first use; call off
    /// the main thread.
    func claudeExecutable(homeDirectory: String, hint: String?) -> String? {
        let fileManager = FileManager.default
        if let hint, Self.isUsableHint(hint), fileManager.isExecutableFile(atPath: hint) { return hint }
        lock.lock()
        let cached = cachedExecutable
        let recentMiss = lastMiss.map { Date().timeIntervalSince($0) < 600 } ?? false
        lock.unlock()
        if let cached, fileManager.isExecutableFile(atPath: cached) { return cached }
        if recentMiss { return nil }

        let found = locate(homeDirectory: homeDirectory)
        lock.lock()
        cachedExecutable = found
        lastMiss = found == nil ? Date() : nil
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
                environment: environment(homeDirectory: homeDirectory, configDirectory: nil),
                currentDirectory: homeDirectory, timeout: 5),
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
        lastMiss = nil
        cachedVersions = [:]
        lock.unlock()
    }

    /// Login-shell PATH plus well-known install directories, de-duplicated.
    func searchPath(homeDirectory: String) -> String {
        lock.lock()
        let cached = cachedPATH
        lock.unlock()
        if let cached { return cached }

        // The login shell's order first: that is the `claude` the user actually runs.
        var directories: [String] = []
        if let login = loginShellOutput(script: "printf '%s' \"$PATH\"", interactive: false),
            !login.contains("\n")
        {
            directories += login.split(separator: ":").map(String.init)
        }
        directories += Self.wellKnownDirectories(homeDirectory: homeDirectory)
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        var seen = Set<String>()
        let unique = directories.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
        let path = unique.joined(separator: ":")
        lock.lock()
        cachedPATH = path
        lock.unlock()
        return path
    }

    // MARK: - Lookup

    /// The hook reports the claude process's executable. For npm installs that is `node`, which cannot run
    /// `agents --json`; accept only real claude binaries (`…/claude`, native installs `…/claude/versions/<v>`).
    static func isUsableHint(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasSuffix(".js") else { return false }
        let name = (path as NSString).lastPathComponent
        return name == "claude" || path.contains("/claude/versions/")
    }

    static func wellKnownDirectories(homeDirectory: String) -> [String] {
        var directories = [
            homeDirectory + "/.claude/local",
            homeDirectory + "/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory + "/.npm-global/bin",
            homeDirectory + "/.bun/bin",
            homeDirectory + "/.volta/bin",
            homeDirectory + "/Library/pnpm",
        ]
        let nvmRoot = homeDirectory + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            directories += versions.sorted().reversed().map { nvmRoot + "/" + $0 + "/bin" }
        }
        return directories
    }

    private func locate(homeDirectory: String) -> String? {
        let fileManager = FileManager.default
        // 1. Well-known locations and the login shell's PATH.
        for directory in searchPath(homeDirectory: homeDirectory).split(separator: ":") {
            let candidate = String(directory) + "/claude"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        // 2. The user's interactive shell (nvm & co. are often set up in .zshrc only).
        if let output = loginShellOutput(script: "command -v claude", interactive: true),
            let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("/") })
        {
            let path = String(line).trimmingCharacters(in: .whitespaces)
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        // 3. The CLI bundled with Claude Desktop.
        return Self.desktopBundledCLI(homeDirectory: homeDirectory)
    }

    /// `~/Library/Application Support/Claude/claude-code/<version>/…/claude`, newest version first.
    static func desktopBundledCLI(homeDirectory: String) -> String? {
        let root = homeDirectory + "/Library/Application Support/Claude/claude-code"
        let fileManager = FileManager.default
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return nil }
        let sorted = versions.sorted { lhs, rhs in
            let left = ClaudeVersion(lhs)
            let right = ClaudeVersion(rhs)
            if let left, let right { return left > right }
            return lhs > rhs
        }
        for version in sorted {
            let base = root + "/" + version
            let direct = [
                base + "/claude", base + "/claude.app/Contents/MacOS/claude", base + "/bin/claude",
            ]
            if let hit = direct.first(where: { fileManager.isExecutableFile(atPath: $0) }) { return hit }
            guard let enumerator = fileManager.enumerator(atPath: base) else { continue }
            var visited = 0
            while let relative = enumerator.nextObject() as? String, visited < 400 {
                visited += 1
                if (relative as NSString).lastPathComponent == "claude", enumerator.level <= 4 {
                    let path = base + "/" + relative
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                        fileManager.isExecutableFile(atPath: path)
                    {
                        return path
                    }
                }
                if enumerator.level > 4 { enumerator.skipDescendants() }
            }
        }
        return nil
    }

    /// Runs `script` in the user's login shell (3 s budget). Nil on failure.
    private func loginShellOutput(script: String, interactive: Bool) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment[IPCConfig.internalMarkerEnvironmentKey] = "1"
        let flags = interactive ? ["-l", "-i", "-c"] : ["-l", "-c"]
        guard
            let output = ClaudeProcessRunner.runSync(
                executable: shell, arguments: flags + [script], environment: environment,
                currentDirectory: NSHomeDirectory(), timeout: 3, maxOutputBytes: 64 * 1024),
            output.succeeded
        else { return nil }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains("/") ? text : nil
    }
}
