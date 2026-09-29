// Owner: claude-core. UsageLimits, AgentsListEntry, SessionHost / visibility classification, ClaudeProcess.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("UsageLimits")
struct UsageLimitsTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func parsesTheDocumentedStatusLinePayload() throws {
        let limits = try #require(UsageLimits.fromStatusLine(try ClaudeFixtures.json("statusline"), now: now))
        #expect(limits.fiveHour == UsageWindow(usedPercentage: 82.5, resetsAt: Date(timeIntervalSince1970: 1_790_003_600)))
        #expect(limits.sevenDay?.usedPercentage == 12)
        #expect(limits.fiveHour?.fraction == 0.825)
        #expect(limits.isWarning(threshold: 0.8))
        #expect(!limits.isWarning(threshold: 0.9))
        #expect(limits.maxFraction == 0.825)
        #expect(limits.updatedAt == now)
    }

    @Test func tolerantScalars() throws {
        let payload: JSONValue = [
            "rate_limits": [
                "five_hour": ["used_percentage": "40.5", "resets_at": 1_790_003_600_000],
                "seven_day": ["used_percentage": 150, "resets_at": "2026-09-30T00:00:00Z"],
            ]
        ]
        let limits = try #require(UsageLimits.fromStatusLine(payload, now: now))
        #expect(limits.fiveHour?.usedPercentage == 40.5)
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_790_003_600))
        #expect(limits.sevenDay?.fraction == 1)
        #expect(limits.sevenDay?.resetsAt != nil)
        #expect(UsageLimits.fromStatusLine(["rate_limits": [:]], now: now) == nil)
        #expect(UsageLimits.fromStatusLine(["rate_limits": "nope"], now: now) == nil)
        #expect(UsageLimits.fromStatusLine(["model": ["id": "x"]], now: now) == nil)
        #expect(UsageLimits.fromStatusLine(["rate_limits": ["five_hour": ["resets_at": 1]]], now: now) == nil)
    }

    @Test func mergingNeverLetsAStaleReportWin() {
        let reset = Date(timeIntervalSince1970: 1_790_003_600)
        let current = UsageWindow(usedPercentage: 60, resetsAt: reset)
        #expect(current.merged(with: UsageWindow(usedPercentage: 40, resetsAt: reset)).usedPercentage == 60)
        #expect(current.merged(with: UsageWindow(usedPercentage: 70, resetsAt: reset.addingTimeInterval(30))).usedPercentage == 70)
        let newWindow = UsageWindow(usedPercentage: 1, resetsAt: reset.addingTimeInterval(18_000))
        #expect(current.merged(with: newWindow) == newWindow)
        let stale = UsageWindow(usedPercentage: 99, resetsAt: reset.addingTimeInterval(-18_000))
        #expect(current.merged(with: stale) == current)

        let limits = UsageLimits(fiveHour: current, sevenDay: UsageWindow(usedPercentage: 10, resetsAt: nil), updatedAt: now)
        let merged = limits.merged(with: UsageLimits(fiveHour: nil, sevenDay: UsageWindow(usedPercentage: 11, resetsAt: nil), updatedAt: now.addingTimeInterval(5)))
        #expect(merged.fiveHour == current)
        #expect(merged.sevenDay?.usedPercentage == 11)
        #expect(merged.updatedAt == now.addingTimeInterval(5))
    }

    @Test func pruning() {
        let limits = UsageLimits(
            fiveHour: UsageWindow(usedPercentage: 50, resetsAt: now), sevenDay: UsageWindow(usedPercentage: 5, resetsAt: nil),
            updatedAt: now)
        let pruned = limits.pruned(now: now)
        #expect(pruned.fiveHour == nil)
        #expect(pruned.sevenDay != nil)
        #expect(!pruned.isEmpty)
        #expect(UsageLimits(fiveHour: nil, sevenDay: nil, updatedAt: now).isEmpty)
    }

    @Test func codableForPersistence() throws {
        let limits = UsageLimits(fiveHour: UsageWindow(usedPercentage: 1.5, resetsAt: now), sevenDay: nil, updatedAt: now)
        let decoded = try JSONDecoder().decode(UsageLimits.self, from: try JSONEncoder().encode(limits))
        #expect(decoded == limits)
    }
}

@Suite("AgentsListEntry")
struct AgentsListEntryTests {
    @Test func decodesNoisyOutputTolerantly() throws {
        let entries = try AgentsListEntry.decodeList(try ClaudeFixtures.data("agents-list", "txt"))
        #expect(entries.count == 5)
        #expect(entries[0].pid == 4242)
        #expect(entries[0].status == "busy")
        #expect(entries[0].startedDate == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(entries[1].needsInputKind == .permission)
        #expect(entries[2].state == "working")
        #expect(entries[2].id == "b7")
        #expect(entries[3].sessionId == nil)
        #expect(entries[4].pid == 4444)  // numeric string
        #expect(entries[4].sessionId == "0d6f1c2e-1111-4a5b-8c9d-000000000004")
    }

    @Test func shapes() throws {
        #expect(try AgentsListEntry.decodeList(Data("[]".utf8)).isEmpty)
        #expect(try AgentsListEntry.decodeList(Data(#"{"sessions":[{"sessionId":"x","pid":1}]}"#.utf8)).first?.pid == 1)
        #expect(try AgentsListEntry.decodeList(Data(#"{"unexpected":true}"#.utf8)).isEmpty)
        #expect(throws: (any Error).self) { try AgentsListEntry.decodeList(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try AgentsListEntry.decodeList(Data()) }
    }

    @Test func waitingForMapping() {
        func kind(_ waitingFor: String?) -> NeedsInputKind? { AgentsListEntry(waitingFor: waitingFor).needsInputKind }
        #expect(kind("permission prompt") == .permission)
        #expect(kind("sandbox request") == .permission)
        #expect(kind("input needed") == .question)
        #expect(kind("dialog open") == nil)
        #expect(kind("worker request") == nil)
        #expect(kind(nil) == .other)
    }
}

@Suite("Session host and visibility")
struct SessionHostTests {
    @Test func hostDetection() {
        let iterm = SessionHost(context: HookContext(tty: "/dev/ttys001", termProgram: "iTerm.app", bundleIdentifier: "com.apple.Terminal"))
        #expect(iterm.kind == .terminal)
        #expect(iterm.appBundleID == "com.googlecode.iterm2")  // TERM_PROGRAM beats a leaked bundle id
        let tmux = SessionHost(context: HookContext(termProgram: "tmux", tmux: "/tmp/tmux-501/default,1,0", bundleIdentifier: "com.mitchellh.ghostty"))
        #expect(tmux.kind == .terminal)
        #expect(tmux.appBundleID == "com.mitchellh.ghostty")
        let desktop = SessionHost(context: HookContext(entrypoint: "claude-desktop", hostSessionID: "local_1"))
        #expect(desktop.kind == .claudeDesktop)
        #expect(desktop.appBundleID == SessionHost.claudeDesktopBundleID)
        #expect(desktop.desktopSessionID == "local_1")
        #expect(SessionHost(context: HookContext(entrypoint: "claude-desktop-3p")).kind == .claudeDesktop)
        let cursor = SessionHost(context: HookContext(termProgram: "vscode", bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
        #expect(cursor.kind == .vscode)
        #expect(cursor.appBundleID == "com.todesktop.230313mzl4w4u92")
        #expect(SessionHost(context: HookContext(entrypoint: "claude-vscode")).appBundleID == SessionHost.vscodeBundleID)
        #expect(SessionHost(context: HookContext()).kind == .unknown)
        #expect(SessionHost.bundleID(forTermProgram: "Apple_Terminal") == "com.apple.Terminal")
        #expect(SessionHost.bundleID(forTermProgram: "vscode") == nil)
    }

    @Test func headlessClassification() {
        #expect(!HookContext(entrypoint: "claude-desktop", isPrintMode: true).isHeadless)
        #expect(!HookContext(hostSessionID: "local_x", isPrintMode: true).isHeadless)
        #expect(!HookContext(entrypoint: "claude-vscode", isPrintMode: true).isHeadless)
        #expect(HookContext(entrypoint: "cli", isPrintMode: true).isHeadless)
        #expect(HookContext(isPrintMode: true).isHeadless)
        #expect(HookContext(entrypoint: "sdk-ts").isHeadless)
        #expect(HookContext(entrypoint: "sdk-py").isHeadless)
        #expect(HookContext(bundleIdentifier: SessionHost.claudeDesktopBundleID, entrypoint: "local-agent").isHeadless)
        #expect(!HookContext(bundleIdentifier: SessionHost.claudeDesktopBundleID, entrypoint: "local-agent").isDesktopHost)
        #expect(!HookContext(entrypoint: "cli").isHeadless)
        #expect(SessionStore.visibility(for: HookContext(isInternal: true), event: .userPromptSubmit) == .hiddenInternal)
        #expect(SessionStore.visibility(for: HookContext(entrypoint: "claude-desktop", isPrintMode: true), event: .sessionStart) == .hiddenUntilFirstPrompt)
        #expect(SessionStore.visibility(for: HookContext(entrypoint: "claude-desktop", isPrintMode: true), event: .stop) == .visible)
    }

    @Test func awaitingReplies() {
        let terminal = HookContext(entrypoint: "cli")
        #expect(terminal.shouldAwaitPermissionReply(for: .permissionRequest, agentID: nil))
        #expect(terminal.shouldAwaitPermissionReply(for: .permissionRequest, agentID: "a1"))
        #expect(!terminal.shouldAwaitPermissionReply(for: .preToolUse, agentID: nil))
        #expect(!HookContext(isPrintMode: true).shouldAwaitPermissionReply(for: .permissionRequest, agentID: nil))
        #expect(!HookContext(isInternal: true).shouldAwaitPermissionReply(for: .permissionRequest, agentID: nil))
        #expect(HookContext(entrypoint: "claude-desktop", isPrintMode: true).shouldAwaitPermissionReply(for: .permissionRequest, agentID: nil))
    }

    @Test func projectNameAndDisplayTitle() {
        let session = Session(id: "s", cwd: "/Users/me/supernotch/", startedAt: Date())
        #expect(session.projectName == "supernotch")
        #expect(session.displayTitle == "supernotch")
        #expect(Session(id: "s", cwd: "", startedAt: Date()).projectName == "Claude")
        #expect(Session(id: "s", cwd: "/", startedAt: Date()).projectName == "Claude")
        #expect(TrafficLight.allCases.max() == .red)
        #expect(SessionPhase.needsInput(.question).trafficLight == .red)
        #expect(SessionPhase.idle.trafficLight == .grey)
    }
}

@Suite("ClaudeProcess")
struct ClaudeProcessTests {
    @Test func recognisesInstalls() {
        #expect(ClaudeProcess.isClaude(arguments: ["claude", "--resume"], executablePath: "/Users/me/.local/share/claude/versions/2.1.284"))
        #expect(ClaudeProcess.isClaude(arguments: ["/opt/homebrew/bin/claude"], executablePath: nil))
        #expect(ClaudeProcess.isClaude(arguments: ["2.1.284"], executablePath: "/Users/me/.local/share/claude/versions/2.1.284"))
        #expect(
            ClaudeProcess.isClaude(
                arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "-p", "hi"],
                executablePath: "/usr/local/bin/node"))
        #expect(ClaudeProcess.isClaude(arguments: ["node", "/usr/local/bin/claude"], executablePath: "/usr/local/bin/node"))
        #expect(!ClaudeProcess.isClaude(arguments: ["/Applications/Claude.app/Contents/MacOS/Claude"], executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"))
        #expect(!ClaudeProcess.isClaude(arguments: ["node", "server.js"], executablePath: "/usr/local/bin/node"))
        #expect(!ClaudeProcess.isClaude(arguments: ["/bin/zsh", "-c", "claude"], executablePath: "/bin/zsh"))
        #expect(!ClaudeProcess.isClaude(arguments: [], executablePath: nil))
    }

    @Test func printModeAndInvocation() {
        #expect(ClaudeProcess.isPrintMode(arguments: ["claude", "-p", "hello"]))
        #expect(ClaudeProcess.isPrintMode(arguments: ["claude", "--print"]))
        #expect(!ClaudeProcess.isPrintMode(arguments: ["claude", "fix -p flag handling"]))
        #expect(!ClaudeProcess.isPrintMode(arguments: ["-p"]))
        #expect(
            ClaudeProcess.invocation(arguments: ["claude"], executablePath: "/Users/me/.local/share/claude/versions/2.1.284")
                == ["/Users/me/.local/share/claude/versions/2.1.284"])
        #expect(
            ClaudeProcess.invocation(
                arguments: ["node", "/opt/lib/node_modules/@anthropic-ai/claude-code/cli.js"], executablePath: "/opt/bin/node")
                == ["/opt/bin/node", "/opt/lib/node_modules/@anthropic-ai/claude-code/cli.js"])
        #expect(ClaudeProcess.invocation(arguments: ["claude"], executablePath: nil) == nil)
    }

    @Test func hostAppAndTTY() {
        let chain = [
            HookProcessEntry(pid: 10, name: "sh", path: "/bin/sh"),
            HookProcessEntry(pid: 11, name: "2.1.284", path: "/Users/me/.local/share/claude/versions/2.1.284"),
            HookProcessEntry(pid: 12, name: "zsh", path: "/bin/zsh"),
            HookProcessEntry(pid: 13, name: "login", path: nil),
            HookProcessEntry(pid: 14, name: "iTerm2", path: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
            HookProcessEntry(pid: 1, name: "launchd", path: nil),
        ]
        #expect(ClaudeProcess.hostAppPath(chain: chain, claudePID: 11) == "/Applications/iTerm.app")
        let desktop = [
            HookProcessEntry(pid: 20, name: "claude", path: "/Users/me/Library/Application Support/Claude/claude-code/2.1.284/claude.app/Contents/MacOS/claude"),
            HookProcessEntry(pid: 21, name: "disclaimer", path: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            HookProcessEntry(pid: 22, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ]
        #expect(ClaudeProcess.hostAppPath(chain: desktop, claudePID: 20) == "/Applications/Claude.app")
        #expect(ClaudeProcess.hostAppPath(chain: [], claudePID: nil) == nil)
        #expect(HookContext.appBundlePath(in: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/x") == "/Applications/Visual Studio Code.app")
        #expect(ClaudeProcess.ttyPath(linuxTTYNumber: 34_816) == "/dev/pts/0")
        #expect(ClaudeProcess.ttyPath(linuxTTYNumber: 34_817) == "/dev/pts/1")
        #expect(ClaudeProcess.ttyPath(linuxTTYNumber: 0) == nil)
    }

    @Test func contextFromEnvironment() {
        let context = HookContext(
            environment: [
                "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:ABC", "CLAUDE_CODE_ENTRYPOINT": "cli",
                "SUPERNOTCH_INTERNAL": "1", "CLAUDE_CODE_REMOTE": "", "CLAUDE_CODE_EXECPATH": "/opt/claude/bin/claude",
                "CLAUDE_PID": "4242", "VSCODE_GIT_ASKPASS_NODE": "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/x",
            ], hookVersion: "9")
        #expect(context.termProgram == "iTerm.app")
        #expect(context.isInternal)
        #expect(!context.isRemote)
        #expect(context.claudeExecutablePath == "/opt/claude/bin/claude")
        #expect(context.claudeInvocation == ["/opt/claude/bin/claude"])
        #expect(context.claudePID == 4242)
        #expect(context.hostAppPath == "/Applications/Cursor.app")
        #expect(HookContext(environment: ["CLAUDE_CODE_REMOTE": "true"], hookVersion: "1").isRemote)
    }
}
