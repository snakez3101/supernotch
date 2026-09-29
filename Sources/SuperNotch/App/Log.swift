// Owner: FOUNDATION (SPEC §F.2).
//
// Unified logging for the app target. Usage: `Log.claude.debug("hook installed at \(path, privacy: .public)")`.
// * Use `privacy: .public` only for non-personal values (counts, states, bundle ids, error codes).
// * Never log prompts, file contents or clipboard contents.
// * `nonisolated`: safe to use from background queues, DispatchSource handlers and C callbacks.
import os

nonisolated enum Log {
    static let subsystem = "io.github.snakez3101.supernotch"

    /// Launch, lifecycle, windows, menu-bar item, smoke test (FOUNDATION).
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Panel, geometry, hover, popups, fullscreen (notch-shell).
    static let notch = Logger(subsystem: subsystem, category: "notch")
    /// Sessions, hook installer, agents poller, titles, focuser (claude-app).
    static let claude = Logger(subsystem: subsystem, category: "claude")
    /// Hook socket server and replies (claude-app).
    static let ipc = Logger(subsystem: subsystem, category: "ipc")
    /// Spotify / AppleScript (media).
    static let media = Logger(subsystem: subsystem, category: "media")
    /// Shelf storage, drag & drop, AirDrop (shelf-clipboard).
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
    /// Clipboard history capture and paste (shelf-clipboard).
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    /// Settings persistence and the Settings window.
    static let settings = Logger(subsystem: subsystem, category: "settings")
    /// Hotkeys, launch at login, displays, permissions (notch-shell System/*).
    static let system = Logger(subsystem: subsystem, category: "system")
}
