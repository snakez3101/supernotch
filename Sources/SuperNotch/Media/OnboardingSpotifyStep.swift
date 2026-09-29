// Owner: media stream. Onboarding step 3 (SPEC §A.11): ask for Automation permission for Spotify.
// Hosted by `OnboardingView` (notch-shell) in a normal window (light or dark), so only semantic colours are used.
// Every state shows what is going on and a way forward (`MediaPermissionPresentation`): waiting for Spotify or
// macOS (spinner), "macOS didn't answer" (Try Again / Reset & Ask Again / System Settings), denied, the tccutil
// command when the reset could not run.
import AppKit
import SuperNotchCore
import SwiftUI

struct OnboardingSpotifyStep: View {
    @Environment(MediaModel.self) private var media

    init() {}

    var body: some View {
        let presentation = media.permissionPresentation
        VStack(spacing: DesignTokens.Spacing.l) {
            Image(systemName: "music.note")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Control Spotify")
                .font(.title2.weight(.semibold))
            Text(
                "SuperNotch shows what's playing and lets you pause, skip and seek. It talks to the Spotify desktop "
                    + "app through macOS Automation: no Spotify login, only cover images are loaded from Spotify."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            MediaPermissionStatusLabel(presentation: presentation)
                .font(.callout)

            if let detail = presentation.detail, presentation.tone != .allowed {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let command = presentation.terminalCommand {
                MediaTerminalCommandView(command: command)
                    .frame(maxWidth: 440)
            }

            actions(for: presentation)

            Text(hint(for: presentation))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { media.recheckAutomationPermission() }
        // The system prompt and System Settings take focus away; check again when the user returns.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            media.recheckAutomationPermission()
        }
    }

    @ViewBuilder
    private func actions(for presentation: MediaPermissionPresentation) -> some View {
        if presentation.tone == .allowed {
            Label("Spotify is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.Colors.trafficGreen)
        } else if !presentation.actions.isEmpty {
            MediaPermissionActions(prominentPrimary: true)
        }
    }

    private func hint(for presentation: MediaPermissionPresentation) -> String {
        switch presentation.tone {
        case .allowed:
            return "You can change this any time in Settings > Music."
        case .busy:
            return "This can take a few seconds. Look for the macOS dialog."
        case .attention, .blocked, .inactive:
            return "You can skip this step and allow it later in Settings > Music."
        }
    }
}
