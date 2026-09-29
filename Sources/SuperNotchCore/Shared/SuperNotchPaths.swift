import Foundation

// FOUNDATION-OWNED (frozen). Every on-disk location SuperNotch uses. Pure string math so it is testable
// on Linux; the app creates directories lazily (FileManager.createDirectory(withIntermediateDirectories:)).

public struct SuperNotchPaths: Sendable, Hashable {
    public static let bundleIdentifier = "io.github.snakez3101.supernotch"
    public static let appFolderName = "SuperNotch"
    public static let hookBinaryName = "supernotch-hook"

    public let homeDirectory: String

    public init(homeDirectory: String) {
        var home = homeDirectory
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        self.homeDirectory = home
    }

    /// ~/Library/Application Support/SuperNotch
    public var appSupport: String { homeDirectory + "/Library/Application Support/" + Self.appFolderName }
    /// Stable location of the hook helper referenced from ~/.claude/settings.json (re-verified every launch).
    public var binDirectory: String { appSupport + "/bin" }
    public var hookBinary: String { binDirectory + "/" + Self.hookBinaryName }
    /// JSON manifest written by the hook installer (installed command, events, original statusLine).
    public var hookManifest: String { appSupport + "/hook-manifest.json" }
    /// Timestamped backups of settings.json live here, e.g. settings.json.2026-09-29T14-03-11Z.bak
    public var settingsBackupDirectory: String { appSupport + "/Backups" }
    /// Shelf file copies: Shelf/<uuid>/<original file name>; index at Shelf/items.json.
    public var shelfDirectory: String { appSupport + "/Shelf" }
    public var shelfIndex: String { shelfDirectory + "/items.json" }
    /// Clipboard history: Clipboard/history.json + Clipboard/images/<uuid>.png
    public var clipboardDirectory: String { appSupport + "/Clipboard" }
    public var clipboardIndex: String { clipboardDirectory + "/history.json" }
    public var clipboardImagesDirectory: String { clipboardDirectory + "/images" }
    /// Cache (artwork, generated titles). Safe to delete.
    public var cacheDirectory: String { homeDirectory + "/Library/Caches/" + Self.bundleIdentifier }
    public var titleCache: String { appSupport + "/titles.json" }
    /// Logs written by the hook helper when SUPERNOTCH_HOOK_DEBUG=1.
    public var logsDirectory: String { homeDirectory + "/Library/Logs/" + Self.appFolderName }
}
