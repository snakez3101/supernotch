// Owner: media stream. Onboarding step 3 (SPEC §A.11): ask for Automation permission for Spotify.
// Hosted by `OnboardingView` (notch-shell) in a normal window (light or dark), so only semantic colours are used.
import AppKit
import SuperNotchCore
import SwiftUI

struct OnboardingSpotifyStep: View {
    @Environment(MediaModel.self) private var media

    init() {}

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Image(systemName: "music.note")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Control Spotify")
                .font(.title2.weight(.semibold))
            Text(
                "SuperNotch shows what's playing and lets you pause, skip and seek. It talks to the Spotify desktop "
                    + "app through macOS Automation: no Spotify login, and nothing leaves your Mac."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            MediaPermissionStatusLabel(permission: media.automationPermission)
                .font(.callout)

            actions

            Text(hint)
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
    private var actions: some View {
        switch media.automationPermission {
        case .granted:
            Label("Spotify is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.Colors.trafficGreen)
        case .denied:
            HStack {
                Button("Open System Settings") { media.openAutomationSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Check Again") { media.recheckAutomationPermission() }
            }
        case .unknown:
            Button("Allow Access to Spotify") { media.requestAutomationPermission() }
                .buttonStyle(.borderedProminent)
        case .notRunning:
            Button("Open Spotify and Allow Access") { media.requestAutomationPermission() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var hint: String {
        switch media.automationPermission {
        case .granted:
            return "You can change this any time in Settings > Music."
        case .denied:
            return "Turn on SuperNotch under Privacy & Security > Automation > Spotify, then come back."
        case .unknown, .notRunning:
            return "Spotify has to be running for macOS to ask. You can skip this step and allow it later in Settings > Music."
        }
    }
}
