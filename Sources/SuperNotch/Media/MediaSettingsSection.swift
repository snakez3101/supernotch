// Owner: media stream. Settings > Music (SPEC §A.10): enable Spotify, visualizer, Automation permission status.
//
// Hosting note: this view brings its own grouped `Form`; put it directly in the Settings detail pane.
import AppKit
import SuperNotchCore
import SwiftUI

struct MediaSettingsSection: View {
    @Environment(MediaModel.self) private var media
    @Environment(SettingsStore.self) private var settingsStore

    init() {}

    var body: some View {
        @Bindable var store = settingsStore
        Form {
            Section {
                Toggle("Enable Spotify", isOn: $store.settings.spotifyEnabled)
                Toggle("Animated bars in the closed notch", isOn: $store.settings.showVisualizer)
                    .disabled(!store.settings.spotifyEnabled)
            } header: {
                Text("Spotify")
            } footer: {
                Text(
                    "Shows the current track and controls the Spotify desktop app: play, pause, skip and seek. "
                        + "There is no Spotify login, and nothing leaves your Mac."
                )
            }

            Section {
                LabeledContent("Automation") {
                    MediaPermissionStatusLabel(permission: media.automationPermission)
                }
                MediaPermissionActions()
            } header: {
                Text("Permission")
            } footer: {
                Text(
                    "macOS asks once, and only while Spotify is running. You can change it later in "
                        + "System Settings > Privacy & Security > Automation."
                )
            }
            .disabled(!store.settings.spotifyEnabled)
        }
        .formStyle(.grouped)
        .onAppear { media.recheckAutomationPermission() }
        // Coming back from System Settings: pick up a changed grant without a manual "Check again".
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            media.recheckAutomationPermission()
        }
    }
}

/// Status dot plus a short sentence for the current Automation state.
struct MediaPermissionStatusLabel: View {
    let permission: MediaAutomationPermission

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch permission {
        case .granted: return DesignTokens.Colors.trafficGreen
        case .denied: return DesignTokens.Colors.trafficRed
        case .unknown: return DesignTokens.Colors.warningOrange
        case .notRunning: return DesignTokens.Colors.trafficGrey
        }
    }

    private var text: String {
        switch permission {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .unknown: return "Not allowed yet"
        case .notRunning: return "Spotify isn't running"
        }
    }
}

/// The buttons that fit the current state: ask, open System Settings, launch Spotify, re-check.
struct MediaPermissionActions: View {
    @Environment(MediaModel.self) private var media

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            switch media.automationPermission {
            case .granted:
                EmptyView()
            case .denied:
                Button("Open System Settings") { media.openAutomationSettings() }
            case .unknown:
                Button("Allow Access") { media.requestAutomationPermission() }
            case .notRunning:
                Button("Open Spotify and Allow Access") { media.requestAutomationPermission() }
            }
            Button("Check Again") { media.recheckAutomationPermission() }
        }
    }
}
