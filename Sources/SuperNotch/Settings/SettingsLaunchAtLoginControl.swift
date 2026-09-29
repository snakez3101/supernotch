// Owner: notch-shell (SPEC §A.10 General, §A.11 Done step).
//
// The "Launch at login" toggle shared by Settings › General (rows of a grouped Form) and the onboarding Done step
// (centred). It always shows the real state (`NotchLoginItem.currentOutcome()`), read when it appears and whenever
// SuperNotch becomes active again (e.g. back from System Settings › Login Items). Waiting for approval shows a hint
// and a button; errors and the LaunchAgent fallback show as small secondary text, never silently.
import AppKit
import SuperNotchCore
import SwiftUI

struct SettingsLaunchAtLoginControl: View {
    enum Layout {
        /// Separate rows inside a grouped `Form` section.
        case form
        /// Centred, for the onboarding Done step.
        case centered
    }

    let title: String
    let layout: Layout

    @Environment(SettingsStore.self) private var settingsStore
    @State private var outcome = NotchLoginItem.Outcome(state: .disabled, message: nil)

    init(title: String, layout: Layout) {
        self.title = title
        self.layout = layout
    }

    var body: some View {
        Group {
            toggle
                .onAppear {
                    refresh(keepingMessage: false)
                }
                .onReceive(appDidBecomeActive) { _ in
                    refresh(keepingMessage: true)
                }
                .onChange(of: settingsStore.settings.launchAtLogin) {
                    // Changed by the other copy of this control (Settings and onboarding can both be open).
                    refresh(keepingMessage: true)
                }
            if outcome.state == .requiresApproval {
                approvalHint
            }
            if let message = outcome.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(isForm ? TextAlignment.leading : TextAlignment.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: messageMaxWidth, alignment: isForm ? Alignment.leading : Alignment.center)
            }
        }
    }

    private var isForm: Bool { layout == .form }

    private var messageMaxWidth: CGFloat { isForm ? CGFloat.infinity : 420 }

    /// Back from System Settings (approval) or another app: the state may have changed.
    private var appDidBecomeActive: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    }

    @ViewBuilder private var toggle: some View {
        switch layout {
        case .form:
            Toggle(title, isOn: binding)
        case .centered:
            Toggle(title, isOn: binding)
                .toggleStyle(.switch)
        }
    }

    @ViewBuilder private var approvalHint: some View {
        switch layout {
        case .form:
            LabeledContent {
                Button("Open Login Items") {
                    NotchLoginItem.openSystemSettings()
                }
            } label: {
                Text("Needs your approval")
                Text("Allow SuperNotch in System Settings › General › Login Items.")
            }
        case .centered:
            VStack(spacing: 4) {
                Text("Allow SuperNotch in System Settings › General › Login Items to finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items") {
                    NotchLoginItem.openSystemSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { outcome.state.isOn },
            set: { enabled in
                apply(enabled)
            })
    }

    private func apply(_ enabled: Bool) {
        guard enabled != outcome.state.isOn else { return }
        let result = NotchLoginItem.setEnabled(enabled)
        outcome = result
        if settingsStore.settings.launchAtLogin != result.state.isOn {
            settingsStore.settings.launchAtLogin = result.state.isOn
        }
    }

    /// Reads the real state. `keepingMessage`: keep a message the user may still be reading if nothing changed.
    private func refresh(keepingMessage: Bool) {
        let fresh = NotchLoginItem.currentOutcome()
        if keepingMessage, fresh.state == outcome.state, outcome.message != nil { return }
        outcome = fresh
    }
}
