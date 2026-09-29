// Owner: claude-app. The permission card (SPEC §A.7): peek content (452 × 114 pt inside the 480 pt peek) and
// a compact inline variant for the expanded Home column.
//
//   ⌘ Bash · Fix login bug · supernotch                       1 of 3
//   git push --force origin main                              ← monospaced for Bash
//   Push the release branch                                   ← optional detail
//   [force push]                          Deny  Always allow  Allow
//
// * Dangerous commands: red tint + reason chips; Allow / Always allow need a second click within 4 s
//   ("Confirm allow"); Return needs the same confirm step.
// * Return = Allow, Esc = Deny, only while the panel is key (typing in a terminal never approves, §A.4).
// * Answered in the terminal / timed out: the request disappears from the model and the card with it.

import SuperNotchCore
import SwiftUI

struct PermissionCardView: View {
    enum Style {
        /// Auto popup content (SPEC §A.6).
        case peek
        /// Compact card at the top of the Home column while the notch is expanded.
        case inline
    }

    let requestID: String
    let style: Style

    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(NotchViewModel.self) private var notch
    @Environment(SettingsStore.self) private var store

    /// The action waiting for its confirming second click (dangerous commands).
    @State private var armed: ArmedAction?
    @State private var disarmTask: Task<Void, Never>?
    @State private var holdToken: NotchHoldToken?
    @FocusState private var isFocused: Bool

    private enum ArmedAction: Equatable {
        case allow
        case alwaysAllow
    }

    init(requestID: String) {
        self.requestID = requestID
        self.style = .peek
    }

    init(requestID: String, style: Style) {
        self.requestID = requestID
        self.style = style
    }

    var body: some View {
        if let request = claude.permission(id: requestID) {
            card(for: request)
        } else {
            // Answered elsewhere or withdrawn: the shell removes the popup; render nothing meanwhile.
            Color.clear
        }
    }

    // MARK: - Layout

    private func card(for request: PermissionRequest) -> some View {
        let session = claude.session(id: request.sessionID)
        let dangerous = request.danger.isDangerous
        let isPeek = style == .peek
        return VStack(alignment: .leading, spacing: isPeek ? DesignTokens.Spacing.s : DesignTokens.Spacing.xs) {
            header(request: request, session: session)
            Text(request.summary)
                .font(isMonospaced(request) ? DesignTokens.Fonts.mono : DesignTokens.Fonts.bodyEmphasized)
                .foregroundStyle(DesignTokens.Colors.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(request.summary)
            if isPeek, let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if isPeek { Spacer(minLength: 0) }
            footer(request: request, session: session)
        }
        .padding(isPeek && !dangerous ? 0 : DesignTokens.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: isPeek ? CGFloat.infinity : nil, alignment: .topLeading)
        .background {
            if dangerous || !isPeek {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
                    .fill(dangerous ? DesignTokens.Colors.dangerTint : DesignTokens.Colors.hoverFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
                            .strokeBorder(
                                dangerous ? DesignTokens.Colors.danger.opacity(0.55) : DesignTokens.Colors.hairline,
                                lineWidth: 1)
                    }
            }
        }
        .focusable(isPeek)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) { handleReturn(request) }
        .onKeyPress(.escape) { handleEscape(request) }
        .onAppear {
            if isPeek && notch.isKeyFocused { isFocused = true }
        }
        .onChange(of: notch.isKeyFocused) { _, focused in
            if isPeek && focused { isFocused = true }
        }
        .onHover { hovering in
            // "A pending permission card the user is looking at" keeps the notch open (§A.4).
            if hovering {
                if holdToken == nil { holdToken = notch.holdOpen(reason: "claude.permission") }
            } else {
                holdToken?.release()
                holdToken = nil
            }
        }
        .onDisappear {
            holdToken?.release()
            holdToken = nil
            disarmTask?.cancel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude wants to use \(request.toolName): \(request.summary)")
    }

    private func header(request: PermissionRequest, session: Session?) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs + 1) {
            Image(systemName: ClaudeFormat.symbol(forTool: request.toolName))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(request.danger.isDangerous ? DesignTokens.Colors.danger : DesignTokens.Colors.secondaryText)
            Text(ClaudeFormat.toolDisplayName(request.toolName))
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.secondaryText)
                .lineLimit(1)
            if let session {
                Text("·")
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
                Text(session.displayTitle)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.primaryText.opacity(0.85))
                    .lineLimit(1)
                Text(session.projectName)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DesignTokens.Spacing.xs)
            if let position = position(of: request) {
                Text(position)
                    .font(DesignTokens.Fonts.rowMeta)
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
            }
        }
        .font(DesignTokens.Fonts.caption)
    }

    private func footer(request: PermissionRequest, session: Session?) -> some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            if request.danger.isDangerous {
                reasonChips(request.danger.reasons)
            } else if style == .peek {
                Button {
                    claude.answerInChat(requestID: request.id)
                } label: {
                    Label("Open chat", systemImage: "arrow.up.forward.app")
                        .font(DesignTokens.Fonts.caption)
                        .foregroundStyle(DesignTokens.Colors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Answer in \(session.flatMap { ClaudeHostApps.displayName(for: $0.host) } ?? "the chat") instead")
            }
            Spacer(minLength: DesignTokens.Spacing.xs)
            Button("Deny") { deny(request) }
                .buttonStyle(ClaudeCapsuleButtonStyle(kind: .neutral))
                .help("Deny (Esc)")
            if request.canAlwaysAllow {
                Button(armed == .alwaysAllow ? "Confirm" : alwaysAllowTitle(request)) { alwaysAllow(request) }
                    .buttonStyle(ClaudeCapsuleButtonStyle(kind: armed == .alwaysAllow ? .danger : .neutral))
                    .help(alwaysAllowHelp(request))
            }
            Button(armed == .allow ? "Confirm allow" : "Allow") { allow(request) }
                .buttonStyle(ClaudeCapsuleButtonStyle(kind: armed == .allow ? .danger : .primary))
                .help(needsConfirmation(request) ? "Dangerous: click twice to allow (Return)" : "Allow once (Return)")
        }
    }

    private func reasonChips(_ reasons: [String]) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.danger)
            ForEach(Array(reasons.prefix(style == .peek ? 3 : 1).enumerated()), id: \.offset) { _, reason in
                Text(reason)
                    .font(DesignTokens.Fonts.micro)
                    .foregroundStyle(DesignTokens.Colors.danger)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(DesignTokens.Colors.danger.opacity(0.18), in: Capsule())
            }
        }
    }

    // MARK: - Actions

    private func isMonospaced(_ request: PermissionRequest) -> Bool {
        request.toolName == "Bash" || request.toolName == "PowerShell"
    }

    private func needsConfirmation(_ request: PermissionRequest) -> Bool {
        request.danger.isDangerous && store.settings.confirmDangerousCommands
    }

    private func allow(_ request: PermissionRequest) {
        if needsConfirmation(request) && armed != .allow {
            arm(.allow)
            return
        }
        claude.answer(requestID: request.id, decision: .allow)
    }

    private func alwaysAllow(_ request: PermissionRequest) {
        if needsConfirmation(request) && armed != .alwaysAllow {
            arm(.alwaysAllow)
            return
        }
        claude.answer(requestID: request.id, decision: request.alwaysAllowDecision)
    }

    private func deny(_ request: PermissionRequest) {
        claude.answer(requestID: request.id, decision: .deny(message: PermissionDecision.defaultDenyMessage))
    }

    /// First click on a dangerous request: switch to "Confirm allow" for `dangerConfirmWindow` (4 s).
    private func arm(_ action: ArmedAction) {
        armed = action
        disarmTask?.cancel()
        disarmTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(NotchMetrics.dangerConfirmWindow))
            guard !Task.isCancelled else { return }
            armed = nil
        }
    }

    private func handleReturn(_ request: PermissionRequest) -> KeyPress.Result {
        guard notch.isKeyFocused else { return .ignored }
        allow(request)
        return .handled
    }

    private func handleEscape(_ request: PermissionRequest) -> KeyPress.Result {
        guard notch.isKeyFocused else { return .ignored }
        if armed != nil {
            armed = nil
            disarmTask?.cancel()
            return .handled
        }
        deny(request)
        return .handled
    }

    // MARK: - Labels

    /// "1 of 3" when several requests wait (oldest first).
    private func position(of request: PermissionRequest) -> String? {
        let all = claude.permissions
        guard all.count > 1, let index = all.firstIndex(where: { $0.id == request.id }) else { return nil }
        return "\(index + 1) of \(all.count)"
    }

    /// "Allow for session" when the suggestion only lasts for this session, else "Always allow".
    private func alwaysAllowTitle(_ request: PermissionRequest) -> String {
        guard case .allowAlways(let updates) = request.alwaysAllowDecision else { return "Always allow" }
        let destinations = Set(updates.compactMap { $0["destination"]?.stringValue })
        return destinations == ["session"] ? "Allow for session" : "Always allow"
    }

    private func alwaysAllowHelp(_ request: PermissionRequest) -> String {
        guard case .allowAlways(let updates) = request.alwaysAllowDecision else { return "Allow and remember" }
        let destinations = Set(updates.compactMap { $0["destination"]?.stringValue })
        if destinations.contains("userSettings") { return "Allow and add a rule to your user settings" }
        if destinations.contains("projectSettings") { return "Allow and add a rule to the project settings" }
        if destinations.contains("localSettings") { return "Allow and add a rule to the local project settings" }
        if destinations == ["session"] { return "Allow for the rest of this session" }
        return "Allow and remember"
    }
}
