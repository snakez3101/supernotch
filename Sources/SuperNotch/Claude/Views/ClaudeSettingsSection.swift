// Owner: claude-app. Settings › Claude (SPEC §A.10): hook status + install / repair / uninstall, statusLine
// bridge, pop-up rules, dangerous-command confirmation, Haiku titles, usage bars, config folder override.
// Hosted directly as the pane content (brings its own grouped Form). Normal window: semantic colours.

import AppKit
import SuperNotchCore
import SwiftUI

struct ClaudeSettingsSection: View {
    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(SettingsStore.self) private var settingsStore

    @State private var configDraft = ""

    init() {}

    var body: some View {
        @Bindable var store = settingsStore
        Form {
            Section {
                Toggle("Show Claude Code sessions", isOn: $store.settings.claudeEnabled)
            } header: {
                Text("Claude Code")
            } footer: {
                Text(
                    "Local sessions from the terminal, IDEs and the Claude app's Code tab: 🟡 working, 🟢 done, "
                        + "🔴 needs you. Everything stays on this Mac.")
            }

            ClaudeHookSettingsGroup()

            Section {
                Toggle("Pop open when a session needs you (🔴)", isOn: $store.settings.popupOnNeedsInput)
                Toggle("Pop open when a session is done (🟢)", isOn: $store.settings.popupOnDone)
                Toggle("Skip 🟢 when its app is in front", isOn: $store.settings.skipDoneWhenHostFrontmost)
                    .disabled(!store.settings.popupOnDone)
                Stepper(value: $store.settings.doneAutoCollapse, in: 2...20, step: 1) {
                    LabeledContent("Close 🟢 pop-ups after") {
                        Text("\(Int(store.settings.doneAutoCollapse)) s")
                            .monospacedDigit()
                    }
                }
                .disabled(!store.settings.popupOnDone)
            } header: {
                Text("Pop-ups")
            } footer: {
                Text(
                    "🔴 always pops up, even over full-screen apps. Without pop-ups for 🔴, permission prompts are "
                        + "answered in the terminal or the Claude app.")
            }
            .disabled(!store.settings.claudeEnabled)

            Section {
                Toggle("Confirm dangerous commands with a second click", isOn: $store.settings.confirmDangerousCommands)
            } header: {
                Text("Permissions")
            } footer: {
                Text(
                    "Commands such as rm -rf, sudo or git push --force are shown in red. Return allows and Esc "
                        + "denies only after you clicked into the notch, so typing in a terminal never approves.")
            }
            .disabled(!store.settings.claudeEnabled)

            ClaudeUsageSettingsGroup()

            Section {
                Toggle("Short titles with Claude Haiku", isOn: $store.settings.generateTitlesWithHaiku)
            } header: {
                Text("Titles")
            } footer: {
                Text(
                    "Claude Code's own session title is used when there is one. Only otherwise SuperNotch asks "
                        + "Haiku once for a 2–4 word title (claude -p, your subscription). Titles are cached and "
                        + "never written back.")
            }
            .disabled(!store.settings.claudeEnabled)

            Section {
                LabeledContent("Folder") {
                    Text(abbreviated(claude.configDirectory))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Override (empty = automatic)", text: $configDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyConfigDraft() }
                    Button("Choose…") { chooseConfigFolder() }
                    Button("Automatic") {
                        configDraft = ""
                        applyConfigDraft()
                    }
                    .disabled(store.settings.claudeConfigDirOverride == nil)
                }
            } header: {
                Text("Claude config folder")
            } footer: {
                Text(
                    "Automatic uses $CLAUDE_CONFIG_DIR when SuperNotch can see it, otherwise ~/.claude. Set a "
                        + "folder here if you run Claude Code with a different CLAUDE_CONFIG_DIR.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            configDraft = store.settings.claudeConfigDirOverride ?? ""
            claude.refreshHookStatus()
            claude.discoverConfigDirectories()
        }
    }

    private func applyConfigDraft() {
        let trimmed = configDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.settings.claudeConfigDirOverride = trimmed.isEmpty ? nil : trimmed
    }

    private func chooseConfigFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the Claude Code config folder (the one that contains settings.json)."
        panel.directoryURL = URL(fileURLWithPath: claude.configDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configDraft = url.path
        applyConfigDraft()
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Hook status, install / repair / uninstall, other config folders, backups.
private struct ClaudeHookSettingsGroup: View {
    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(SettingsStore.self) private var store

    var body: some View {
        Section {
            LabeledContent("Status") {
                ClaudeHookStatusLabel(status: claude.hookStatus)
            }
            if let detail = claude.hookStatus.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Settings file") {
                Text((claude.settingsFilePath as NSString).abbreviatingWithTildeInPath)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            HStack {
                actionButtons
                Spacer()
                if claude.isHookOperationRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let message = claude.hookMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let backup = claude.lastBackupPath {
                LabeledContent("Backup") {
                    Button((backup as NSString).lastPathComponent) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup)])
                    }
                    .buttonStyle(.link)
                }
            }
            ForEach(claude.detectedConfigDirectories, id: \.self) { directory in
                LabeledContent {
                    Button("Install there too") { claude.installHooks(inConfigDirectory: directory) }
                        .disabled(claude.isHookOperationRunning)
                } label: {
                    Text("Also found \((directory as NSString).abbreviatingWithTildeInPath)")
                }
            }
            ForEach(claude.extraConfigStatuses.keys.sorted(), id: \.self) { directory in
                LabeledContent((directory as NSString).abbreviatingWithTildeInPath) {
                    ClaudeHookStatusLabel(status: claude.extraConfigStatuses[directory] ?? .unknown)
                }
            }
            if let error = claude.socketError {
                Label("Session tracking is off: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if !claude.isClaudeCLIFound {
                Text("The claude command was not found. Hooks still work; titles, usage checks and newer hook events need it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("What gets added to settings.json") {
                ClaudeHookPreview(text: claude.hookPreview)
            }
        } header: {
            Text("Hooks")
        } footer: {
            Text(hookFooter)
        }
        .disabled(!store.settings.claudeEnabled)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch claude.hookStatus {
        case .installed:
            Button("Uninstall Hooks") { claude.uninstallHooks() }
                .disabled(claude.isHookOperationRunning)
            Button("Check Again") { claude.refreshHookStatus() }
        case .needsRepair:
            Button("Repair") { claude.installHooks() }
                .buttonStyle(.borderedProminent)
                .disabled(claude.isHookOperationRunning)
            Button("Uninstall Hooks") { claude.uninstallHooks() }
                .disabled(claude.isHookOperationRunning)
        case .notInstalled:
            Button("Install Hooks") { claude.installHooks() }
                .buttonStyle(.borderedProminent)
                .disabled(claude.isHookOperationRunning)
        case .failed:
            Button("Check Again") { claude.refreshHookStatus() }
            Button("Show settings.json") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: claude.settingsFilePath)])
            }
        case .unknown:
            Button("Check Again") { claude.refreshHookStatus() }
        }
        Button("Show Backups") {
            NSWorkspace.shared.open(URL(fileURLWithPath: claude.backupDirectory, isDirectory: true))
        }
        .disabled(!FileManager.default.fileExists(atPath: claude.backupDirectory))
    }

    private var hookFooter: String {
        var text =
            "SuperNotch adds its own entries to settings.json and never changes your other hooks. Every change "
            + "is backed up first; uninstalling restores your status line."
        if let version = claude.claudeVersionText { text += " Claude Code \(version)." }
        return text
    }
}

/// Usage bars, status line bridge, warning threshold.
private struct ClaudeUsageSettingsGroup: View {
    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        Section {
            Toggle("Show usage limits (5-hour and weekly)", isOn: $store.settings.showUsageLimits)
            Toggle("Read limits via the status line", isOn: $store.settings.wrapStatusLine)
            LabeledContent("Warn at") {
                HStack {
                    Slider(value: $store.settings.usageWarningThreshold, in: 0.5...1.0, step: 0.05)
                        .frame(width: 160)
                    Text(ClaudeFormat.percent(store.settings.usageWarningThreshold * 100))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!store.settings.showUsageLimits)
            LabeledContent("Now") {
                Text(currentUsage)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Usage limits")
        } footer: {
            Text(
                "The limits come from Claude Code's status line (Pro and Max plans, after the first answer of a "
                    + "terminal session). SuperNotch wraps your status line and keeps showing its output. While any "
                    + "status line is set, Claude Code hides some footer hints such as \u{201C}esc to interrupt\u{201D}.")
        }
        .disabled(!store.settings.claudeEnabled)
    }

    private var currentUsage: String {
        guard let usage = claude.usage else { return "No data yet" }
        let now = Date()
        var parts: [String] = []
        if let window = usage.fiveHour { parts.append("5h \(ClaudeFormat.percent(window.usedPercentage))") }
        if let window = usage.sevenDay { parts.append("7d \(ClaudeFormat.percent(window.usedPercentage))") }
        parts.append(ClaudeFormat.updatedDescription(usage.updatedAt, now: now))
        return parts.joined(separator: " · ")
    }
}

/// Icon + title for a hook status (normal window colours).
struct ClaudeHookStatusLabel: View {
    let status: ClaudeHookStatus

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .unknown:
                ProgressView()
                    .controlSize(.small)
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notInstalled:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
            case .needsRepair:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            Text(status.title)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Monospaced, scrollable preview of the settings.json entries.
struct ClaudeHookPreview: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "…" : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: 90, maxHeight: 160)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
