// Owner: notch-shell (SPEC §A.4, §A.10 Shortcuts).
//
// Recorders for the two global shortcuts (⌥⌘N notch, ⌥⌘V clipboard history). While a recorder listens, the
// global hotkeys are suspended so the current combination reaches it instead of firing.
import AppKit
import Observation
import SuperNotchCore
import SwiftUI

struct SettingsShortcutsPane: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(NotchViewModel.self) private var notch

    var body: some View {
        @Bindable var store = settingsStore
        Form {
            Section {
                LabeledContent(HotkeyAction.toggleNotch.title) {
                    SettingsHotkeyRecorder(combo: $store.settings.toggleNotchHotkey, defaultCombo: .toggleNotchDefault)
                }
                if notch.hotkeyConflicts.contains(.toggleNotch) {
                    SettingsHotkeyConflictNote()
                }
                LabeledContent(HotkeyAction.clipboardHistory.title) {
                    SettingsHotkeyRecorder(
                        combo: $store.settings.clipboardHotkey, defaultCombo: .clipboardHistoryDefault)
                }
                .disabled(!store.settings.clipboardEnabled)
                if notch.hotkeyConflicts.contains(.clipboardHistory) {
                    SettingsHotkeyConflictNote()
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Click a shortcut and press the new keys, using ⌘ or ⌃. Esc cancels, Delete turns it off. "
                    + "Shortcuts work in every app and need no Accessibility permission.")
            }

            Section {
                LabeledContent("Close the notch") {
                    Text("Esc").foregroundStyle(.secondary)
                }
                LabeledContent("Allow / Deny a permission request") {
                    Text("Return / Esc").foregroundStyle(.secondary)
                }
            } header: {
                Text("In the notch")
            } footer: {
                Text("Keys only reach the notch after you click into it or open it with the shortcut, so typing "
                    + "in another app can never answer a request by accident.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsHotkeyConflictNote: View {
    var body: some View {
        Label("This shortcut is used by another app. Choose a different one.", systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
    }
}

/// Click to record a new global shortcut.
struct SettingsHotkeyRecorder: View {
    @Binding var combo: KeyCombo?
    let defaultCombo: KeyCombo

    @Environment(NotchViewModel.self) private var notch
    @State private var recorder = SettingsKeyRecorder()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if recorder.isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(title)
                    .monospacedDigit()
                    .frame(minWidth: 118)
            }
            .help(recorder.isRecording ? "Press the new shortcut" : "Click to change")
            if !recorder.isRecording && combo != nil {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Turn this shortcut off")
                .accessibilityLabel("Turn this shortcut off")
            }
            if !recorder.isRecording && combo != defaultCombo {
                Button("Use \(defaultCombo.description)") {
                    combo = defaultCombo
                }
                .buttonStyle(.borderless)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let hint = recorder.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize()
                    .offset(y: 16)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var title: String {
        if recorder.isRecording { return "Press shortcut…" }
        return combo?.description ?? "Off"
    }

    private func startRecording() {
        notch.setHotkeysSuspended(true)
        recorder.start { result in
            switch result {
            case .set(let newCombo):
                combo = newCombo
            case .clear:
                combo = nil
            case .cancel:
                break
            }
            notch.setHotkeysSuspended(false)
        }
    }

    private func stopRecording() {
        guard recorder.isRecording else { return }
        recorder.stop()
        notch.setHotkeysSuspended(false)
    }
}

/// Captures one key combination from the Settings window with a local key-down monitor.
@Observable
final class SettingsKeyRecorder {
    enum Result {
        case set(KeyCombo)
        case clear
        case cancel
    }

    private(set) var isRecording = false
    /// Why the last key press was not accepted.
    private(set) var hint: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var completion: ((Result) -> Void)?

    init() {}

    func start(completion: @escaping (Result) -> Void) {
        stop()
        self.completion = completion
        hint = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                self?.handle(keyCode: keyCode, flags: flags) ?? false
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        completion = nil
        isRecording = false
    }

    /// Returns true when the key press was consumed.
    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard isRecording else { return false }
        let modifiers = flags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty {
            switch keyCode {
            case 53:  // Esc
                finish(.cancel)
            case 51, 117:  // Delete, Forward Delete
                finish(.clear)
            default:
                hint = "Add ⌘ or ⌃ to the shortcut."
            }
            return true
        }
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= KeyCombo.cmdKey }
        if modifiers.contains(.option) { carbon |= KeyCombo.optionKey }
        if modifiers.contains(.control) { carbon |= KeyCombo.controlKey }
        if modifiers.contains(.shift) { carbon |= KeyCombo.shiftKey }
        let combo = KeyCombo(keyCode: UInt32(keyCode), carbonModifiers: carbon)
        // macOS 15+ refuses global hotkeys whose only modifiers are ⌥ or ⌥⇧.
        guard combo.hasCommand || combo.hasControl else {
            hint = "Use ⌘ or ⌃; macOS does not allow ⌥ alone."
            return true
        }
        finish(.set(combo))
        return true
    }

    private func finish(_ result: Result) {
        let handler = completion
        stop()
        hint = nil
        handler?(result)
    }
}
