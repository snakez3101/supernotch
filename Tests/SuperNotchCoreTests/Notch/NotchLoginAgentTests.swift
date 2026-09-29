// Owner: notch-shell.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("NotchLoginAgent")
struct NotchLoginAgentTests {
    let executable = "/Applications/SuperNotch.app/Contents/MacOS/SuperNotch"
    let bundleID = "io.github.snakez3101.supernotch"

    private func decode(_ data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(object as? [String: Any])
    }

    @Test func plistPathIsPerUserLaunchAgents() {
        #expect(
            NotchLoginAgent.plistPath(homeDirectory: "/Users/me")
                == "/Users/me/Library/LaunchAgents/io.github.snakez3101.supernotch.plist")
        #expect(
            NotchLoginAgent.plistPath(homeDirectory: "/Users/me/", label: "x.y")
                == "/Users/me/Library/LaunchAgents/x.y.plist")
    }

    @Test func plistContainsTheLaunchKeys() throws {
        let data = try NotchLoginAgent.plistData(executablePath: executable, bundleIdentifier: bundleID)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("<?xml"))
        let plist = try decode(data)
        #expect(plist["Label"] as? String == NotchLoginAgent.defaultLabel)
        #expect(plist["ProgramArguments"] as? [String] == [executable, NotchLoginAgent.launchedAtLoginArgument])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [bundleID])
        #expect(plist["KeepAlive"] == nil)
    }

    @Test func plistWithoutBundleIdentifierOmitsAssociation() throws {
        let data = try NotchLoginAgent.plistData(label: "a.b", executablePath: executable, bundleIdentifier: nil)
        let plist = try decode(data)
        #expect(plist["Label"] as? String == "a.b")
        #expect(plist["AssociatedBundleIdentifiers"] == nil)
    }

    @Test func programIsReadBack() throws {
        let data = try NotchLoginAgent.plistData(executablePath: executable, bundleIdentifier: bundleID)
        #expect(NotchLoginAgent.program(inPlist: data) == executable)
        #expect(NotchLoginAgent.program(inPlist: Data("not a plist".utf8)) == nil)

        let programOnly = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "x", "Program": "/opt/SuperNotch"] as [String: Any], format: .xml,
            options: 0)
        #expect(NotchLoginAgent.program(inPlist: programOnly) == "/opt/SuperNotch")
    }

    @Test func fileStateComparesWithThisExecutable() throws {
        let current = try NotchLoginAgent.plistData(executablePath: executable, bundleIdentifier: bundleID)
        #expect(NotchLoginAgent.fileState(plistData: nil, executablePath: executable) == .missing)
        #expect(NotchLoginAgent.fileState(plistData: current, executablePath: executable) == .current)
        // Same file, non-canonical spelling of the running path.
        #expect(
            NotchLoginAgent.fileState(
                plistData: current, executablePath: "/Applications/./SuperNotch.app/Contents/MacOS/../MacOS/SuperNotch")
                == .current)

        let old = try NotchLoginAgent.plistData(
            executablePath: "/Users/me/Downloads/SuperNotch.app/Contents/MacOS/SuperNotch", bundleIdentifier: bundleID)
        #expect(
            NotchLoginAgent.fileState(plistData: old, executablePath: executable)
                == .stale(program: "/Users/me/Downloads/SuperNotch.app/Contents/MacOS/SuperNotch"))
        #expect(
            NotchLoginAgent.fileState(plistData: Data("garbage".utf8), executablePath: executable)
                == .stale(program: nil))
    }

    @Test func bootoutTargetIsTheGuiDomain() {
        #expect(NotchLoginAgent.bootoutTarget(uid: 501) == "gui/501/io.github.snakez3101.supernotch")
    }

    @Test func normalizedPath() {
        #expect(NotchLoginAgent.normalizedPath("/a/b/../c/./d/") == "/a/c/d")
        #expect(NotchLoginAgent.normalizedPath("") == "")
    }
}

@Suite("NotchLoginState")
struct NotchLoginStateTests {
    @Test func loginItemWins() {
        #expect(NotchLoginState.resolve(service: .enabled, agentFile: .missing) == .enabled(.loginItem))
        #expect(NotchLoginState.resolve(service: .enabled, agentFile: .current) == .enabled(.loginItem))
    }

    @Test func launchAgentCountsWhenItStartsThisCopy() {
        for service in [NotchLoginServiceStatus.notRegistered, .notFound, .requiresApproval] {
            #expect(NotchLoginState.resolve(service: service, agentFile: .current) == .enabled(.launchAgent))
        }
    }

    @Test func staleOrMissingAgentIsOff() {
        for agent in [NotchLoginAgentFileState.missing, .stale(program: "/old"), .stale(program: nil)] {
            #expect(NotchLoginState.resolve(service: .notRegistered, agentFile: agent) == .disabled)
            #expect(NotchLoginState.resolve(service: .notFound, agentFile: agent) == .disabled)
            #expect(NotchLoginState.resolve(service: .requiresApproval, agentFile: agent) == .requiresApproval)
        }
    }

    @Test func toggleValue() {
        #expect(NotchLoginState.enabled(.loginItem).isOn)
        #expect(NotchLoginState.enabled(.launchAgent).isOn)
        #expect(NotchLoginState.requiresApproval.isOn)
        #expect(!NotchLoginState.disabled.isOn)
    }

    @Test func registerSteps() {
        #expect(NotchLoginRegisterStep.after(status: .enabled) == .done)
        #expect(NotchLoginRegisterStep.after(status: .requiresApproval) == .needsApproval)
        #expect(NotchLoginRegisterStep.after(status: .notRegistered) == .useLaunchAgent)
        #expect(NotchLoginRegisterStep.after(status: .notFound) == .useLaunchAgent)
    }
}

@Suite("NotchInstanceGuard")
struct NotchInstanceGuardTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func aloneKeepsRunning() {
        let me = NotchInstanceGuard.Instance(pid: 50, launchDate: t0)
        #expect(!NotchInstanceGuard.shouldYield(current: me, others: []))
        #expect(!NotchInstanceGuard.shouldYield(current: me, others: [me]))
    }

    @Test func youngerCopyYields() {
        let old = NotchInstanceGuard.Instance(pid: 900, launchDate: t0)
        let new = NotchInstanceGuard.Instance(pid: 100, launchDate: t0 + 5)
        #expect(NotchInstanceGuard.shouldYield(current: new, others: [old]))
        #expect(!NotchInstanceGuard.shouldYield(current: old, others: [new]))
    }

    @Test func simultaneousStartKeepsExactlyOne() {
        let a = NotchInstanceGuard.Instance(pid: 10, launchDate: t0)
        let b = NotchInstanceGuard.Instance(pid: 11, launchDate: t0)
        #expect(!NotchInstanceGuard.shouldYield(current: a, others: [b]))
        #expect(NotchInstanceGuard.shouldYield(current: b, others: [a]))

        let c = NotchInstanceGuard.Instance(pid: 20, launchDate: nil)
        let d = NotchInstanceGuard.Instance(pid: 21, launchDate: t0)
        #expect(!NotchInstanceGuard.shouldYield(current: c, others: [d]))
        #expect(NotchInstanceGuard.shouldYield(current: d, others: [c]))
    }
}
