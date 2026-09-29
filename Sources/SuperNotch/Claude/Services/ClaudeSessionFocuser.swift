// Owner: claude-app. "Jump to chat" (SPEC §D.8), best effort, never blocks the main thread.
//
// | Host            | Technique                                                                          |
// | Claude Desktop  | claude://code/continue?session=<local_id> (undocumented) → else activate the app  |
// | iTerm2          | AppleScript: select the session by ITERM_SESSION_ID's UUID, else by tty            |
// | Terminal.app    | AppleScript: select the tab whose tty matches                                      |
// | tmux            | tmux select-window/select-pane on $TMUX_PANE, then activate the terminal           |
// | WezTerm         | wezterm cli activate-pane --pane-id $WEZTERM_PANE, then activate                   |
// | others / VS Code| activate the app by bundle id                                                      |
// | fallback        | the host app the hook found (`HookContext.hostAppPath`), else walk the parent       |
// |                 | processes of the claude PID to the first GUI app and activate it                   |
//
// AppleScript only targets apps that are already running (never launches them). Automation permission is
// requested by macOS lazily, per host, on first use.

import AppKit
import Foundation
import SuperNotchCore

final class ClaudeSessionFocuser {
    private let scriptQueue = DispatchQueue(label: "io.github.snakez3101.supernotch.claude.focus", qos: .userInitiated)
    private let homeDirectory: String

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    /// `hostAppPath`: the enclosing `.app` of the GUI process hosting the session, as the hook reported it.
    func focus(_ session: Session, hostAppPath: String? = nil) {
        let host = session.host
        Log.claude.debug("focus session host=\(host.kind.rawValue, privacy: .public)")
        if host.kind == .claudeDesktop {
            focusDesktop(host)
            return
        }
        if let pane = host.tmuxPane { selectTmuxPane(pane, tmuxEnvironment: host.tmux) }
        guard let bundleID = ClaudeHostApps.bundleID(for: host) else {
            if let hostAppPath, FileManager.default.fileExists(atPath: hostAppPath) {
                openApplication(at: URL(fileURLWithPath: hostAppPath, isDirectory: true))
            } else {
                activateHostingApp(of: session)
            }
            return
        }
        if bundleID == ClaudeHostApps.iTerm2 {
            let uuid = host.iTermSessionID.flatMap { $0.split(separator: ":").last.map(String.init) } ?? ""
            let tty = host.tty ?? ""
            guard !uuid.isEmpty || !tty.isEmpty, ClaudeSystemBridge.isApplicationRunning(bundleID: bundleID) else {
                activate(bundleID: bundleID, session: session)
                return
            }
            runAppleScript(Self.iTermScript(uuid: uuid, tty: tty)) { [weak self] found in
                if !found { self?.activate(bundleID: bundleID, session: session) }
            }
        } else if bundleID == ClaudeHostApps.terminal {
            guard let tty = host.tty, ClaudeSystemBridge.isApplicationRunning(bundleID: bundleID) else {
                activate(bundleID: bundleID, session: session)
                return
            }
            runAppleScript(Self.terminalScript(tty: tty)) { [weak self] found in
                if !found { self?.activate(bundleID: bundleID, session: session) }
            }
        } else if bundleID == ClaudeHostApps.wezterm {
            if let pane = host.weztermPane { activateWezTermPane(pane) }
            activate(bundleID: bundleID, session: session)
        } else {
            activate(bundleID: bundleID, session: session)
        }
    }

    // MARK: - Claude Desktop

    private func focusDesktop(_ host: SessionHost) {
        if let localID = host.desktopSessionID, Self.isValidDesktopSessionID(localID),
            let url = URL(string: "claude://code/continue?session=\(localID)"),
            NSWorkspace.shared.open(url)
        {
            return
        }
        activate(bundleID: SessionHost.claudeDesktopBundleID, session: nil)
    }

    /// `local_<uuid>` as accepted by Desktop's URL handler (`^local_[A-Za-z0-9-]{1,64}$`).
    static func isValidDesktopSessionID(_ value: String) -> Bool {
        guard value.hasPrefix("local_") else { return false }
        let rest = value.dropFirst("local_".count)
        guard (1...64).contains(rest.count) else { return false }
        return rest.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122) || scalar == "-"
        }
    }

    // MARK: - Activation

    /// Brings `bundleID` forward. Uses LaunchServices (reliable from a non-active accessory app); falls back
    /// to the parent-process walk when the app is unknown.
    private func activate(bundleID: String, session: Session?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            openApplication(at: url)
            return
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [])
            return
        }
        if let session { activateHostingApp(of: session) }
    }

    /// Fallback: the first ancestor of the claude process that is a regular GUI app.
    private func activateHostingApp(of session: Session) {
        guard let pid = session.pid else {
            Log.claude.info("jump to chat: host unknown")
            return
        }
        for ancestor in ClaudeProcessInspector.ancestry(of: pid).dropFirst() {
            guard let app = NSRunningApplication(processIdentifier: ancestor),
                app.activationPolicy == .regular
            else { continue }
            if let url = app.bundleURL {
                openApplication(at: url)
            } else {
                app.activate(options: [])
            }
            return
        }
        Log.claude.info("jump to chat: no GUI ancestor found")
    }

    /// Opens (activates) an app through LaunchServices, which works from a non-active accessory app.
    private func openApplication(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Log.claude.info("activate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - AppleScript

    private func runAppleScript(_ source: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        scriptQueue.async {
            var found = false
            if let script = NSAppleScript(source: source) {
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if let error {
                    let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                    Log.claude.info("focus AppleScript failed (\(number, privacy: .public))")
                } else {
                    found = result.stringValue == "ok"
                }
            }
            let succeeded = found
            DispatchQueue.main.async {
                completion(succeeded)
            }
        }
    }

    /// AppleScript string literal (quotes and backslashes escaped).
    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func iTermScript(uuid: String, tty: String) -> String {
        """
        set wantedID to \(literal(uuid))
        set wantedTTY to \(literal(tty))
        tell application id "com.googlecode.iterm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        set matched to false
                        if wantedID is not "" then
                            if (unique id of aSession) is wantedID then set matched to true
                        end if
                        if (not matched) and wantedTTY is not "" then
                            if (tty of aSession) is wantedTTY then set matched to true
                        end if
                        if matched then
                            select aWindow
                            select aTab
                            select aSession
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    static func terminalScript(tty: String) -> String {
        """
        set wantedTTY to \(literal(tty))
        tell application id "com.apple.Terminal"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if (tty of aTab) is wantedTTY then
                        set selected tab of aWindow to aTab
                        set index of aWindow to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    // MARK: - Multiplexers

    /// `tmux select-window` + `select-pane` on the session's pane (socket from $TMUX when known).
    private func selectTmuxPane(_ pane: String, tmuxEnvironment: String?) {
        let home = homeDirectory
        let socket = tmuxEnvironment?.split(separator: ",").first.map(String.init)
        DispatchQueue.global(qos: .userInitiated).async {
            let environment = ClaudeCLIEnvironment.shared
            let searchPath = environment.searchPath(homeDirectory: home)
            guard
                let tmux = searchPath.split(separator: ":").lazy.map({ String($0) + "/tmux" }).first(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                })
            else { return }
            var arguments: [String] = []
            if let socket, !socket.isEmpty { arguments += ["-S", socket] }
            arguments += ["select-window", "-t", pane, ";", "select-pane", "-t", pane]
            _ = ClaudeProcessRunner.runSync(
                executable: tmux, arguments: arguments, environment: ProcessInfo.processInfo.environment, timeout: 2)
        }
    }

    private func activateWezTermPane(_ pane: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeHostApps.wezterm) else {
            return
        }
        let cli = appURL.appendingPathComponent("Contents/MacOS/wezterm").path
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ClaudeProcessRunner.runSync(
                executable: cli, arguments: ["cli", "activate-pane", "--pane-id", pane],
                environment: ProcessInfo.processInfo.environment, timeout: 2)
        }
    }
}
