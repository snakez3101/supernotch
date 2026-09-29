// Owner: claude-app. PID liveness and parent lookups (SPEC §E.3 liveness, §D.8 fallback focus).
// Start times use the same source as `supernotch-hook` (sysctl KERN_PROC_PID → p_starttime), so a PID that
// was reused by another process is detected.

import Foundation

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
