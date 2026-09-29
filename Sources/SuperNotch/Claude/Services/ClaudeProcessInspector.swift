// Owner: claude-app. PID liveness and parent lookups (SPEC §E.3 liveness, §D.8 fallback focus).
// Start times use the same source as `supernotch-hook` (sysctl KERN_PROC_PID → p_starttime), so a PID that
// was reused by another process is detected. argv/env (KERN_PROCARGS2) classify processes that only
// `claude agents --json` reported, so headless and internal runs are never adopted as rows.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

nonisolated enum ClaudeProcessInspector {
    /// True when the process no longer exists (kill(pid, 0) == -1 && errno == ESRCH).
    /// EPERM means "exists, owned by someone else" and counts as alive.
    static func isGone(_ pid: Int32) -> Bool {
        guard pid > 0 else { return true }
        if kill(pid, 0) == 0 { return false }
        return errno == ESRCH
    }

    /// True when `pid` is gone or now belongs to a different process (start time changed).
    static func hasExited(pid: Int32, expectedStartTime: Double?) -> Bool {
        if isGone(pid) { return true }
        guard let expectedStartTime, let current = startTime(of: pid) else { return false }
        return abs(current - expectedStartTime) > 1.0
    }

    /// Process start time in unix seconds, nil if unavailable.
    static func startTime(of pid: Int32) -> Double? {
        #if canImport(Darwin)
            guard let info = kinfo(pid) else { return nil }
            let started = info.kp_proc.p_un.__p_starttime
            return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        #else
            return nil
        #endif
    }

    /// Parent PID, nil if unavailable.
    static func parent(of pid: Int32) -> Int32? {
        #if canImport(Darwin)
            guard let info = kinfo(pid) else { return nil }
            let parent = info.kp_eproc.e_ppid
            return parent > 0 ? parent : nil
        #else
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let closing = stat.lastIndex(of: ")")
            else { return nil }
            let fields = stat[stat.index(after: closing)...].split(separator: " ")
            guard fields.count > 1, let parent = Int32(fields[1]), parent > 0 else { return nil }
            return parent
        #endif
    }

    /// `pid` and up to `maxHops` ancestors (closest first), stopping at launchd.
    static func ancestry(of pid: Int32, maxHops: Int = 16) -> [Int32] {
        var chain: [Int32] = []
        var current: Int32? = pid
        while let value = current, value > 1, chain.count <= maxHops {
            chain.append(value)
            current = parent(of: value)
        }
        return chain
    }

    /// True when `pid` is a Claude Code run that must never become a row: SuperNotch's own calls
    /// (`SUPERNOTCH_INTERNAL=1`), Agent SDK / Cowork / plain `claude -p` runs, or a cloud session. Uses Core's
    /// hook classification (`HookContext.isHeadless`) on the process's argv and environment. False when the
    /// process cannot be read (another user, already gone): the store's own rules then apply.
    static func isHiddenClaudeProcess(pid: Int32) -> Bool {
        guard pid > 0, let process = argumentsAndEnvironment(of: pid) else { return false }
        var context = HookContext(environment: process.environment, hookVersion: "app")
        context.isPrintMode = ClaudeProcess.isPrintMode(arguments: process.arguments)
        return context.isInternal || context.isRemote || context.isHeadless
    }

    /// argv and environment of a process owned by the same user. Nil when unreadable.
    static func argumentsAndEnvironment(of pid: Int32) -> (arguments: [String], environment: [String: String])? {
        #if canImport(Darwin)
            // KERN_PROCARGS2 layout: [argc: Int32][exec path\0][\0 padding…][argv…\0][env…\0][\0]…
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
            let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
            var index = 4
            while index < size && buffer[index] != 0 { index += 1 }  // exec path
            while index < size && buffer[index] == 0 { index += 1 }  // padding
            var strings: [String] = []
            while index < size {
                let start = index
                while index < size && buffer[index] != 0 { index += 1 }
                // An empty string after argv ends the environment block (the "apple" strings follow).
                if start == index && strings.count >= argc { break }
                strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
                index += 1
            }
            guard strings.count >= argc else { return nil }
            return (Array(strings.prefix(argc)), Self.environment(from: strings.dropFirst(argc)))
        #else
            guard let cmdline = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return nil }
            let arguments = cmdline.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            let environ = FileManager.default.contents(atPath: "/proc/\(pid)/environ") ?? Data()
            let pairs = environ.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            return (arguments, Self.environment(from: pairs[...]))
        #endif
    }

    private static func environment(from pairs: ArraySlice<String>) -> [String: String] {
        var environment: [String: String] = [:]
        for pair in pairs {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { continue }
            let key = String(pair[..<equals])
            if environment[key] == nil { environment[key] = String(pair[pair.index(after: equals)...]) }
        }
        return environment
    }

    #if canImport(Darwin)
        private static func kinfo(_ pid: Int32) -> kinfo_proc? {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
            return info
        }
    #endif
}
