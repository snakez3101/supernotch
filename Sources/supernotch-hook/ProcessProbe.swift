// Owner: claude-core. Walks the hook's ancestor processes (SPEC §D.7): finds the owning `claude` process and
// records its pid, start time, executable/invocation, terminal and `-p` flag, plus the chain up to launchd
// (for jump-to-chat). macOS: sysctl(KERN_PROC_PID) + KERN_PROCARGS2. Linux: /proc (tests, development).
//
// Hooks run in their own session without a controlling terminal (hooks.md), so the tty comes from the claude
// process (`e_tdev` / `tty_nr`), never from the hook's own descriptors.
//
// DARWIN CODE IS ONLY COMPILED ON THE macOS CI RUNNER. Keep it small and boring.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum ProcessProbe {
    /// Ancestors inspected (hook shell, claude, shells, multiplexers, terminal app, launchd).
    static let maxHops = 16

    struct Info {
        var pid: Int32
        var parent: Int32
        var name: String
        var path: String?
        var arguments: [String]
        var startTime: Double?
        var tty: String?
    }

    /// Fills claudePID, claudeStartTime, claudeExecutablePath, claudeInvocation, tty, isPrintMode, processChain
    /// and hostAppPath. Never fails: missing information stays nil.
    static func enrich(_ context: inout HookContext) {
        var chain: [HookProcessEntry] = []
        var claude: Info?
        var firstTTY: String?
        var hostApp: String?
        let hintedPID = context.claudePID  // CLAUDE_PID from the environment, if Claude Code exported it
        var pid = getppid()
        for _ in 0..<maxHops {
            // argv/paths are only needed until both the claude process and the GUI host app are known.
            guard pid > 0, let info = info(for: pid, detailed: claude == nil || hostApp == nil) else { break }
            chain.append(HookProcessEntry(pid: info.pid, name: info.name, path: info.path))
            if claude == nil,
                info.pid == hintedPID || ClaudeProcess.isClaude(arguments: info.arguments, executablePath: info.path)
            {
                claude = info
            } else if claude != nil, hostApp == nil, let path = info.path {
                hostApp = HookContext.appBundlePath(in: path)
            }
            if firstTTY == nil { firstTTY = info.tty }
            guard info.parent > 0, info.parent != pid, pid != 1 else { break }
            pid = info.parent
        }
        if let claude {
            context.claudePID = claude.pid
            context.claudeStartTime = claude.startTime
            if let invocation = ClaudeProcess.invocation(arguments: claude.arguments, executablePath: claude.path) {
                context.claudeInvocation = invocation
                context.claudeExecutablePath = invocation.last
            }
            context.isPrintMode = ClaudeProcess.isPrintMode(arguments: claude.arguments)
            context.tty = claude.tty ?? firstTTY
        } else {
            context.tty = firstTTY
        }
        if !chain.isEmpty {
            context.processChain = chain
            if let host = hostApp ?? ClaudeProcess.hostAppPath(chain: chain, claudePID: claude?.pid) {
                context.hostAppPath = host
            }
        }
    }

    #if canImport(Darwin)
        /// `detailed == false` skips KERN_PROCARGS2 (argv + executable path; the buffer is up to kern.argmax).
        static func info(for pid: Int32, detailed: Bool) -> Info? {
            var kinfo = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, u_int(mib.count), &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = kinfo.kp_eproc.e_ppid
            let started = kinfo.kp_proc.p_un.__p_starttime
            let startTime = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
            let name = withUnsafeBytes(of: kinfo.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let (path, arguments) = detailed ? processArguments(for: pid) : (nil, [])
            return Info(
                pid: pid, parent: parent, name: name, path: path, arguments: arguments, startTime: startTime,
                tty: terminal(device: kinfo.kp_eproc.e_tdev))
        }

        /// "/dev/ttys004" for a terminal device number; nil for none (NODEV = -1).
        static func terminal(device: dev_t) -> String? {
            guard device != -1, device != 0, let raw = devname(device, mode_t(S_IFCHR)) else { return nil }
            let name = String(cString: raw)
            guard !name.isEmpty, !name.contains("?") else { return nil }
            return "/dev/" + name
        }

        /// KERN_PROCARGS2 layout: [argc: Int32][exec path\0][padding \0…][argv0\0 argv1\0 …][env…].
        /// Returns (exec path, argv). Fails (nil, []) for other users' processes.
        static func processArguments(for pid: Int32) -> (String?, [String]) {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return (nil, []) }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 4 else { return (nil, []) }
            let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }  // no alignment assumption
            var index = 4
            let pathStart = index
            while index < size && buffer[index] != 0 { index += 1 }
            let path = String(decoding: buffer[pathStart..<index], as: UTF8.self)
            while index < size && buffer[index] == 0 { index += 1 }
            var arguments: [String] = []
            while arguments.count < Int(argc) && index < size {
                let start = index
                while index < size && buffer[index] != 0 { index += 1 }
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                index += 1
            }
            return (path.isEmpty ? nil : path, arguments)
        }
    #elseif os(Linux)
        static func info(for pid: Int32, detailed: Bool) -> Info? {
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let open = stat.firstIndex(of: "("), let closing = stat.lastIndex(of: ")")
            else { return nil }
            let name = String(stat[stat.index(after: open)..<closing])
            let fields = stat[stat.index(after: closing)...].split(separator: " ")
            // fields: state(0) ppid(1) pgrp(2) session(3) tty_nr(4) … starttime(19)
            guard fields.count > 19, let parent = Int32(fields[1]) else { return nil }
            let tty = Int(fields[4]).flatMap(ClaudeProcess.ttyPath(linuxTTYNumber:))
            let startTime = Double(fields[19]).flatMap { ticks -> Double? in
                guard let boot = bootTime else { return nil }
                let hertz = Double(sysconf(Int32(_SC_CLK_TCK)))
                return boot + ticks / (hertz > 0 ? hertz : 100)
            }
            var arguments: [String] = []
            var path: String?
            if detailed {
                let cmdline = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") ?? Data()
                arguments = cmdline.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
            }
            return Info(
                pid: pid, parent: parent, name: name, path: path, arguments: arguments, startTime: startTime, tty: tty)
        }

        /// `btime` from /proc/stat (Unix seconds of boot).
        static let bootTime: Double? = {
            guard let text = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") where line.hasPrefix("btime ") {
                return Double(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }()
    #else
        static func info(for pid: Int32, detailed: Bool) -> Info? { nil }
    #endif
}
