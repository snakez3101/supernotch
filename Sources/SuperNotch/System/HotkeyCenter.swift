// Owner: notch-shell (SPEC §A.4, §B, §F.4 #2 and #11).
//
// Global hotkeys via Carbon `RegisterEventHotKey`: works while another app is active and needs no
// Accessibility permission. One Carbon event handler serves every registered hotkey; the handler is a
// capture-free C callback that finds this object through the `userData` pointer.
//
// Pattern (not code) follows soffes/HotKey and sindresorhus/KeyboardShortcuts (both MIT).
import AppKit
import Carbon.HIToolbox
import SuperNotchCore
import os

/// The app's global shortcuts (SPEC §A.4). Raw values double as Carbon hotkey ids.
enum HotkeyAction: UInt32, CaseIterable, Hashable {
    /// ⌥⌘N by default: open/close the notch.
    case toggleNotch = 1
    /// ⌥⌘V by default: clipboard history panel.
    case clipboardHistory = 2

    var title: String {
        switch self {
        case .toggleNotch: return "Open or close the notch"
        case .clipboardHistory: return "Clipboard history"
        }
    }
}

final class HotkeyCenter {
    /// "SNOT": identifies our hotkeys in the shared Carbon event stream.
    nonisolated static let signature: OSType = 0x534E_4F54

    private struct Registration {
        let combo: KeyCombo
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandlerRef: EventHandlerRef?

    init() {}

    /// Currently registered actions.
    var registeredActions: Set<HotkeyAction> {
        Set(registrations.keys.compactMap { HotkeyAction(rawValue: $0) })
    }

    /// Registers (or re-registers) `combo` for `action`. Returns false if macOS refused it, e.g. because
    /// another app already owns the combination.
    @discardableResult
    func register(_ combo: KeyCombo, for action: HotkeyAction, handler: @escaping () -> Void) -> Bool {
        unregister(action)
        guard combo.isValidGlobalHotkey else {
            // macOS 15+ refuses ⌥-only / ⌥⇧ global hotkeys, so ⌘ or ⌃ is required (KeyCombo.isValidGlobalHotkey).
            Log.system.error("Refusing hotkey without ⌘ or ⌃ for \(String(describing: action), privacy: .public)")
            return false
        }
        guard installEventHandlerIfNeeded() else { return false }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.system.error(
                "Hotkey \(combo.description, privacy: .public) unavailable (OSStatus \(status, privacy: .public))")
            return false
        }
        registrations[action.rawValue] = Registration(combo: combo, ref: ref, handler: handler)
        let name = String(describing: action)
        Log.system.info("Registered hotkey \(combo.description, privacy: .public) for \(name, privacy: .public)")
        return true
    }

    func unregister(_ action: HotkeyAction) {
        guard let registration = registrations.removeValue(forKey: action.rawValue) else { return }
        let status = UnregisterEventHotKey(registration.ref)
        if status != noErr {
            Log.system.error("UnregisterEventHotKey failed (OSStatus \(status, privacy: .public))")
        }
    }

    /// Unregisters every hotkey and removes the Carbon event handler.
    func unregisterAll() {
        for action in HotkeyAction.allCases {
            unregister(action)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    // MARK: Carbon plumbing

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(), HotkeyCarbonBridge.handler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr, let handlerRef else {
            Log.system.error("InstallEventHandler failed (OSStatus \(status, privacy: .public))")
            return false
        }
        eventHandlerRef = handlerRef
        return true
    }

    /// Called on the main thread by the Carbon callback.
    fileprivate func handleHotKey(id: UInt32) -> Bool {
        guard let registration = registrations[id] else { return false }
        registration.handler()
        return true
    }

    /// Entry point for `HotkeyCarbonBridge` (keeps `handleHotKey` fileprivate).
    fileprivate static func dispatch(id: UInt32, userData: UnsafeMutableRawPointer) -> Bool {
        let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
        return center.handleHotKey(id: id)
    }
}

/// The capture-free C callback (SPEC §F.4 #2). Carbon delivers hotkey events on the main thread.
private nonisolated enum HotkeyCarbonBridge {
    static let handler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else {
            return OSStatus(eventNotHandledErr)
        }
        let id = hotKeyID.id
        let handled = MainActor.assumeIsolated {
            HotkeyCenter.dispatch(id: id, userData: userData)
        }
        return handled ? noErr : OSStatus(eventNotHandledErr)
    }
}
