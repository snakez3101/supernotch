// Owner: notch-shell (SPEC §A.10 General).
//
// Settings › General (startup, menu-bar icon, setup assistant, reset) and Settings › Notch (closed style,
// glass or solid black, hover behaviour, haptics, fullscreen).
import AppKit
import SuperNotchCore
import SwiftUI

struct SettingsGeneralPane: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(AppModel.self) private var appModel

    @State private var loginState: NotchLoginItem.State = .disabled
    @State private var loginError: String?
    @State private var confirmsReset = false

    var body: some View {
        @Bindable var store = settingsStore
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .disabled(loginState == .unavailable)
                if loginState == .requiresApproval {
                    LabeledContent("Allow SuperNotch in System Settings") {
                        Button("Open Login Items") {
                            NotchLoginItem.openSystemSettings()
                        }
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Toggle("Show menu-bar icon", isOn: $store.settings.showMenuBarIcon)
            } header: {
                Text("Startup")
            } footer: {
                if loginState == .unavailable {
                    Text("Launch at login works once SuperNotch is in the Applications folder.")
                } else if !store.settings.showMenuBarIcon {
                    Text(
                        "Without the menu-bar icon, open Settings with the gear in the notch or by launching "
                            + "SuperNotch again.")
                }
            }

            Section {
                LabeledContent("Setup assistant") {
                    Button("Run Setup Again") {
                        appModel.showOnboarding()
                    }
                }
                LabeledContent("All settings") {
                    Button("Reset to Defaults…") {
                        confirmsReset = true
                    }
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("SuperNotch keeps everything on this Mac.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshLoginState()
        }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive) {
                settingsStore.reset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shortcuts, notch, Claude, music, shelf and clipboard settings go back to their defaults. "
                + "Your shelf items, clipboard history and installed hooks are not touched.")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginState == .enabled || loginState == .requiresApproval },
            set: { enabled in
                loginError = NotchLoginItem.setEnabled(enabled)
                if loginError == nil {
                    settingsStore.settings.launchAtLogin = enabled
                }
                refreshLoginState()
            })
    }

    private func refreshLoginState() {
        loginState = NotchLoginItem.state
    }
}

struct SettingsNotchPane: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        @Bindable var store = settingsStore
        Form {
            Section {
                Picker("When idle", selection: $store.settings.closedMode) {
                    Text("Invisible until something happens").tag(ClosedNotchMode.invisible)
                    Text("Dynamic Island").tag(ClosedNotchMode.island)
                }
                Picker("Style", selection: $store.settings.notchStyle) {
                    Text("Liquid Glass").tag(NotchStyle.glass)
                    Text("Solid black").tag(NotchStyle.solidBlack)
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text(appearanceFooter(closedMode: store.settings.closedMode, style: store.settings.notchStyle))
            }

            Section {
                Toggle("Open when the pointer rests on the notch", isOn: $store.settings.openOnHover)
                SettingsDelayRow(
                    title: "Open after", value: $store.settings.hoverOpenDelay, range: 0...1, step: 0.05
                )
                .disabled(!store.settings.openOnHover)
                SettingsDelayRow(
                    title: "Close after leaving", value: $store.settings.hoverCloseDelay, range: 0...2, step: 0.05)
                Toggle("Haptic feedback when it opens", isOn: $store.settings.hapticsEnabled)
            } header: {
                Text("Hover")
            } footer: {
                Text("Only the notch itself counts, so moving along the menu bar never opens it. "
                    + "Clicking the notch or pressing the shortcut always works.")
            }

            Section {
                Toggle("Hide in fullscreen apps", isOn: $store.settings.hideInFullscreen)
            } header: {
                Text("Fullscreen")
            } footer: {
                Text("Requests that need you (permission prompts and questions) still appear over fullscreen apps.")
            }
        }
        .formStyle(.grouped)
    }

    private func appearanceFooter(closedMode: ClosedNotchMode, style: NotchStyle) -> String {
        var text: String
        switch closedMode {
        case .invisible:
            text = "The closed notch looks like the plain hardware notch; it only reacts to hover and events."
        case .island:
            text = "While music plays or Claude works, the closed notch shows the cover on the left and "
                + "the visualizer or Claude status on the right."
        }
        if style == .glass && reduceTransparency {
            text += " Reduce Transparency is on in System Settings, so the notch is solid black."
        }
        return text
    }
}

/// A labelled slider for a delay in seconds.
private struct SettingsDelayRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 240)
                Text(String(format: "%.2f s", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}
