// Owner: shelf-clipboard. Settings › Clipboard (SPEC §A.10): enable, limit (50–1000), capture images, ignored
// apps, paste permission status, clear history.
//
// Hosting note: this view brings its own grouped `Form`; put it directly in the Settings detail pane.
import AppKit
import SuperNotchCore
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsSection: View {
    @Environment(ClipboardModel.self) private var clipboard
    @Environment(SettingsStore.self) private var settingsStore
    @State private var confirmingClear = false

    init() {}

    var body: some View {
        @Bindable var store = settingsStore
        Form {
            Section {
                Toggle("Enable clipboard history", isOn: $store.settings.clipboardEnabled)
                Stepper(
                    value: $store.settings.clipboardLimit, in: AppSettings.clipboardLimitRange, step: 50
                ) {
                    LabeledContent("Keep up to") {
                        Text("\(store.settings.clipboardLimit) items")
                            .monospacedDigit()
                    }
                }
                Toggle("Save copied images", isOn: $store.settings.captureImages)
            } header: {
                Text("History")
            } footer: {
                Text(historyFooter)
            }

            Section {
                LabeledContent("Paste with Return") {
                    ClipboardPermissionLabel(
                        isGranted: clipboard.canPaste, grantedText: "Allowed",
                        missingText: "Not allowed: Return only copies")
                }
                if !clipboard.canPaste {
                    HStack {
                        Button("Allow Pasting…") { clipboard.requestPastePermission() }
                        Button("Open Accessibility Settings") { clipboard.openAccessibilitySettings() }
                    }
                }
                LabeledContent("Reading the clipboard") {
                    let access = clipboard.pasteboardAccess
                    ClipboardPermissionLabel(
                        isGranted: access.allowsAutomaticCapture, grantedText: access.summary,
                        missingText: access.summary)
                }
                if !clipboard.pasteboardAccess.allowsAutomaticCapture {
                    Button("Open Privacy Settings") { clipboard.openPrivacySettings() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text(
                    "Pasting sends ⌘V to the app you were typing in, which macOS allows only after you add "
                        + "SuperNotch under Privacy & Security › Accessibility. macOS may also ask once whether "
                        + "SuperNotch can read what you copy; choose Allow.")
            }

            Section {
                ClipboardIgnoredAppsList()
            } header: {
                Text("Never record copies from")
            } footer: {
                Text(
                    "Password managers are ignored by default. Anything marked as concealed or transient "
                        + "(nspasteboard.org) is never recorded, whichever app it comes from.")
            }

            Section {
                LabeledContent("Stored items") {
                    Text(clipboard.history.isEmpty ? "None" : "\(clipboard.history.count)")
                        .foregroundStyle(.secondary)
                }
                Button("Clear History…", role: .destructive) { confirmingClear = true }
                    .disabled(clipboard.history.isEmpty)
            } header: {
                Text("Storage")
            }
        }
        .formStyle(.grouped)
        .onAppear { clipboard.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            clipboard.refreshPermissions()
        }
        .confirmationDialog(
            "Clear the clipboard history?", isPresented: $confirmingClear, titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { clipboard.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every entry, including pinned ones, and their saved images.")
        }
    }

    private var historyFooter: String {
        let shortcut = settingsStore.settings.clipboardHotkey?.description ?? "the clipboard shortcut"
        return "Press \(shortcut) to open the history. Text, links, images and copied files are kept on this "
            + "Mac only. Old entries are removed with the Shelf's auto-cleanup setting (currently: "
            + "\(settingsStore.settings.retention.displayName.lowercased())); pinned entries stay."
    }
}

private struct ClipboardPermissionLabel: View {
    let isGranted: Bool
    let grantedText: String
    let missingText: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Circle()
                .fill(isGranted ? DesignTokens.Colors.trafficGreen : DesignTokens.Colors.warningOrange)
                .frame(width: 8, height: 8)
            Text(isGranted ? grantedText : missingText)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Editable list of ignored bundle identifiers, shown with app names and icons when installed.
private struct ClipboardIgnoredAppsList: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        let apps = settingsStore.settings.clipboardIgnoredApps
        ForEach(apps, id: \.self) { bundleID in
            HStack(spacing: DesignTokens.Spacing.m) {
                ClipboardAppIcon(bundleID: bundleID)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ClipboardAppInfo.name(for: bundleID) ?? bundleID)
                    if ClipboardAppInfo.name(for: bundleID) != nil {
                        Text(bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    settingsStore.update { settings in
                        settings.clipboardIgnoredApps.removeAll { $0 == bundleID }
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop ignoring this app")
                .accessibilityLabel("Remove \(bundleID)")
            }
        }
        HStack {
            Button("Add App…") { chooseApp() }
            Spacer()
            Button("Restore Defaults") {
                settingsStore.update { $0.clipboardIgnoredApps = AppSettings.defaultIgnoredApps }
            }
            .disabled(apps == AppSettings.defaultIgnoredApps)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Ignore an App"
        panel.prompt = "Ignore"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let store = settingsStore
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
                guard !ids.isEmpty else { return }
                store.update { settings in
                    for id in ids where !settings.clipboardIgnoredApps.contains(id) {
                        settings.clipboardIgnoredApps.append(id)
                    }
                }
            }
        }
    }
}

private struct ClipboardAppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
        }
    }
}

enum ClipboardAppInfo {
    /// Display name of an installed app, nil when it is not installed.
    static func name(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
