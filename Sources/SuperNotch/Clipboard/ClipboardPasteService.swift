// Owner: shelf-clipboard (SPEC §A.4, §D.4). Writing history entries back to the pasteboard and pasting them.
//
// * Every write carries our marker type (`ClipboardCaptureFilter.ownMarkerType`) so the monitor never records
//   it again; file URLs go through `writeObjects` with one item per file (multi-file paste works, Maccy #…).
// * Paste = write, then post ⌘V with CGEvent. That needs the PostEvent permission (listed under
//   Privacy & Security › Accessibility): `CGPreflightPostEventAccess` / `CGRequestPostEventAccess`. Without it
//   we only copy and tell the user to press ⌘V.
// * ⌘V is posted as virtual key 9 (kVK_ANSI_V): right for QWERTY/QWERTZ/AZERTY and "Dvorak – QWERTY ⌘".
// Pattern adapted from Maccy (MIT, © Alex Rodionov): marker type on own writes, writeObjects for file URLs,
// CGEvent ⌘V on the session event tap.
import AppKit
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

    /// Sends ⌘V to the frontmost app. Callers check `hasPostEventAccess` first.
    nonisolated static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9  // kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
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
