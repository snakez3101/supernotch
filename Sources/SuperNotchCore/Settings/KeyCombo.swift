import Foundation

// FOUNDATION-OWNED (SPEC §D.3). A global hotkey as Carbon understands it (RegisterEventHotKey).

public struct KeyCombo: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Carbon virtual key code (kVK_*), e.g. kVK_ANSI_N = 45, kVK_ANSI_V = 9.
    public var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | optionKey | …), NOT NSEvent.ModifierFlags.
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    // Carbon modifier bits (Carbon.HIToolbox/Events.h). Duplicated so Core stays Foundation-only.
    public static let cmdKey: UInt32 = 1 << 8  // 0x0100
    public static let shiftKey: UInt32 = 1 << 9  // 0x0200
    public static let optionKey: UInt32 = 1 << 11  // 0x0800
    public static let controlKey: UInt32 = 1 << 12  // 0x1000

    /// ⌥⌘N: open/close the notch.
    public static let toggleNotchDefault = KeyCombo(keyCode: 45, carbonModifiers: optionKey | cmdKey)
    /// ⌥⌘V: clipboard history.
    public static let clipboardHistoryDefault = KeyCombo(keyCode: 9, carbonModifiers: optionKey | cmdKey)

    public var hasCommand: Bool { carbonModifiers & Self.cmdKey != 0 }
    public var hasOption: Bool { carbonModifiers & Self.optionKey != 0 }
    public var hasShift: Bool { carbonModifiers & Self.shiftKey != 0 }
    public var hasControl: Bool { carbonModifiers & Self.controlKey != 0 }

    /// A global hotkey needs ⌘ or ⌃. Shift alone would swallow normal typing, and macOS 15+ refuses
    /// `RegisterEventHotKey` combinations whose only modifiers are ⌥ or ⌥⇧.
    public var isValidGlobalHotkey: Bool { hasCommand || hasControl }

    /// "⌥⌘N". Modifier order follows Apple HIG: ⌃ ⌥ ⇧ ⌘.
    public var description: String {
        var text = ""
        if hasControl { text += "⌃" }
        if hasOption { text += "⌥" }
        if hasShift { text += "⇧" }
        if hasCommand { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// US-layout names for display only (the recorder may show the layout-specific character instead).
    public static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
            13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
            35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
            46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 122: "F1", 120: "F2", 99: "F3",
            118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}
