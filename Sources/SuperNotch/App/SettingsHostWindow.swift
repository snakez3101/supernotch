// Owner: FOUNDATION (SPEC §A.10, §A.11, §D.10).
//
// Titled window for Settings and onboarding. SuperNotch is an accessory app at all times (no Dock icon, no
// menu bar), so the main menu is never on screen. Its key equivalents still work, but as a fallback this window
// also routes the standard editing shortcuts (⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z) to the first responder, so text fields
// always support cut, copy, paste, select all and undo.
import AppKit

final class SettingsHostWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown, let action = Self.editingAction(for: event) else { return false }
        return NSApplication.shared.sendAction(action, to: nil, from: self)
    }

    private static func editingAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        if flags == [.command, .shift] {
            return key == "z" ? Selector(("redo:")) : nil
        }
        guard flags == .command else { return nil }
        switch key {
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return Selector(("undo:"))
        default: return nil
        }
    }
}
