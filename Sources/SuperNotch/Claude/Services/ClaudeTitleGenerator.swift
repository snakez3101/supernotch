// Owner: claude-app. Haiku short titles, used only when Claude Code has no usable title (SPEC §E.4).
//
//   claude -p --model haiku --no-session-persistence --max-turns 1 --output-format text "<prompt>"
//
// * cwd = a fresh empty temp dir, env SUPERNOTCH_INTERNAL=1 (our hook hides that session), 20 s timeout,
//   at most 2 concurrent calls, a small hourly budget.
// * At most once per session; results cached in `SuperNotchPaths.titleCache`. Titles are never written back.
// * Prompts are never logged.

import Foundation
import SuperNotchCore

nonisolated struct ClaudeTitleCacheEntry: Codable, Sendable, Hashable {
    var title: String
    var createdAt: Date
}

nonisolated enum ClaudeTitleText {
    static let promptPrefix = "Summarise this coding task as a 2–4 word title. Reply with the title only.\n\n"
    static let maxSourceCharacters = 1_500

    static func prompt(for source: String) -> String {
        promptPrefix + String(source.prefix(maxSourceCharacters))
    }

    /// Cleans Haiku's reply into a display title (nil if unusable).
    static func sanitize(_ output: String) -> String? {
        let wrappers = CharacterSet(charactersIn: "\"'`*#_“”‘’.:- ")
        guard
            var line = output.split(whereSeparator: \.isNewline).map({
                $0.trimmingCharacters(in: .whitespaces)
            }).first(where: { !$0.isEmpty })
        else { return nil }
        line = line.trimmingCharacters(in: wrappers)
        for prefix in ["title:", "session title:", "task:"] where line.lowercased().hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
        }
        line = line.trimmingCharacters(in: wrappers)
        guard !line.isEmpty, line.count <= 80 else { return nil }
        let lowered = line.lowercased()
        let refusals = [
            "i can't", "i cannot", "i'm sorry", "i am sorry", "sorry", "as an ai", "error", "i need more",
            "usage limit", "rate limit", "not logged in", "please run", "invalid api key", "credit balance",
        ]
        if refusals.contains(where: { lowered.hasPrefix($0) }) || lowered.contains("api error") { return nil }
        let short = TitleResolver.shorten(line)
        return short.isEmpty ? nil : short
    }
}

final class ClaudeTitleGenerator {
    nonisolated struct Request: Sendable {
        var sessionID: String
        var sourceText: String
        var executableHint: String?
        var configDirectory: String
    }

    /// Called on the main actor with (sessionID, title).
    var onTitle: ((String, String) -> Void)?

    private let paths: SuperNotchPaths
    private let maxConcurrent = 2
    private let maxPerHour = 30
    private let cacheLimit = 500
    private let cacheMaxAge: TimeInterval = 30 * 86_400

    private var cache: [String: ClaudeTitleCacheEntry] = [:]
    private var cacheLoaded = false
    private var waiting: [Request] = []
    private var running: Set<String> = []
    private var attempted: Set<String> = []
    private var recentStarts: [Date] = []

    init(paths: SuperNotchPaths) {
        self.paths = paths
    }

    func cachedTitle(for sessionID: String) -> String? {
        loadCacheIfNeeded()
        return cache[sessionID]?.title
    }

    /// Queues a generation (ignored if one ran or is queued for this session).
    func enqueue(_ request: Request) {
        if let cached = cachedTitle(for: request.sessionID) {
            onTitle?(request.sessionID, cached)
            return
        }
        guard !attempted.contains(request.sessionID) else { return }
        attempted.insert(request.sessionID)
        waiting.append(request)
        pump()
    }

    /// Drops a queued request (session ended, feature turned off).
    func cancel(sessionID: String) {
        waiting.removeAll { $0.sessionID == sessionID }
    }

    func cancelAll() {
        waiting.removeAll()
    }

    // MARK: - Scheduling

    private func pump() {
        let now = Date()
        recentStarts.removeAll { now.timeIntervalSince($0) > 3_600 }
        while running.count < maxConcurrent, !waiting.isEmpty {
            guard recentStarts.count < maxPerHour else {
                Log.claude.info("Haiku title budget exhausted; keeping fallback titles")
                waiting.removeAll()
                return
            }
            let request = waiting.removeFirst()
            running.insert(request.sessionID)
            recentStarts.append(now)
            let home = paths.homeDirectory
            Task { [weak self] in
                let title = await Self.generate(request, homeDirectory: home)
                guard let self else { return }
                self.running.remove(request.sessionID)
                if let title {
                    self.store(title, for: request.sessionID)
                    self.onTitle?(request.sessionID, title)
                } else {
                    Log.claude.info("Haiku title generation failed; keeping the fallback title")
                }
                self.pump()
            }
        }
    }

    private nonisolated static func generate(_ request: Request, homeDirectory: String) async -> String? {
        let sourceText = request.sourceText
        let hint = request.executableHint
        let configDirectory = request.configDirectory
        return await Task.detached(priority: .utility) { () -> String? in
            let environment = ClaudeCLIEnvironment.shared
            guard let executable = environment.claudeExecutable(homeDirectory: homeDirectory, hint: hint) else {
                return nil
            }
            let workDirectory = NSTemporaryDirectory() + "supernotch-title-" + UUID().uuidString
            do {
                try FileManager.default.createDirectory(atPath: workDirectory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
            defer { try? FileManager.default.removeItem(atPath: workDirectory) }
            let arguments = [
                "-p", "--model", "haiku", "--no-session-persistence", "--max-turns", "1",
                "--output-format", "text", ClaudeTitleText.prompt(for: sourceText),
            ]
            guard
                let output = ClaudeProcessRunner.runSync(
                    executable: executable, arguments: arguments,
                    environment: environment.environment(
                        homeDirectory: homeDirectory, configDirectory: configDirectory, purpose: .title),
                    currentDirectory: workDirectory, timeout: 20, maxOutputBytes: 16 * 1024),
                output.succeeded
            else { return nil }
            return ClaudeTitleText.sanitize(output.text)
        }.value
    }

    // MARK: - Cache

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let data = FileManager.default.contents(atPath: paths.titleCache) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        cache = (try? decoder.decode([String: ClaudeTitleCacheEntry].self, from: data)) ?? [:]
    }

    private func store(_ title: String, for sessionID: String) {
        loadCacheIfNeeded()
        let now = Date()
        cache[sessionID] = ClaudeTitleCacheEntry(title: title, createdAt: now)
        cache = cache.filter { now.timeIntervalSince($0.value.createdAt) < cacheMaxAge }
        if cache.count > cacheLimit {
            let newest = cache.sorted { $0.value.createdAt > $1.value.createdAt }.prefix(cacheLimit)
            cache = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        let snapshot = cache
        let path = paths.titleCache
        let directory = paths.appSupport
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        }
    }
}
