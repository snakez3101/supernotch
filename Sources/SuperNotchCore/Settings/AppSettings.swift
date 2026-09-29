import Foundation

// FOUNDATION-OWNED (SPEC §D.3). Every persisted user setting and its default.
// Persisted as one JSON blob in UserDefaults (`userDefaultsKey`) by the app's SettingsStore.
// Decoding is tolerant: a missing or malformed key falls back to its default, so adding fields is safe.
// Streams: do NOT edit. Request new settings via the escape hatch in SPEC §C.

/// Closed-notch appearance (REQUIREMENTS "Closed state is user-configurable").
public enum ClosedNotchMode: String, Codable, Sendable, CaseIterable {
    /// Looks exactly like the hardware notch; only events/hover show anything.
    case invisible
    /// Dynamic-Island style: album cover left, visualizer right, Claude dots while chats are active.
    case island
}

/// Expanded background style.
public enum NotchStyle: String, Codable, Sendable, CaseIterable {
    /// Black top band fading into Liquid Glass.
    case glass
    /// Solid black (for Reduce Transparency or taste).
    case solidBlack
}

/// Auto-cleanup for shelf items and clipboard history (pinned items never expire).
public enum RetentionPeriod: String, Codable, Sendable, CaseIterable {
    case off
    case oneDay
    case sevenDays
    case thirtyDays

    /// nil ⇒ keep forever.
    public var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .oneDay: return 86_400
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        }
    }

    public var displayName: String {
        switch self {
        case .off: return "Never"
        case .oneDay: return "After 1 day"
        case .sevenDays: return "After 7 days"
        case .thirtyDays: return "After 30 days"
        }
    }
}

public struct AppSettings: Codable, Sendable, Hashable {
    public static let userDefaultsKey = "sn.settings.v1"

    // MARK: General (notch-shell)
    public var closedMode: ClosedNotchMode = .island
    public var notchStyle: NotchStyle = .glass
    public var openOnHover: Bool = true
    /// Dwell over the physical notch before opening (seconds).
    public var hoverOpenDelay: Double = 0.15
    /// Grace period after the mouse leaves before closing (seconds).
    public var hoverCloseDelay: Double = 0.35
    public var hapticsEnabled: Bool = true
    /// Hide the notch UI while the frontmost app is fullscreen (red popups still show).
    public var hideInFullscreen: Bool = true
    public var showMenuBarIcon: Bool = true
    /// Mirrors SMAppService.mainApp status; the source of truth is the system, this is the user's wish.
    public var launchAtLogin: Bool = false
    public var onboardingCompleted: Bool = false

    // MARK: Hotkeys (notch-shell registers them). nil = disabled.
    public var toggleNotchHotkey: KeyCombo? = .toggleNotchDefault
    public var clipboardHotkey: KeyCombo? = .clipboardHistoryDefault

    // MARK: Claude (claude-app)
    public var claudeEnabled: Bool = true
    /// Pop open on 🔴 (question / permission).
    public var popupOnNeedsInput: Bool = true
    /// Pop open on 🟢 (done).
    public var popupOnDone: Bool = true
    /// Skip the 🟢 popup when the app hosting the session is frontmost.
    public var skipDoneWhenHostFrontmost: Bool = true
    /// Seconds before a 🟢 peek collapses by itself.
    public var doneAutoCollapse: Double = 4
    /// Generate 2–4 word titles with `claude -p --model haiku` when Claude Code has none.
    public var generateTitlesWithHaiku: Bool = true
    /// Explicit Claude config folder; nil ⇒ $CLAUDE_CONFIG_DIR ⇒ ~/.claude.
    public var claudeConfigDirOverride: String? = nil
    public var showUsageLimits: Bool = true
    /// 0…1. At or above ⇒ orange bar + warning dot in the closed notch.
    public var usageWarningThreshold: Double = 0.8
    /// Install the statusLine bridge (needed for usage limits).
    public var wrapStatusLine: Bool = true
    /// Dangerous commands need a second confirming click.
    public var confirmDangerousCommands: Bool = true

    // MARK: Music (media)
    public var spotifyEnabled: Bool = true
    public var showVisualizer: Bool = true

    // MARK: Shelf (shelf-clipboard)
    public var shelfEnabled: Bool = true
    public var showAirDropZone: Bool = true
    /// Shared by shelf and clipboard history (REQUIREMENTS "same cleanup setting").
    public var retention: RetentionPeriod = .sevenDays

    // MARK: Clipboard (shelf-clipboard)
    public var clipboardEnabled: Bool = true
    public var clipboardLimit: Int = 200
    public var captureImages: Bool = true
    /// Bundle ids whose copies are never recorded (password managers prefilled).
    public var clipboardIgnoredApps: [String] = AppSettings.defaultIgnoredApps

    public static let defaultIgnoredApps: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "in.sinew.Enpass-Desktop",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass",
        "com.nordpass.macos.NordPass",
        "me.proton.pass.electron",
    ]

    public init() {}

    public static let defaults = AppSettings()

    // MARK: Tolerant Codable

    private enum CodingKeys: String, CodingKey {
        case closedMode, notchStyle, openOnHover, hoverOpenDelay, hoverCloseDelay, hapticsEnabled
        case hideInFullscreen, showMenuBarIcon, launchAtLogin, onboardingCompleted
        case toggleNotchHotkey, clipboardHotkey
        case claudeEnabled, popupOnNeedsInput, popupOnDone, skipDoneWhenHostFrontmost, doneAutoCollapse
        case generateTitlesWithHaiku, claudeConfigDirOverride, showUsageLimits, usageWarningThreshold
        case wrapStatusLine, confirmDangerousCommands
        case spotifyEnabled, showVisualizer
        case shelfEnabled, showAirDropZone, retention
        case clipboardEnabled, clipboardLimit, captureImages, clipboardIgnoredApps
        // Present only when a hotkey was explicitly disabled (distinguishes "disabled" from "missing").
        case toggleNotchHotkeyDisabled, clipboardHotkeyDisabled
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? current
        }
        closedMode = read(.closedMode, closedMode)
        notchStyle = read(.notchStyle, notchStyle)
        openOnHover = read(.openOnHover, openOnHover)
        hoverOpenDelay = read(.hoverOpenDelay, hoverOpenDelay)
        hoverCloseDelay = read(.hoverCloseDelay, hoverCloseDelay)
        hapticsEnabled = read(.hapticsEnabled, hapticsEnabled)
        hideInFullscreen = read(.hideInFullscreen, hideInFullscreen)
        showMenuBarIcon = read(.showMenuBarIcon, showMenuBarIcon)
        launchAtLogin = read(.launchAtLogin, launchAtLogin)
        onboardingCompleted = read(.onboardingCompleted, onboardingCompleted)
        toggleNotchHotkey =
            read(.toggleNotchHotkeyDisabled, false) ? nil : read(.toggleNotchHotkey, .toggleNotchDefault)
        clipboardHotkey =
            read(.clipboardHotkeyDisabled, false) ? nil : read(.clipboardHotkey, .clipboardHistoryDefault)
        claudeEnabled = read(.claudeEnabled, claudeEnabled)
        popupOnNeedsInput = read(.popupOnNeedsInput, popupOnNeedsInput)
        popupOnDone = read(.popupOnDone, popupOnDone)
        skipDoneWhenHostFrontmost = read(.skipDoneWhenHostFrontmost, skipDoneWhenHostFrontmost)
        doneAutoCollapse = read(.doneAutoCollapse, doneAutoCollapse)
        generateTitlesWithHaiku = read(.generateTitlesWithHaiku, generateTitlesWithHaiku)
        claudeConfigDirOverride = read(.claudeConfigDirOverride, claudeConfigDirOverride)
        showUsageLimits = read(.showUsageLimits, showUsageLimits)
        usageWarningThreshold = read(.usageWarningThreshold, usageWarningThreshold)
        wrapStatusLine = read(.wrapStatusLine, wrapStatusLine)
        confirmDangerousCommands = read(.confirmDangerousCommands, confirmDangerousCommands)
        spotifyEnabled = read(.spotifyEnabled, spotifyEnabled)
        showVisualizer = read(.showVisualizer, showVisualizer)
        shelfEnabled = read(.shelfEnabled, shelfEnabled)
        showAirDropZone = read(.showAirDropZone, showAirDropZone)
        retention = read(.retention, retention)
        clipboardEnabled = read(.clipboardEnabled, clipboardEnabled)
        clipboardLimit = read(.clipboardLimit, clipboardLimit)
        captureImages = read(.captureImages, captureImages)
        clipboardIgnoredApps = read(.clipboardIgnoredApps, clipboardIgnoredApps)
        normalize()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(closedMode, forKey: .closedMode)
        try c.encode(notchStyle, forKey: .notchStyle)
        try c.encode(openOnHover, forKey: .openOnHover)
        try c.encode(hoverOpenDelay, forKey: .hoverOpenDelay)
        try c.encode(hoverCloseDelay, forKey: .hoverCloseDelay)
        try c.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try c.encode(hideInFullscreen, forKey: .hideInFullscreen)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(onboardingCompleted, forKey: .onboardingCompleted)
        try c.encodeIfPresent(toggleNotchHotkey, forKey: .toggleNotchHotkey)
        if toggleNotchHotkey == nil { try c.encode(true, forKey: .toggleNotchHotkeyDisabled) }
        try c.encodeIfPresent(clipboardHotkey, forKey: .clipboardHotkey)
        if clipboardHotkey == nil { try c.encode(true, forKey: .clipboardHotkeyDisabled) }
        try c.encode(claudeEnabled, forKey: .claudeEnabled)
        try c.encode(popupOnNeedsInput, forKey: .popupOnNeedsInput)
        try c.encode(popupOnDone, forKey: .popupOnDone)
        try c.encode(skipDoneWhenHostFrontmost, forKey: .skipDoneWhenHostFrontmost)
        try c.encode(doneAutoCollapse, forKey: .doneAutoCollapse)
        try c.encode(generateTitlesWithHaiku, forKey: .generateTitlesWithHaiku)
        try c.encodeIfPresent(claudeConfigDirOverride, forKey: .claudeConfigDirOverride)
        try c.encode(showUsageLimits, forKey: .showUsageLimits)
        try c.encode(usageWarningThreshold, forKey: .usageWarningThreshold)
        try c.encode(wrapStatusLine, forKey: .wrapStatusLine)
        try c.encode(confirmDangerousCommands, forKey: .confirmDangerousCommands)
        try c.encode(spotifyEnabled, forKey: .spotifyEnabled)
        try c.encode(showVisualizer, forKey: .showVisualizer)
        try c.encode(shelfEnabled, forKey: .shelfEnabled)
        try c.encode(showAirDropZone, forKey: .showAirDropZone)
        try c.encode(retention, forKey: .retention)
        try c.encode(clipboardEnabled, forKey: .clipboardEnabled)
        try c.encode(clipboardLimit, forKey: .clipboardLimit)
        try c.encode(captureImages, forKey: .captureImages)
        try c.encode(clipboardIgnoredApps, forKey: .clipboardIgnoredApps)
    }

    /// Clamps values into sane ranges (also applied after decoding).
    public mutating func normalize() {
        hoverOpenDelay = min(max(hoverOpenDelay, 0), 2)
        hoverCloseDelay = min(max(hoverCloseDelay, 0), 3)
        doneAutoCollapse = min(max(doneAutoCollapse, 1), 60)
        usageWarningThreshold = min(max(usageWarningThreshold, 0.5), 1)
        clipboardLimit = min(max(clipboardLimit, 20), 1000)
        if let dir = claudeConfigDirOverride, dir.trimmingCharacters(in: .whitespaces).isEmpty {
            claudeConfigDirOverride = nil
        }
    }

    // MARK: Data round trip helpers (used by SettingsStore and tests)

    public static func decode(from data: Data?) -> AppSettings {
        guard let data, let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}
