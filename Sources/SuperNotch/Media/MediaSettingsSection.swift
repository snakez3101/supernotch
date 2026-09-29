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
        let presentation = media.permissionPresentation
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
                        + "There is no Spotify login; only cover images are loaded from Spotify."
                )
            }

            Section {
                LabeledContent("Automation") {
                    MediaPermissionStatusLabel(presentation: presentation)
                }
                if let detail = presentation.detail, presentation.tone != .allowed {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command = presentation.terminalCommand {
                    MediaTerminalCommandView(command: command)
                }
                if !presentation.actions.isEmpty {
                    MediaPermissionActions()
                }
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

/// Status dot (a spinner while a request runs) plus a short sentence for the current Automation state.
struct MediaPermissionStatusLabel: View {
    let presentation: MediaPermissionPresentation

    init(presentation: MediaPermissionPresentation) {
        self.presentation = presentation
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            if presentation.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(presentation.status)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch presentation.tone {
        case .allowed: return DesignTokens.Colors.trafficGreen
        case .blocked: return DesignTokens.Colors.trafficRed
        case .attention: return DesignTokens.Colors.warningOrange
        case .inactive, .busy: return DesignTokens.Colors.trafficGrey
        }
    }
}

/// The buttons that fit the current state (`MediaPermissionPresentation.actions`, primary first).
struct MediaPermissionActions: View {
    @Environment(MediaModel.self) private var media
    /// Onboarding draws the first button prominent.
    let prominentPrimary: Bool

    init(prominentPrimary: Bool = false) {
        self.prominentPrimary = prominentPrimary
    }

    var body: some View {
        let actions = media.permissionPresentation.actions
        HStack(spacing: DesignTokens.Spacing.m) {
            ForEach(actions, id: \.self) { action in
                button(for: action, isPrimary: prominentPrimary && action == actions.first)
            }
        }
    }

    @ViewBuilder
    private func button(for action: MediaPermissionAction, isPrimary: Bool) -> some View {
        if isPrimary {
            Button(action.title) { media.perform(action) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(action.title) { media.perform(action) }
        }
    }
}

/// The `tccutil` fallback: monospaced, selectable, copyable with the "Copy Command" action.
struct MediaTerminalCommandView: View {
    let command: String

    init(command: String) {
        self.command = command
    }

    var body: some View {
        Text(command)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(2)
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, DesignTokens.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous))
    }
}
