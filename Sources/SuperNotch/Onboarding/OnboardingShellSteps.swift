// Owner: notch-shell (SPEC §A.11 steps 1 and 5).
//
// Welcome: what SuperNotch does, and that everything stays on this Mac.
// Done: launch at login and a hotkey cheat-sheet.
import AppKit
import SuperNotchCore
import SwiftUI

struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
            }
            Text("Welcome to SuperNotch")
                .font(.title.weight(.semibold))
            Text("A small, quiet notch that shows what matters and stays out of the way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                OnboardingFeatureRow(
                    symbol: "sparkles", title: "Claude Code at a glance",
                    detail: "Working, done or needs you. Answer permission requests right in the notch.")
                OnboardingFeatureRow(
                    symbol: "music.note", title: "Spotify",
                    detail: "Cover, title and artist, play, pause, skip and seek.")
                OnboardingFeatureRow(
                    symbol: "tray.full", title: "Shelf and AirDrop",
                    detail: "Drop files on the notch and drag them out again later.")
                OnboardingFeatureRow(
                    symbol: "doc.on.clipboard", title: "Clipboard history",
                    detail: "Press ⌥⌘V, pick an entry and press Return to paste it.")
            }
            .padding(.top, 4)

            Label("Everything stays on this Mac.", systemImage: "lock.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingFeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingDoneStep: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        let settings = settingsStore.settings
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("You're all set")
                .font(.title2.weight(.semibold))
            Text("Rest the pointer on the notch to open it. You can change everything later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                SettingsLaunchAtLoginControl(title: "Launch SuperNotch at login", layout: .centered)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 7) {
                    OnboardingShortcutRow(
                        keys: settings.toggleNotchHotkey?.description ?? "Off", action: "Open or close the notch")
                    OnboardingShortcutRow(
                        keys: settings.clipboardHotkey?.description ?? "Off",
                        action: "Clipboard history, Return pastes")
                    OnboardingShortcutRow(keys: "Esc", action: "Close the notch")
                    OnboardingShortcutRow(keys: "Drag a file", action: "Drop it on the notch: shelf or AirDrop")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                Text("Shortcuts")
            }
            .frame(maxWidth: 420)

            if settings.clipboardHotkey == .clipboardHistoryDefault {
                Text(
                    "⌥⌘V is also Finder's \"Move Item Here\". Pick another shortcut in Settings › Shortcuts "
                        + "if you use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(keys)
                .font(.callout.monospaced().weight(.medium))
                .frame(width: 96, alignment: .leading)
            Text(action)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
