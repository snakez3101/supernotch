// Owner: shelf-clipboard (SPEC §A.4, §D.4). Writing history entries back to the pasteboard and pasting them.
//
// * Every write carries our marker type (`ClipboardCaptureFilter.ownMarkerType`) so the monitor never records
//   it again; file URLs go through `writeObjects` with one item per file (multi-file paste works, Maccy #…).
// * Paste = write, then post ⌘V with CGEvent. That needs the PostEvent permission (listed under
//   Privacy & Security › Accessibility): `CGPreflightPostEventAccess` / `CGRequestPostEventAccess`. Without it
//   we only copy and tell the user to press ⌘V.
// * ⌘V is posted on the key that types "v" in the current keyboard layout (Dvorak, Colemak, …), found with
//   `UCKeyTranslate`; layouts that switch to QWERTY while ⌘ is held ("Dvorak – QWERTY ⌘") and layouts without a
//   "v" (Cyrillic, Greek, …, which use the ASCII-capable layout for shortcuts) are handled; fallback is
//   kVK_ANSI_V (9). Text Input Source calls must run on the main thread, so the paste path is main-actor.
// Pattern adapted from Maccy (MIT, © Alex Rodionov): marker type on own writes, writeObjects for file URLs,
// CGEvent ⌘V on the session event tap with the left-⌘ device flag, forced QWERTY for "… ⌘" layouts.
import AppKit
import Carbon
import CoreGraphics
import SuperNotchCore

/// macOS pasteboard privacy (macOS 15.4+ "Paste from Other Apps") as far as it affects automatic capture.
enum ClipboardPasteboardAccess: Equatable {
    /// Reading is allowed.
    case allowed
    /// Not decided yet: macOS asks once on the first read.
    case notDecided
    /// macOS asks every time: automatic capture would prompt on every copy, so it pauses.
    case asksEachTime
    /// Reading is denied: nothing can be captured.
    case denied

    var allowsAutomaticCapture: Bool { self == .allowed || self == .notDecided }

    var summary: String {
        switch self {
        case .allowed: return "Allowed"
        case .notDecided: return "macOS will ask on the first copy"
        case .asksEachTime: return "Set to Ask: history is paused"
        case .denied: return "Denied: history can't record"
        }
    }
}

enum ClipboardPasteService {
    static let ownMarkerType = NSPasteboard.PasteboardType(ClipboardCaptureFilter.ownMarkerType)
    private static let accessibilitySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let privacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy"

    // MARK: Writing

    /// Puts `entry` on the general pasteboard (with our marker). Returns the new change count, nil on failure.
    static func write(_ entry: ClipboardEntry, imageURL: URL?) -> Int? {
        var items: [NSPasteboardItem] = []
        switch entry.content {
        case .text(let text):
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            items.append(item)
        case .link(let link):
            let item = NSPasteboardItem()
            item.setString(link, forType: .string)
            if URL(string: link)?.scheme != nil { item.setString(link, forType: .URL) }
            items.append(item)
        case .image:
            guard let imageURL, let data = try? Data(contentsOf: imageURL) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            items.append(item)
        case .files(let paths):
            let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
            for path in existing {
                let item = NSPasteboardItem()
                item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                items.append(item)
            }
        }
        guard let first = items.first else { return nil }
        first.setString("", forType: ownMarkerType)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            Log.clipboard.error("Writing to the pasteboard failed")
            return nil
        }
        return pasteboard.changeCount
    }

    // MARK: Paste permission (PostEvent)

    static var hasPostEventAccess: Bool {
        CGPreflightPostEventAccess()
    }

    /// Shows the system prompt the first time; afterwards macOS only lists us in System Settings.
    @discardableResult
    static func requestPostEventAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    /// Sends ⌘V to the frontmost app. Callers check `hasPostEventAccess` first. Main thread only (layout lookup).
    static func postCommandV() {
        let vKey = commandVKeyCode()
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        // ⌘ plus the left-⌘ device bit (NX_DEVICELCMDKEYMASK): some apps check which ⌘ key is down.
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0000_0008)
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    // MARK: Keyboard layout (which key types "v")

    /// kVK_ANSI_V: the "V" key position on ANSI/ISO keyboards.
    private static let ansiVKeyCode: CGKeyCode = 9
    /// U+0076 "v".
    private static let lowercaseV: UniChar = 0x76

    /// Virtual key code whose ⌘ shortcut is ⌘V in the current layout (falls back to 9).
    private static func commandVKeyCode() -> CGKeyCode {
        let current: Unmanaged<TISInputSource>? = TISCopyCurrentKeyboardLayoutInputSource()
        guard let layout = current?.takeRetainedValue() else { return ansiVKeyCode }
        // "Dvorak – QWERTY ⌘", "bépo – AZERTY ⌘": these type QWERTY/AZERTY while ⌘ is held (Maccy #482, #520).
        if localizedName(of: layout).hasSuffix("⌘") { return ansiVKeyCode }
        if let code = keyCode(typing: lowercaseV, in: layout) { return code }
        // No "v" in this layout (Cyrillic, Greek, Hebrew, …): shortcuts use the ASCII-capable layout.
        let ascii: Unmanaged<TISInputSource>? = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()
        if let asciiLayout = ascii?.takeRetainedValue(), let code = keyCode(typing: lowercaseV, in: asciiLayout) {
            return code
        }
        return ansiVKeyCode
    }

    private static func localizedName(of source: TISInputSource) -> String {
        let raw: UnsafeMutableRawPointer? = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
        guard let raw else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// The key (0…127) that types `character` without modifiers in `source`, nil if none does.
    private static func keyCode(typing character: UniChar, in source: TISInputSource) -> CGKeyCode? {
        let raw: UnsafeMutableRawPointer? = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        guard let raw else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        let bytes: UnsafePointer<UInt8>? = CFDataGetBytePtr(layoutData)
        guard let bytes else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        let maxLength = 4
        var characters = [UniChar](repeating: 0, count: maxLength)
        for code in 0..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            let status = UCKeyTranslate(
                keyboardLayout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, maxLength, &length, &characters)
            if status == 0, length == 1, characters[0] == character {
                return CGKeyCode(code)
            }
        }
        return nil
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: accessibilitySettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openPrivacySettings() {
        guard let url = URL(string: privacySettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Pasteboard privacy (macOS 15.4+)

    static var pasteboardAccess: ClipboardPasteboardAccess {
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        case .ask: return .asksEachTime
        case .default: return .notDecided
        @unknown default: return .notDecided
        }
    }
}
