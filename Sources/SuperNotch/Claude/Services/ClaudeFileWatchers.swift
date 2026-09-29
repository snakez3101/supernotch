// Owner: claude-app. Event-driven file watchers (SPEC §E.3, §F.1: no polling).
// * `ClaudeSessionFileWatcher`: `<config>/sessions/<pid>.json` (undocumented). A removed file hints at a
//   process exit, confirmed with kill(pid, 0).
// * `ClaudeTranscriptWatcher`: transcripts of *working* sessions only, throttled. Catches the
//   "[Request interrupted by user" marker (Esc does not fire Stop) and freshly written ai-titles.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A DispatchSource vnode watcher for one path. The handler runs on a private utility queue.
nonisolated final class ClaudeVnodeWatcher: @unchecked Sendable {
    let path: String
    #if canImport(Darwin)
        private let source: DispatchSourceFileSystemObject
    #endif

    private static let queue = DispatchQueue(label: "io.github.snakez3101.supernotch.claude.vnode", qos: .utility)

    init?(
        path: String, events: DispatchSource.FileSystemEvent,
        handler: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void
    ) {
        #if canImport(Darwin)
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            self.path = path
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: events, queue: Self.queue)
            // Dispatch source protocols are not class-bound (no `[weak source]`). The strong capture is a cycle
            // only until `cancel()`, which `deinit` guarantees; dispatch then releases the handler.
            source.setEventHandler {
                handler(source.data)
            }
            source.setCancelHandler { _ = Darwin.close(fd) }
            self.source = source
            source.resume()
        #else
            return nil  // vnode sources are Darwin-only; the app target is macOS-only anyway.
        #endif
    }

    func cancel() {
        #if canImport(Darwin)
            source.cancel()
        #endif
    }

    deinit { cancel() }
}

/// Watches `<config>/sessions/` and reports PIDs whose file vanished and whose process is gone.
final class ClaudeSessionFileWatcher {
    var onProcessExit: ((Int32) -> Void)?

    private var watcher: ClaudeVnodeWatcher?
    private(set) var directory: String?
    private var knownPIDs: Set<Int32> = []
    private var rescanScheduled = false

    var isWatching: Bool { watcher != nil }

    /// Starts watching `directory` (no-op if already watching it; silently waits if it does not exist yet).
    func start(directory: String) {
        if self.directory == directory, watcher != nil { return }
        stop()
        self.directory = directory
        guard FileManager.default.fileExists(atPath: directory) else { return }
        knownPIDs = Self.listPIDs(in: directory)
        watcher = ClaudeVnodeWatcher(path: directory, events: [.write, .delete, .rename]) { [weak self] events in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if events.contains(.delete) || events.contains(.rename) {
                    self.watcher = nil  // The directory itself went away; re-armed on the next start().
                }
                self.scheduleRescan()
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        directory = nil
        knownPIDs = []
    }

    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        // Coalesce bursts (atomic rewrites show up as delete + create).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.rescanScheduled = false
            self.rescan()
        }
    }

    private func rescan() {
        guard let directory else { return }
        let current = Self.listPIDs(in: directory)
        let removed = knownPIDs.subtracting(current)
        knownPIDs = current
        for pid in removed where ClaudeProcessInspector.isGone(pid) {
            Log.claude.debug("session file removed, process \(pid, privacy: .public) exited")
            onProcessExit?(pid)
        }
    }

    private static func listPIDs(in directory: String) -> Set<Int32> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return Set(
            names.compactMap { name in
                guard name.hasSuffix(".json") else { return nil }
                return Int32(name.dropLast(5))
            })
    }
}

/// Watches the transcripts of working sessions and reports (throttled) that one changed.
final class ClaudeTranscriptWatcher {
    var onChange: ((String) -> Void)?
    /// At most one change report per session per interval.
    var throttle: TimeInterval = 2.0

    private var watchers: [String: ClaudeVnodeWatcher] = [:]
    private var pending: Set<String> = []

    /// `targets`: session id → transcript path. Starts/stops watchers to match.
    func update(targets: [String: String]) {
        for (sessionID, watcher) in watchers where targets[sessionID] != watcher.path {
            watcher.cancel()
            watchers[sessionID] = nil
        }
        for (sessionID, path) in targets where watchers[sessionID] == nil {
            let watcher = ClaudeVnodeWatcher(path: path, events: [.write, .extend, .delete, .rename]) {
                [weak self] events in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if events.contains(.delete) || events.contains(.rename) {
                        self.watchers[sessionID]?.cancel()
                        self.watchers[sessionID] = nil
                    }
                    self.report(sessionID)
                }
            }
            if let watcher { watchers[sessionID] = watcher }
        }
    }

    func stopAll() {
        for watcher in watchers.values { watcher.cancel() }
        watchers = [:]
        pending = []
    }

    private func report(_ sessionID: String) {
        guard !pending.contains(sessionID) else { return }
        pending.insert(sessionID)
        DispatchQueue.main.asyncAfter(deadline: .now() + throttle) { [weak self] in
            guard let self else { return }
            self.pending.remove(sessionID)
            self.onChange?(sessionID)
        }
    }
}
