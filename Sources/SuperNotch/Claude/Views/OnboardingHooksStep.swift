// Owner: claude-app. Onboarding step 2 (SPEC §A.11): explain what changes, show the exact entries and the
// backup location, install with one click. Hosted by `OnboardingView` (notch-shell) in a normal window, so
// only semantic colours are used. Skipping is the wizard's "Next".

import AppKit
import SuperNotchCore
import SwiftUI

struct OnboardingHooksStep: View {
    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(SettingsStore.self) private var settingsStore

    init() {}

    var body: some View {
        @Bindable var store = settingsStore
        VStack(spacing: DesignTokens.Spacing.m) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Connect Claude Code")
                .font(.title2.weight(.semibold))
            Text(
                "SuperNotch shows your Claude Code sessions as 🟡 working, 🟢 done and 🔴 needs you, and lets you "
                    + "answer permission prompts in the notch. For that it adds small hooks to Claude Code's "
                    + "settings. Your other settings and hooks stay untouched."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Added to \(abbreviated(claude.settingsFilePath)):")
                    .font(.caption.weight(.medium))
                ClaudeHookPreview(text: claude.hookPreview)
                    .frame(maxHeight: 118)
                Text("A backup is saved to \(abbreviated(claude.backupDirectory)) first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show usage limits (wraps your status line)", isOn: $store.settings.wrapStatusLine)
                Text(
                    "Your status line keeps working. While any status line is set, Claude Code hides some footer "
                        + "hints such as \u{201C}esc to interrupt\u{201D}."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions

            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            claude.refreshHookStatus()
            claude.discoverConfigDirectories()
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            switch claude.hookStatus {
            case .installed:
                Label("Hooks installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(DesignTokens.Colors.trafficGreen)
            case .needsRepair:
                Button("Repair Hooks") { claude.installHooks() }
                    .buttonStyle(.borderedProminent)
                    .disabled(claude.isHookOperationRunning)
            case .notInstalled, .unknown:
                Button("Install Hooks") { claude.installHooks() }
                    .buttonStyle(.borderedProminent)
                    .disabled(claude.isHookOperationRunning || claude.hookStatus == .unknown)
            case .failed:
                Button("Check Again") { claude.refreshHookStatus() }
                Button("Show settings.json") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: claude.settingsFilePath)])
                }
            }
            if claude.isHookOperationRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        if let message = statusMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(claude.detectedConfigDirectories, id: \.self) { directory in
            HStack {
                Text("Also found \(abbreviated(directory))")
                    .font(.callout)
                Button("Install there too") { claude.installHooks(inConfigDirectory: directory) }
                    .disabled(claude.isHookOperationRunning)
            }
        }
    }

    /// Error details or the result of the last operation.
    private var statusMessage: String? {
        if let detail = claude.hookStatus.detail { return detail }
        return claude.hookMessage
    }

    private var hint: String {
        switch claude.hookStatus {
        case .installed:
            return "Running Claude Code sessions pick the hooks up automatically. You can remove them any time in "
                + "Settings › Claude."
        case .failed:
            return "Fix settings.json (it must be valid JSON), then check again. Nothing was changed."
        case .unknown, .notInstalled, .needsRepair:
            return "You can skip this step and install the hooks later in Settings › Claude."
        }
    }

    private func abbreviated(_ path: String) -> String {
        ClaudeFormat.abbreviatedPath(path)
    }
}
