// Owner: shelf-clipboard. Onboarding step 4 (SPEC §A.11): paste permission (PostEvent, listed under
// Accessibility) and the note about macOS pasteboard privacy. Skippable; the app works without it (Return then
// copies instead of pasting).
// Hosted by `OnboardingView` (notch-shell) in a normal window (light or dark), so only semantic colours are used.
import AppKit
import SuperNotchCore
import SwiftUI

struct OnboardingPasteStep: View {
    @Environment(ClipboardModel.self) private var clipboard
    @Environment(SettingsStore.self) private var settingsStore

    init() {}

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Clipboard History")
                .font(.title2.weight(.semibold))
            Text(
                "Press \(shortcut) to see what you copied recently and press Return to paste it into the app "
                    + "you're typing in. Passwords from password managers are never recorded, and everything "
                    + "stays on this Mac."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            permissionStatus

            Text(
                "Pasting needs SuperNotch to be allowed under System Settings › Privacy & Security › "
                    + "Accessibility. Without it, Return copies the item and you press ⌘V yourself. macOS may also "
                    + "ask once whether SuperNotch can read what you copy: choose Allow to build your history."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { clipboard.refreshPermissions() }
        // The system prompt and System Settings take focus away; check again when the user returns.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            clipboard.refreshPermissions()
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        if clipboard.canPaste {
            Label("Pasting with Return is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.Colors.trafficGreen)
        } else {
            HStack {
                Button("Allow Pasting") { clipboard.requestPastePermission() }
                    .buttonStyle(.borderedProminent)
                Button("Open System Settings") { clipboard.openAccessibilitySettings() }
            }
        }
    }

    private var shortcut: String {
        settingsStore.settings.clipboardHotkey?.description ?? "the clipboard shortcut"
    }
}
