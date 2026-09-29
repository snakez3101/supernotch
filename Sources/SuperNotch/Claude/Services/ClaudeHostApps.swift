// Owner: claude-app. Maps a session's host (hook context) to the GUI app that shows it.
// Used for focus-aware popups (skip 🟢 when that app is frontmost) and for "jump to chat" (SPEC §D.8).

import Foundation
import SuperNotchCore

nonisolated enum ClaudeHostApps {
    static let iTerm2 = "com.googlecode.iterm2"
    static let terminal = "com.apple.Terminal"
    static let ghostty = "com.mitchellh.ghostty"
    static let wezterm = "com.github.wez.wezterm"
    static let kitty = "net.kovidgoyal.kitty"
    static let warp = "dev.warp.Warp-Stable"
    static let vscode = "com.microsoft.VSCode"
    static let alacritty = "org.alacritty"
    static let claudeDesktop = SessionHost.claudeDesktopBundleID

    /// `TERM_PROGRAM` → bundle id (TERM_PROGRAM is the most reliable terminal hint).
    static let termProgramBundleIDs: [String: String] = [
        "iTerm.app": iTerm2,
        "Apple_Terminal": terminal,
        "ghostty": ghostty,
        "WezTerm": wezterm,
        "kitty": kitty,
        "WarpTerminal": warp,
        "vscode": vscode,
        "Hyper": "co.zeit.hyper",
        "Tabby": "org.tabby",
        "rio": "com.raphaelamorim.rio",
        "alacritty": alacritty,
        "zed": "dev.zed.Zed",
    ]

    /// Best guess of the bundle id of the app hosting `host`, nil when unknown.
    static func bundleID(for host: SessionHost) -> String? {
        if host.kind == .claudeDesktop { return claudeDesktop }
        if let bundle = host.appBundleID, !bundle.isEmpty { return bundle }
        if let program = host.termProgram, let bundle = termProgramBundleIDs[program] { return bundle }
        if host.kittyWindowID != nil { return kitty }
        if host.weztermPane != nil { return wezterm }
        if host.kind == .vscode { return vscode }
        return nil
    }

    /// Short label for the host shown in rows and peeks ("iTerm2", "Desktop", "VS Code").
    static func displayName(for host: SessionHost) -> String? {
        switch host.kind {
        case .claudeDesktop: return "Desktop"
        case .vscode: return "VS Code"
        case .terminal, .unknown: break
        }
        switch bundleID(for: host) {
        case iTerm2?: return "iTerm2"
        case terminal?: return "Terminal"
        case ghostty?: return "Ghostty"
        case wezterm?: return "WezTerm"
        case kitty?: return "kitty"
        case warp?: return "Warp"
        case vscode?: return "VS Code"
        case "com.todesktop.230313mzl4w4u92"?: return "Cursor"
        default: return host.kind == .terminal ? "Terminal" : nil
        }
    }
}
