// Owner: claude-core. Finds the owning `claude` process by walking parent processes (SPEC §D.7).
// Baseline: Linux via /proc, macOS via sysctl(KERN_PROC_PID) + KERN_PROCARGS2. Harden + test.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum ProcessProbe {
    static let maxHops = 8

    struct Info {
        var pid: Int32
        var parent: Int32
        var arguments: [String]
        var startTime: Double?
    }

    /// Fills claudePID, claudeStartTime, claudeExecutablePath, tty and isPrintMode.
    static func enrich(_ context: inout HookContext) {
        var pid = getppid()
        for _ in 0..<maxHops {
            guard pid > 1, let info = info(for: pid) else { break }
            if isClaude(info.arguments) {
                context.claudePID = info.pid
                context.claudeStartTime = info.startTime
                context.claudeExecutablePath = executablePath(from: info.arguments)
                context.isPrintMode = info.arguments.dropFirst().contains { $0 == "-p" || $0 == "--print" }
                break
            }
            pid = info.parent
        }
        context.tty = controllingTTY()
    }

    /// argv[0] basename is "claude", or a node/bun process running a claude cli.js.
    static func isClaude(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        let name = (first as NSString).lastPathComponent
        if name == "claude" { return true }
        if name == "node" || name == "bun" {
            return arguments.dropFirst().prefix(2).contains {
                $0.hasSuffix("/claude") || $0.contains("claude-code/cli") || $0.contains("@anthropic-ai/claude-code")
            }
        }
        return false
    }

    static func executablePath(from arguments: [String]) -> String? {
        guard let first = arguments.first else { return nil }
        if (first as NSString).lastPathComponent == "claude" { return first.hasPrefix("/") ? first : nil }
        return arguments.dropFirst().first { $0.hasSuffix("/claude") }
    }

    static func controllingTTY() -> String? {
        for descriptor: Int32 in [0, 1, 2] {
            if isatty(descriptor) == 1, let name = ttyname(descriptor) { return String(cString: name) }
        }
        return nil
    }

    #if os(Linux)
        static func info(for pid: Int32) -> Info? {
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let closing = stat.lastIndex(of: ")")
            else { return nil }
            let fields = stat[stat.index(after: closing)...].split(separator: " ")
            guard fields.count > 2, let parent = Int32(fields[1]) else { return nil }
            let cmdline = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") ?? Data()
            let arguments = cmdline.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            return Info(pid: pid, parent: parent, arguments: arguments, startTime: nil)
        }
    #elseif canImport(Darwin)
        static func info(for pid: Int32) -> Info? {
            var kinfo = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, u_int(mib.count), &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = kinfo.kp_eproc.e_ppid
            let started = kinfo.kp_proc.p_un.__p_starttime
            let startTime = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
            return Info(pid: pid, parent: parent, arguments: arguments(for: pid), startTime: startTime)
        }

        /// argv via KERN_PROCARGS2: [argc: Int32][exec path\0][padding \0…][argv0\0 argv1\0 …][env…]
        static func arguments(for pid: Int32) -> [String] {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return [] }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
            let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
            var index = 4
            while index < size && buffer[index] != 0 { index += 1 }  // exec path
            while index < size && buffer[index] == 0 { index += 1 }  // padding
            var result: [String] = []
            while result.count < argc && index < size {
                let start = index
                while index < size && buffer[index] != 0 { index += 1 }
                result.append(String(decoding: buffer[start..<index], as: UTF8.self))
                index += 1
            }
            return result
        }
    #else
        static func info(for pid: Int32) -> Info? { nil }
    #endif
}
